#!/bin/bash
# Toggle de Modo Juego para Omarchy
# ON : frame estático del wallpaper actual en los 3 monitores, rotación congelada,
#      blur y animaciones OFF (libera GPU para el juego)
# OFF: restaura blur+animaciones, retoma el MISMO video y la rotación cada 2h
set -u

STATE_DIR="$HOME/.local/state/omarchy/game-mode"
FLAG="$STATE_DIR/active"
VW_STATE="$HOME/.local/state/omarchy/video-wallpaper"
FRAME="$STATE_DIR/current-frame.jpg"
LAST_VIDEO_FILE="$VW_STATE/last_video.txt"
HYPR_CONFIG_ERRORS=""
VW_CURRENT_FRAME="$VW_STATE/current-frame.jpg"
THEME_FRAME="$HOME/.config/omarchy/themes/video-dark/backgrounds/current-frame.jpg"
DW_CONFIG="$HOME/.config/displaywright/wallpapers.json"
DW_BACKUP="$STATE_DIR/wallpapers-backup.json"
CURRENT_LINK="$HOME/.local/state/omarchy/current/background"

notify() { omarchy-notification-send "Modo Juego" "$1" -t 2500 2>/dev/null || notify-send "Modo Juego" "$1" 2>/dev/null || true; }

launch_wallpapers() {
  local video="$1"
  [[ -f $video ]] || return 1
  # SIGKILL evita el teardown NVIDIA EGL que crashea con SIGTERM (ver video-wallpaper-rotator.sh)
  if pgrep -x mpvpaper >/dev/null 2>&1; then
    pkill -KILL -x mpvpaper 2>/dev/null || true
    for _ in {1..20}; do pgrep -x mpvpaper >/dev/null 2>&1 || break; sleep 0.1; done
  fi
  # Dinámico: detecta monitores actuales (a prueba de futuro TV)
  local mons
  mons=$(hyprctl monitors -j 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(m['name'] for m in d))" 2>/dev/null)
  [[ -z "$mons" ]] && mons="HDMI-A-1 DP-1 HDMI-A-2"
  # hwdec=no + gpu-context=waylandvk: mismo que rotator.sh tras fix NVIDIA (vaapi crashea en rotación)
  local opts="no-audio loop-file=inf hwdec=no load-scripts=no gpu-context=waylandvk"
  for m in $mons; do
    mpvpaper -f -o "$opts" "$m" "$video" 2>/dev/null || true
  done
  # Fallback por si hyprctl no respondió a tiempo (boot temprano)
  if ! pgrep -x mpvpaper >/dev/null 2>&1; then
    for m in HDMI-A-1 DP-1 HDMI-A-2; do
      mpvpaper -f -o "$opts" "$m" "$video" 2>/dev/null || true
    done
  fi
}

# Escribe displaywright config per-monitor apuntando a $FRAME (fill) para cubrir TODOS los outputs.
# Sin esto, displaywright solo tapa DP-1/HDMI-A-2 (pinned) y deja HDMI-A-1 transparente,
# causando el bug "solo 2 monitores cambian, el 3ro queda con fondo anterior".
write_displaywright_static() {
  local frame="$1"
  mkdir -p "$(dirname "$DW_CONFIG")"
  # Backup del config actual (para restaurar en OFF)
  if [[ -f "$DW_CONFIG" ]]; then
    cp -a "$DW_CONFIG" "$DW_BACKUP" 2>/dev/null || true
  else
    # Marcador de que no existía config previo
    rm -f "$DW_BACKUP" 2>/dev/null; touch "$DW_BACKUP.empty" 2>/dev/null || true
  fi
  local mons
  mons=$(hyprctl monitors -j 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(m['name'] for m in d))" 2>/dev/null)
  [[ -z "$mons" ]] && mons="HDMI-A-1 DP-1 HDMI-A-2"
  python3 - "$frame" "$DW_CONFIG" $mons << 'PY'
import json, sys, pathlib
frame = sys.argv[1]
config_path = sys.argv[2]
mons = sys.argv[3:]
# Usa path absoluto; displaywright requiere path accesible
frame = str(pathlib.Path(frame).resolve()) if frame else frame
data = {"version": 1, "monitors": {}}
for m in mons:
    data["monitors"][m] = {"kind": "image", "path": frame, "fit": "fill"}
# Escritura atómica
import os, tempfile
d = os.path.dirname(config_path) or "."
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".wallpapers.tmp.")
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, config_path)
except Exception:
    try: os.unlink(tmp)
    except: pass
    raise
PY
}

restore_displaywright() {
  if [[ -f "$DW_BACKUP" ]]; then
    mkdir -p "$(dirname "$DW_CONFIG")"
    mv -f "$DW_BACKUP" "$DW_CONFIG" 2>/dev/null || cp -a "$DW_BACKUP" "$DW_CONFIG" 2>/dev/null || true
    rm -f "$DW_BACKUP.empty" 2>/dev/null || true
  elif [[ -f "$DW_BACKUP.empty" ]]; then
    rm -f "$DW_CONFIG" "$DW_BACKUP.empty" 2>/dev/null || true
  elif [[ -f "$VW_STATE/.last_versioned_frame" && -s "$VW_STATE/.last_versioned_frame" ]]; then
    # Sin backup pero rotator tiene frame versionado vigente: restaurar per-monitor a ese frame
    write_displaywright_static "$(cat "$VW_STATE/.last_versioned_frame")"
  else
    # Sin backup ni versionado: eliminar el config estático que creamos en ON
    rm -f "$DW_CONFIG" 2>/dev/null || true
  fi
  # Dar tiempo a inotifywait del plugin para recargar
  sleep 0.3
}

if [[ -f "$FLAG" ]]; then
  ################ OFF: restaurar todo ################
  rm -f "$FLAG"

  # Efectos: blur y animaciones back on
  hyprctl eval 'hl.config({ decoration = { blur = { enabled = true, size = 6, passes = 2, vibrancy = 0.25 } } })' >/dev/null 2>&1
  hyprctl eval 'hl.config({ animations = { enabled = true } })' >/dev/null 2>&1

  # Restaurar displaywright a su config previo (quita el pin estático per-monitor)
  restore_displaywright

  # Restaurar symlink de background al frame del rotator (no al de game-mode)
  if [[ -f "$VW_CURRENT_FRAME" ]]; then
    ln -nsf "$VW_CURRENT_FRAME" "$CURRENT_LINK" 2>/dev/null || true
    omarchy-shell -q background set "$VW_CURRENT_FRAME" 2>/dev/null || true
  elif [[ -f "$THEME_FRAME" ]]; then
    ln -nsf "$THEME_FRAME" "$CURRENT_LINK" 2>/dev/null || true
    omarchy-shell -q background set "$THEME_FRAME" 2>/dev/null || true
  fi

  # Retomar el MISMO video que estaba antes del modo juego
  LAST_VIDEO=""
  [[ -f "$LAST_VIDEO_FILE" ]] && LAST_VIDEO=$(cat "$LAST_VIDEO_FILE")
  launch_wallpapers "$LAST_VIDEO" || notify "No se pudo relanzar el wallpaper"

  # Reactivar rotación cada 2h y reiniciar su countdown desde AHORA
  systemctl --user start video-wallpaper.timer 2>/dev/null
  touch "$VW_STATE/.skip-once" 2>/dev/null || true
  systemctl --user start video-wallpaper.service 2>/dev/null || true

  notify "Desactivado - wallpaper y efectos restaurados"
else
  ################ ON: modo juego ################
  mkdir -p "$STATE_DIR"
  touch "$FLAG"

  # 1) Extraer frame actual del video en reproducción
  VIDEO=""
  [[ -f "$LAST_VIDEO_FILE" ]] && VIDEO=$(cat "$LAST_VIDEO_FILE")
  FRAME_FOR=""
  [[ -f "$VW_STATE/.game_frame_for" ]] && FRAME_FOR=$(cat "$VW_STATE/.game_frame_for")
  # Ruta rápida: el rotator ya pre-generó el frame de ESTE video → instantáneo, sin ffmpeg
  if [[ -n "$VIDEO" && "$FRAME_FOR" == "$VIDEO" && -s "$FRAME" ]]; then
    : # FRAME vigente del rotator, usar tal cual
  elif [[ -n "$VIDEO" && -f "$VIDEO" ]]; then
      ffmpeg -y -v error -ss 1 -i "$VIDEO" -vframes 1 -q:v 2 "$FRAME.tmp.jpg" 2>/dev/null \
        && mv "$FRAME.tmp.jpg" "$FRAME"
  fi

  if [[ ! -s "$FRAME" ]]; then
    # Sin video vigente: usar fallback existente o salir sin tocar nada visual
    FALLBACK="$HOME/.local/state/omarchy/current/background"
    [[ -f "$FALLBACK" ]] && cp -L "$FALLBACK" "$FRAME" 2>/dev/null
  fi

  # 2) Fondo estático: displaywright per-monitor + shell fallback + matar videos
  if [[ -s "$FRAME" ]]; then
    # Sincroniza también los caches que displaywright/omarchy usan como fallback
    # (si wallpapers.json fallara, que al menos el theme muestre el frame actual)
    mkdir -p "$(dirname "$THEME_FRAME")"
    cp -a "$FRAME" "$THEME_FRAME" 2>/dev/null || true
    cp -a "$FRAME" "$VW_CURRENT_FRAME" 2>/dev/null || true
    ln -nsf "$FRAME" "$CURRENT_LINK" 2>/dev/null || true
    # Cubre TODOS los monitores via displaywright (fix bug 2/3 monitores)
    write_displaywright_static "$FRAME"
    # Fallback stock renderer (para outputs sin pin si algo falla)
    omarchy-shell -q background set "$FRAME" 2>/dev/null || true
  else
    # Sin frame válido: al menos intenta cubrir con backup existente para no dejar stale
    [[ -s "$VW_CURRENT_FRAME" ]] && write_displaywright_static "$VW_CURRENT_FRAME" || true
  fi
  # Matar mpvpaper DESPUÉS de preparar el frame estático para evitar black flash
  if pgrep -x mpvpaper >/dev/null 2>&1; then
    pkill -KILL -x mpvpaper 2>/dev/null || true
    for _ in {1..20}; do pgrep -x mpvpaper >/dev/null 2>&1 || break; sleep 0.1; done
  fi

  # 3) Congelar rotación
  systemctl --user stop video-wallpaper.timer 2>/dev/null

  # 4) Efectos OFF (blur + animaciones); VRR y saturacion se quedan (ayudan al juego)
  hyprctl eval 'hl.config({ decoration = { blur = { enabled = false } } })' >/dev/null 2>&1
  hyprctl eval 'hl.config({ animations = { enabled = false } })' >/dev/null 2>&1

  ERRORS=$(hyprctl configerrors 2>/dev/null | grep -c . || true)
  notify "Activado - blur/animaciones OFF, fondo estatico${ERRORS:+, $ERRORS errores hypr}"
fi

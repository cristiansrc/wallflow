#!/bin/bash
set -euo pipefail

# Marcador skip-once: una rotación manual (picker/hotkey) toca este archivo y
# activa el servicio solo para actualizar el last-active del timer (reset del
# countdown de 2h). Esta corrida del servicio no debe rotar de nuevo.
# Va ANTES del guard de game-mode para que el skip-run consuma el marcador
# incluso con modo juego activo (si no, el marcador huérfano se comería una
# rotación automática futura).
if [[ -f "$HOME/.local/state/omarchy/video-wallpaper/.skip-once" ]]; then
  rm -f "$HOME/.local/state/omarchy/video-wallpaper/.skip-once"
  echo "Rotacion manual ya aplicada: countdown del timer reiniciado"
  exit 0
fi

# Modo Juego activo: no rotar, no regenerar tema, no relanzar wallpapers
[[ -f "$HOME/.local/state/omarchy/game-mode/active" ]] && { echo "Game mode activo: rotacion omitida"; exit 0; }

WALLPAPER_DIR="$HOME/Wallpapers"
THEME_NAME="video-dark"
THEME_DIR="$HOME/.config/omarchy/themes/$THEME_NAME"
STATE_DIR="$HOME/.local/state/omarchy/video-wallpaper"
CURRENT_LINK="$HOME/.local/state/omarchy/current/background"
DW_CONFIG="$HOME/.config/displaywright/wallpapers.json"
DW_FRAMES_DIR="$STATE_DIR/frames"
GAME_FRAME="$HOME/.local/state/omarchy/game-mode/current-frame.jpg"
mkdir -p "$STATE_DIR" "$THEME_DIR/backgrounds" "$DW_FRAMES_DIR"

# Pick random video (mp4/webm)
if [[ ! -d "$WALLPAPER_DIR" ]]; then
  echo "Wallpaper dir no existe: $WALLPAPER_DIR" >&2
  omarchy-notification-send --urgency critical "Video wallpaper error" "Directorio no existe: $WALLPAPER_DIR" 2>/dev/null || true
  exit 1
fi

# Modo forzado: rotate-wall <nombre_archivo>
# Uso: rotate-wall "Wallpaper (100).mp4"  -> busca en $WALLPAPER_DIR y si existe lo usa
#      rotate-wall /ruta/absoluta/video.mp4 -> usa esa ruta si existe
#      si no lo encuentra no hace nada (exit 0)
# Soporta nombres con espacios sin comillas si se pasan como varios args (los une con espacio)
FORCED_PICK=""
if [[ $# -gt 0 ]]; then
  # Une todos los args con espacio para soportar: rotate-wall Wallpaper (100).mp4 sin comillas
  # Si el usuario ya comillo, $* == $1 igualmente
  FORCED_RAW="$*"
  # Trim espacios extremos
  FORCED_RAW="$(echo "$FORCED_RAW" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [[ -n "$FORCED_RAW" ]]; then
    CANDIDATE=""
    # 1) Si es ruta absoluta o contiene /, probar tal cual
    if [[ "$FORCED_RAW" == /* || "$FORCED_RAW" == */* ]]; then
      if [[ -f "$FORCED_RAW" ]]; then
        CANDIDATE="$FORCED_RAW"
      elif [[ -f "$WALLPAPER_DIR/$FORCED_RAW" ]]; then
        CANDIDATE="$WALLPAPER_DIR/$FORCED_RAW"
      elif [[ -f "$WALLPAPER_DIR/$(basename "$FORCED_RAW")" ]]; then
        CANDIDATE="$WALLPAPER_DIR/$(basename "$FORCED_RAW")"
      fi
    else
      # 2) Nombre simple -> buscar en WALLPAPER_DIR
      if [[ -f "$WALLPAPER_DIR/$FORCED_RAW" ]]; then
        CANDIDATE="$WALLPAPER_DIR/$FORCED_RAW"
      fi
    fi
    if [[ -n "$CANDIDATE" && -f "$CANDIDATE" ]]; then
      FORCED_PICK="$CANDIDATE"
      echo "Modo forzado: $FORCED_PICK"
    else
      echo "Wallpaper no encontrado en $WALLPAPER_DIR: $FORCED_RAW (no se cambia)" >&2
      exit 0
    fi
  fi
fi

mapfile -t VIDEOS < <(find "$WALLPAPER_DIR" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.webm" \) | sort)
if (( ${#VIDEOS[@]} == 0 )); then
  echo "No videos found" >&2
  omarchy-notification-send --urgency critical "Video wallpaper error" "No hay videos en $WALLPAPER_DIR" 2>/dev/null || true
  exit 1
fi

# Pick: forzado o random (evitando repetir last)
LAST_FILE="$STATE_DIR/last_video.txt"
if [[ -n "$FORCED_PICK" ]]; then
  PICK="$FORCED_PICK"
else
  PICK=$(shuf -n1 -e "${VIDEOS[@]}")
  if [[ -f "$LAST_FILE" ]]; then
    LAST=$(cat "$LAST_FILE")
    # if we picked same as last and have more than 1, pick again
    if [[ "$PICK" == "$LAST" && ${#VIDEOS[@]} -gt 1 ]]; then
      PICK=$(shuf -n1 -e "${VIDEOS[@]}")
      # ensure different if still same, loop
      tries=0
      while [[ "$PICK" == "$LAST" && $tries -lt 5 ]]; do
        PICK=$(shuf -n1 -e "${VIDEOS[@]}")
        ((tries++))
      done
    fi
  fi
fi
echo "$PICK" > "$LAST_FILE"
echo "Selected video: $PICK"

# Extrae frame SIN matar video todavía: el video viejo sigue tapando y no hay gap negro/flash.
# Preparación en background para que el corte sea instantáneo.
TMPFRAME=$(mktemp /tmp/video-frame-XXXXXX.jpg)
TMPHIST=$(mktemp /tmp/video-hist-XXXXXX.txt)

cleanup() { rm -f "$TMPFRAME" "$TMPHIST"; }
trap cleanup EXIT

# Get duration to pick seek point
DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$PICK" 2>/dev/null || echo "10")
# Use 2s or 15% duration whichever smaller but at least 1s
SEEK=$(awk -v d="$DUR" 'BEGIN{ s=d*0.15; if(s<1)s=1; if(s>2)s=2; print s }')

ffmpeg -y -ss "$SEEK" -i "$PICK" -vframes 1 -vf "scale=1920:1080:flags=bicubic" "$TMPFRAME" 2>/dev/null

if [[ ! -s "$TMPFRAME" ]]; then
  echo "Failed to extract frame, using fallback color" >&2
  DOMINANT="#f38d70"
else
  # Frame versionado para displaywright: cada video tiene su jpg único → signature distinta → animación wipe garantizada.
  # Antes se sobreescribía siempre current-frame.jpg (mismo path) y Surface.qml no detectaba cambio → sin animación y cache stale.
  BASE=$(basename "$PICK")
  SAFE=$(echo "${BASE%.*}" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80)
  HASH=$(sha256sum "$PICK" 2>/dev/null | cut -c1-8)
  [[ -z "$HASH" ]] && HASH=$(date +%s)
  VERSIONED="$DW_FRAMES_DIR/${SAFE}-${HASH}.jpg"
  cp "$TMPFRAME" "$VERSIONED" 2>/dev/null || VERSIONED="$TMPFRAME"
  # Mantener compat: theme preview y fallback legacy
  cp "$TMPFRAME" "$THEME_DIR/backgrounds/current-frame.jpg" 2>/dev/null || true
  cp "$TMPFRAME" "$STATE_DIR/current-frame.jpg" 2>/dev/null || true
  # Pre-generar frame para modo juego: toggle ON será instantáneo sin ffmpeg
  mkdir -p "$(dirname "$GAME_FRAME")"
  cp "$TMPFRAME" "$GAME_FRAME" 2>/dev/null || true
  echo "$PICK" > "$STATE_DIR/.game_frame_for" 2>/dev/null || true
  ln -nsf "$STATE_DIR/current-frame.jpg" "$CURRENT_LINK" 2>/dev/null || true
  # Guardar path versionado para update de displaywright tras pkill
  echo "$VERSIONED" > "$STATE_DIR/.last_versioned_frame" 2>/dev/null || true
  # Limpieza: mantener solo últimos 20 frames versionados
  ls -1t "$DW_FRAMES_DIR"/*.jpg 2>/dev/null | tail -n +21 | xargs -r rm -f -- 2>/dev/null || true

  # Extract dominant color: resize to 1x1 after removing extreme dark/light, or histogram
  # Method: scale to 64px, get histogram, pick most frequent non-black/white color with decent saturation
  # Simpler robust: magick -resize 1x1 gives average, but we want vibrant dominant
  # Try histogram method
  magick "$TMPFRAME" -resize 64x64 -colors 8 -format "%c" histogram:info: > "$TMPHIST" 2>/dev/null || true

  # Parse histogram: lines like "  1234: (12,34,56) #0C2238 srgb(...)"
  # Pick the color with highest count that is not too dark (<15) and not too light (>240) and saturated
  DOMINANT=$(python3 - "$TMPHIST" << 'PY'
import re, sys
path=sys.argv[1]
best_score=-1
best_hex=None
try:
    with open(path) as f:
        for line in f:
            m=re.search(r'^\s*(\d+):\s*\((\d+),(\d+),(\d+)\)\s*(#[0-9A-Fa-f]{6})', line)
            if not m: continue
            count=int(m.group(1)); r=int(m.group(2)); g=int(m.group(3)); b=int(m.group(4)); hexc=m.group(5)
            if r<15 and g<15 and b<15: continue
            if r>242 and g>242 and b>242: continue
            mx=max(r,g,b); mn=min(r,g,b)
            # saturacion 0-1 y luminosidad
            sat=(mx-mn)/255 if mx else 0
            avg=(r+g+b)/3
            # score: cuenta * (0.4 + saturacion) * boost si no es muy oscuro
            # penaliza grises y muy oscuros, premia vibrantes aunque sean menos frecuentes
            brightness_factor=1.0 if avg>=70 else 0.35
            score=count*(0.4+sat)*brightness_factor
            # desempate: si sat <0.12 es gris, reduce mucho
            if sat<0.12:
                score*=0.25
            if score>best_score:
                best_score=score; best_hex=hexc
    if best_hex:
        print(best_hex.lower())
    else:
        print("")
except Exception as e:
    print("", file=sys.stderr)
    print("")
PY
  )
  if [[ -z "$DOMINANT" || "$DOMINANT" == "" ]]; then
    # fallback to simple average
    DOMINANT=$(magick "$TMPFRAME" -resize 1x1 -format "#%[hex:p{0,0}]" info: 2>/dev/null | head -n1 | tr -d '\n' | cut -c1-7)
    # magick gives like #RRGGBB with maybe extra, ensure 7 chars
    DOMINANT=${DOMINANT,,}
    if [[ ! "$DOMINANT" =~ ^#[0-9a-f]{6}$ ]]; then
      DOMINANT="#f38d70"
    fi
  fi
  DOMINANT=$(echo "$DOMINANT" | tr '[:upper:]' '[:lower:]')
  echo "Dominant color: $DOMINANT"
fi

# Si el dominante es muy oscuro para el launcher, aclararlo (mantiene hue, sube lightness para que se vea sobre #2c2525)
if [[ "$DOMINANT" =~ ^#[0-9a-f]{6}$ ]]; then
  DOMINANT=$(python3 - "$DOMINANT" << 'PY'
import sys
hexc=sys.argv[1]
r=int(hexc[1:3],16); g=int(hexc[3:5],16); b=int(hexc[5:7],16)
# luminance aproximada (0-255)
lum=0.2126*r+0.7152*g+0.0722*b
avg=(r+g+b)/3
# si muy oscuro (<60) o gris muy apagado y oscuro, aclarar mezclando con blanco y subiendo saturacion
if lum<75 or avg<65:
    # mezcla 35% con blanco + boost de saturacion: empuja hacia tono mas vivo
    # lighten: mix con #e6d9db (foreground claro) para que armonice con tema dark
    # y luego aumenta saturacion un poco
    fr,fg,fb=0xe6,0xd9,0xdb
    t=0.38
    r=int(round(r*(1-t)+fr*t))
    g=int(round(g*(1-t)+fg*t))
    b=int(round(b*(1-t)+fb*t))
    # si aun muy oscuro, segunda pasada con blanco puro 15%
    if (0.2126*r+0.7152*g+0.0722*b)<85:
        r=int(round(r*0.85+255*0.15)); g=int(round(g*0.85+255*0.15)); b=int(round(b*0.85+255*0.15))
    print(f"#{r:02x}{g:02x}{b:02x}")
else:
    print(hexc)
PY
  )
fi
if [[ ! "$DOMINANT" =~ ^#[0-9a-f]{6}$ ]]; then
  DOMINANT="#f38d70"
fi

# Generate colors.toml - keep dark background, inject dominant as accent/blue
# We darken the dominant a bit for selection/muted to keep dark vibe
python3 - "$DOMINANT" "$THEME_DIR/colors.toml" << 'PY'
import sys
hexc=sys.argv[1]
path=sys.argv[2]
# hex to rgb
r=int(hexc[1:3],16); g=int(hexc[3:5],16); b=int(hexc[5:7],16)
# helper to mix with background for muted/selection
def mix(c1, c2, t):
    return tuple(int(round(a*(1-t)+b*t)) for a,b in zip(c1,c2))
bg=(0x2c,0x25,0x25) # ristretto bg
dark_bg=(0x21,0x1b,0x1b)
# selection = mix bg + dominant 25%
sel=mix(bg, (r,g,b), 0.22)
muted=mix((0x72,0x69,0x6a), (r,g,b), 0.15)
# lighter bg mix
lighter=mix(bg, (r,g,b), 0.08)
def tohex(t): return f"#{t[0]:02x}{t[1]:02x}{t[2]:02x}"
# darker accent for some shades?
# keep original dominant as accent/blue
with open(path, 'w') as f:
    f.write('mode = "dark"\n\n')
    f.write(f'accent = "{hexc}"\n')
    f.write(f'selection = "{tohex(sel)}"\n')
    f.write(f'muted = "{tohex(muted)}"\n\n')
    f.write(f'background = "{tohex(bg)}"\n')
    f.write(f'dark_background = "{tohex(dark_bg)}"\n')
    f.write(f'darker_background = "#181414"\n')
    f.write(f'lighter_background = "{tohex(lighter)}"\n\n')
    f.write(f'foreground = "#e6d9db"\n')
    f.write(f'dark_foreground = "#72696a"\n')
    f.write(f'light_foreground = "#c3b7b8"\n')
    f.write(f'bright_foreground = "#e6d9db"\n\n')
    # keep other ANSI but tint blue/magenta toward accent for cohesion
    f.write(f'red = "#fd6883"\n')
    f.write(f'yellow = "#f9cc6c"\n')
    f.write(f'orange = "#fb9a77"\n')
    f.write(f'green = "#adda78"\n')
    f.write(f'cyan = "#85dacc"\n')
    f.write(f'blue = "{hexc}"\n')
    f.write(f'magenta = "#a8a9eb"\n')
    f.write(f'brown = "#7d4d3b"\n\n')
    f.write(f'bright_red = "#ff8297"\n')
    f.write(f'bright_yellow = "#fcd675"\n')
    f.write(f'bright_green = "#c8e292"\n')
    f.write(f'bright_cyan = "#9bf1e1"\n')
    f.write(f'bright_blue = "{hexc}"\n')
    f.write(f'bright_magenta = "#bebffd"\n')
PY

echo "Generated $THEME_DIR/colors.toml with accent $DOMINANT"
cat "$THEME_DIR/colors.toml"

# Apply theme if not already video-dark, otherwise refresh
CURRENT=$(cat ~/.local/state/omarchy/current/theme.name 2>/dev/null || echo "")
if [[ "$CURRENT" != "$THEME_NAME" ]]; then
  echo "Setting theme $THEME_NAME..."
  omarchy theme set "$THEME_NAME" 2>&1 | tail -n 20
else
  echo "Refreshing theme $THEME_NAME..."
  omarchy theme refresh 2>&1 | tail -n 20
  # Force shell reload of background symlink
  omarchy-shell -q background set "$STATE_DIR/current-frame.jpg" 2>/dev/null || true
fi

# === Gap sin flash + animación garantizada ===
# 1) Kill mpvpaper RECÉN AHORA: el frame ya está listo, el gap mostrará LAST wallpaper (old displaywright image) sin flash negro.
#    SIGKILL evita teardown NVIDIA EGL (ver arriba).
if pgrep -x mpvpaper >/dev/null 2>&1; then
  pkill -KILL -x mpvpaper 2>/dev/null || true
  for _ in {1..20}; do pgrep -x mpvpaper >/dev/null 2>&1 || break; sleep 0.1; done
fi
# 2) Actualiza displaywright a frame VERSIONADO (path distinto → signature cambia → Surface wipe 420ms).
#    Esto hace que la transición sea visible justo en el gap donde ya no hay video.
if [[ -s "$TMPFRAME" ]]; then
  VERSIONED=$(cat "$STATE_DIR/.last_versioned_frame" 2>/dev/null || echo "")
  if [[ -n "$VERSIONED" && -f "$VERSIONED" ]]; then
    python3 - "$VERSIONED" "$DW_CONFIG" << 'PY'
import json, sys, pathlib, os, tempfile, json as _j
frame = sys.argv[1]
config_path = sys.argv[2]
# Detect monitores actuales para cubrir los 3 (fix gamemode 2/3)
try:
    import subprocess, json as js
    out = subprocess.check_output(["hyprctl","monitors","-j"], timeout=2)
    mons = [m["name"] for m in js.loads(out)]
except Exception:
    mons = ["HDMI-A-1","DP-1","HDMI-A-2"]
frame = str(pathlib.Path(frame).resolve())
data = {"version": 1, "monitors": {}}
for m in mons:
    data["monitors"][m] = {"kind": "image", "path": frame, "fit": "fill"}
d = os.path.dirname(config_path) or "."
os.makedirs(d, exist_ok=True)
# Lectura previa para no perder config si hay error
fd, tmp = tempfile.mkstemp(dir=d, prefix=".wallpapers.tmp.")
try:
    with os.fdopen(fd,'w') as f:
        _j.dump(data, f, indent=2); f.write("\n")
    os.replace(tmp, config_path)
except Exception:
    try: os.unlink(tmp)
    except: pass
    raise
PY
    # Dar tiempo a displaywright: inotify + Image async decode (evita wipe sobre rect vacío)
    sleep 0.45
  fi
fi

# Launch mpvpaper per output, loop, no audio.
# Use software decoding for stability: hwdec=vaapi/auto can create NVDEC/EGL
# contexts on NVIDIA and has been crashing in libGLX_nvidia during rotation.
# Rendering still uses the compositor/GPU, so the videos remain accelerated at
# presentation time; only video decode moves to the CPU. Vulkan avoids the
# NVIDIA GLX/EGL teardown path that was producing the crashes.
echo "Launching mpvpaper (hwdec=no, gpu-context=waylandvk)..."
MPVPAPER_OPTIONS="no-audio loop-file=inf hwdec=no load-scripts=no gpu-context=waylandvk"
for mon in $(hyprctl monitors -j 2>/dev/null | python3 -c "import json,sys; print(' '.join(m['name'] for m in json.load(sys.stdin)))" 2>/dev/null); do
  mpvpaper -f -o "$MPVPAPER_OPTIONS" "$mon" "$PICK" 2>/dev/null || true
done
# Fallback por si hyprctl no responde (ej. boot muy temprano)
if ! pgrep -x mpvpaper >/dev/null 2>&1; then
  for mon in HDMI-A-1 DP-1 HDMI-A-2; do
    mpvpaper -f -o "$MPVPAPER_OPTIONS" "$mon" "$PICK" 2>/dev/null || true
  done
fi

echo "Done. Video: $PICK  Accent: $DOMINANT"
# Solo notifica en fallo - no en éxito para no llenar notificaciones
# (fallos usan notify-send más arriba)

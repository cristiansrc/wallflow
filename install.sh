#!/bin/bash
# ============================================================================
#  wallflow — instalador portable
#  Video wallpaper rotation + live theming + game mode + picker para Omarchy
#
#  Uso:
#    ./install.sh            instala/actualiza (idempotente)
#    ./install.sh --remove   desinstala (deja estado y wallpapers intactos)
#    ./install.sh --help
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOME_DIR="${HOME}"
BIN_DIR="$HOME_DIR/.local/bin"
SYSTEMD_DIR="$HOME_DIR/.config/systemd/user"
THEMES_DIR="$HOME_DIR/.config/omarchy/themes"
PLUGINS_DIR="$HOME_DIR/.config/omarchy/plugins"
BINDINGS="$HOME_DIR/.config/hypr/bindings.lua"
SHELL_JSON="$HOME_DIR/.config/omarchy/shell.json"
WALLPAPER_DIR="$HOME_DIR/Wallpapers"
STATE_DIR="$HOME_DIR/.local/state/omarchy/video-wallpaper"

PLUGIN_ID="cristiansrc.wallpicker"
GAMEMODE_ID="cristiansrc.gamemode"
THEME_NAME="video-dark"

MARK_BEGIN="# >>> wallflow >>>"
MARK_END="# <<< wallflow <<<"

info()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,2\}//'
  exit 0
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

require_omarchy() {
  command -v omarchy >/dev/null 2>&1 || die "wallflow requiere Omarchy (https://omarchy.org)"
  command -v omarchy-shell >/dev/null 2>&1 || die "omarchy-shell no encontrado (Omarchy 4.x)"
}

check_deps() {
  local missing=()
  local dep
  for dep in mpvpaper ffmpeg ffprobe magick python3; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
  done
  if (( ${#missing[@]} )); then
    warn "Dependencias faltantes: ${missing[*]}"
    warn "Instálalas antes de usar wallflow. Ejemplo Arch: pacman -S mpvpaper ffmpeg imagemagick python"
    if [[ "${WALLFLOW_IGNORE_DEPS:-0}" != "1" ]]; then
      die "Abortando. (WALLFLOW_IGNORE_DEPS=1 para continuar igual)"
    fi
  fi
}

install_bins() {
  info "Instalando scripts en $BIN_DIR"
  install -Dm755 "$SCRIPT_DIR/bin/video-wallpaper-rotator.sh" "$BIN_DIR/video-wallpaper-rotator.sh"
  install -Dm755 "$SCRIPT_DIR/bin/rotate-wall"                "$BIN_DIR/rotate-wall"
  install -Dm755 "$SCRIPT_DIR/bin/gamemode-toggle.sh"         "$BIN_DIR/gamemode-toggle.sh"
}

install_systemd() {
  info "Instalando unidades systemd user (timer 2h)"
  install -Dm644 "$SCRIPT_DIR/systemd/user/video-wallpaper.service" "$SYSTEMD_DIR/video-wallpaper.service"
  install -Dm644 "$SCRIPT_DIR/systemd/user/video-wallpaper.timer"   "$SYSTEMD_DIR/video-wallpaper.timer"
  systemctl --user daemon-reload
  systemctl --user enable --now video-wallpaper.timer 2>/dev/null || true
}

install_theme() {
  info "Instalando tema $THEME_NAME (skeleton; colors.toml se regenera en cada rotación)"
  mkdir -p "$THEMES_DIR"
  cp -a "$SCRIPT_DIR/theme/$THEME_NAME" "$THEMES_DIR/"
}

install_plugin() {
  info "Instalando plugin $PLUGIN_ID"
  rm -rf "$PLUGINS_DIR/$PLUGIN_ID"
  cp -a "$SCRIPT_DIR/omarchy/plugin/$PLUGIN_ID" "$PLUGINS_DIR/$PLUGIN_ID"
}

patch_bindings() {
  info "Parcheando keybinds en bindings.lua (SUPER+ALT+W rotar, SUPER+ALT+P picker)"
  [[ -f "$BINDINGS" ]] || { warn "bindings.lua no existe; omarchy debería crearlo. Saltando binds."; return; }

  # Idempotente: si el picker ya está bindeado, no duplicar
  if grep -q "Wallpaper picker" "$BINDINGS"; then
    info "  binds ya presentes, sin cambios"
    return
  fi
  cat >>"$BINDINGS" <<EOF

$MARK_BEGIN
-- Rotate wallpaper (video random): SUPER+ALT+W
o.bind("SUPER + ALT + W", "Rotate wallpaper", "rotate-wall")

-- Selector visual de wallpapers (grid de ~/Wallpapers): SUPER+ALT+P
o.bind("SUPER + ALT + P", "Wallpaper picker", "omarchy-shell shell toggle $PLUGIN_ID")
$MARK_END
EOF
}

unpatch_bindings() {
  [[ -f "$BINDINGS" ]] || return
  if grep -q "$MARK_BEGIN" "$BINDINGS"; then
    python3 - "$BINDINGS" <<'PY'
import sys, re
path = sys.argv[1]
text = open(path).read()
text = re.sub(r'\n?# >>> wallflow >>>.*?# <<< wallflow <<<\n?', '\n', text, flags=re.S)
open(path, 'w').write(text)
PY
    info "  bloque de binds eliminado"
  fi
  # Limpieza de líneas sueltas de installs viejos sin marcadores
  sed -i '/Rotate wallpaper", "rotate-wall"/d; /Wallpaper picker", "omarchy-shell shell toggle/d' "$BINDINGS" 2>/dev/null || true
}

patch_shell_json() {
  info "Registrando plugins en shell.json"
  [[ -f "$SHELL_JSON" ]] || { warn "shell.json no encontrado, saltando"; return; }
  python3 - "$SHELL_JSON" install <<'PY'
import json, sys
path, action = sys.argv[1], sys.argv[2]
data = json.load(open(path))
changed = False

# plugins[] (overlays/servicios): wallpicker
plugins = data.get("plugins", [])
if not any(isinstance(p, dict) and p.get("id") == "cristiansrc.wallpicker" for p in plugins):
    plugins.append({"id": "cristiansrc.wallpicker"})
    data["plugins"] = plugins
    changed = True
    print("  wallpicker añadido a plugins[]")
else:
    print("  wallpicker ya registrado en plugins[]")

# bar.layout.right: botón gamemode
bar = data.setdefault("bar", {}).setdefault("layout", {})
right = bar.setdefault("right", [])
if not any(isinstance(e, dict) and e.get("id") == "cristiansrc.gamemode" for e in right):
    right.append({"id": "cristiansrc.gamemode"})
    changed = True
    print("  gamemode añadido a bar.layout.right")
else:
    print("  gamemode ya presente en bar.layout.right")

if changed:
    json.dump(data, open(path, "w"), indent=2)
PY
}

patch_shell_json_remove() {
  [[ -f "$SHELL_JSON" ]] || return
  python3 - "$SHELL_JSON" remove <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
changed = False
plugins = [p for p in data.get("plugins", []) if not (isinstance(p, dict) and p.get("id") == "cristiansrc.wallpicker")]
if len(plugins) != len(data.get("plugins", [])):
    data["plugins"] = plugins
    changed = True
bar = data.get("bar", {})
layout = bar.get("layout", {})
if "right" in layout:
    right = [e for e in layout["right"] if not (isinstance(e, dict) and e.get("id") == "cristiansrc.gamemode")]
    if len(right) != len(layout["right"]):
        layout["right"] = right
        changed = True
if changed:
    json.dump(data, open(path, "w"), indent=2)
PY
}

ensure_wallpapers() {
  if [[ ! -d "$WALLPAPER_DIR" ]]; then
    mkdir -p "$WALLPAPER_DIR"
    warn "Creado $WALLPAPER_DIR — poné ahí tus videos (.mp4/.webm)"
  elif ! compgen -G "$WALLPAPER_DIR/*.mp4" >/dev/null && ! compgen -G "$WALLPAPER_DIR/*.webm" >/dev/null; then
    warn "No hay videos en $WALLPAPER_DIR — la rotación fallará hasta que agregues"
  fi
}

check_displaywright() {
  if [[ ! -d "$PLUGINS_DIR/ai.bkblab.displaywright" ]]; then
    warn "displaywright NO está instalado. wallflow lo usa para fondo estático del"
    warn "modo juego y para la animación wipe. Instálalo con:"
    warn "  omarchy plugin add https://github.com/BlackKingBarOrg/displaywright-shell-plugin.git --enable"
  fi
}

restart_session() {
  info "Recargando Hyprland (keybinds)"
  hyprctl reload >/dev/null 2>&1 || warn "hyprctl reload falló"
  info "Reiniciando omarchy-shell (plugin picker)"
  /usr/bin/omarchy-restart-shell >/dev/null 2>&1 || warn "omarchy-restart-shell falló (reinicialo a mano)"
}

first_rotation_hint() {
  if [[ ! -f "$STATE_DIR/last_video.txt" ]]; then
    info "Primera rotación se disparará con el timer (~1 min tras boot) o con: systemctl --user start video-wallpaper.service"
  fi
}

do_install() {
  require_omarchy
  check_deps
  install_bins
  install_systemd
  install_theme
  install_plugin
  patch_bindings
  patch_shell_json
  ensure_wallpapers
  check_displaywright
  restart_session
  first_rotation_hint
  info "wallflow instalado. Keybinds: SUPER+ALT+W rotar · SUPER+ALT+P picker · botón gamepad en la barra = modo juego"
}

do_remove() {
  info "Desinstalando wallflow"
  systemctl --user disable --now video-wallpaper.timer 2>/dev/null || true
  rm -f "$SYSTEMD_DIR/video-wallpaper.service" "$SYSTEMD_DIR/video-wallpaper.timer"
  systemctl --user daemon-reload
  rm -f "$BIN_DIR/video-wallpaper-rotator.sh" "$BIN_DIR/rotate-wall" "$BIN_DIR/gamemode-toggle.sh"
  rm -rf "$PLUGINS_DIR/$PLUGIN_ID" "$PLUGINS_DIR/$GAMEMODE_ID"
  rm -rf "$THEMES_DIR/$THEME_NAME"
  unpatch_bindings
  patch_shell_json_remove
  restart_session
  info "Listo. Estado (~/.local/state/omarchy/video-wallpaper, game-mode) y ~/Wallpapers intactos."
}

patch_shell_json_remove_helper() {
  [[ -f "$SHELL_JSON" ]] || return
  python3 - "$SHELL_JSON" "$PLUGIN_ID" remove <<'PY'
import json, sys
path, plugin_id = sys.argv[1], sys.argv[2]
data = json.load(open(path))
before = len(data.get("plugins", []))
data["plugins"] = [p for p in data.get("plugins", []) if not (isinstance(p, dict) and p.get("id") == plugin_id)]
if len(data["plugins"]) != before:
    json.dump(data, open(path, "w"), indent=2)
PY
}

case "${1:-install}" in
  install)  do_install ;;
  --remove|-r) do_remove ;;
  *) usage ;;
esac

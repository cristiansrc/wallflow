#!/bin/bash
# Aplica un video del picker vía el pipeline completo existente.
# Uso: apply-wall.sh /ruta/absoluta/video.mp4
set -u
video="${1:-}"
[[ -n "$video" && -f "$video" ]] || exit 1

notify() {
  omarchy-notification-send "Wallpaper" "$1" -t 3000 2>/dev/null \
    || notify-send "Wallpaper" "$1" 2>/dev/null || true
}

# Si modo juego activo: apagarlo primero (restaura blur/animaciones y displaywright)
if [[ -f "$HOME/.local/state/omarchy/game-mode/active" ]]; then
  "$HOME/.local/bin/gamemode-toggle.sh" >/dev/null 2>&1
  sleep 0.4
fi

notify "Aplicando — $(basename "$video")"

# rotate-wall acepta ruta absoluta y ya reinicia el countdown del timer
# (marcador skip-once + activación del servicio). Hace TODO: frame versionado,
# displaywright en los 3 monitores, animación wipe, tema con color dominante,
# mpvpaper.
"$HOME/.local/bin/rotate-wall" "$video" >/dev/null 2>&1

notify "Listo — $(basename "$video")"

#!/bin/bash
# Escanea ~/Wallpapers y emite líneas TSV para el overlay wallpicker:
#   ROW\t<path>\t<nombre>\t<thumb-vacio-o-full>
#   THUMB\t<path>\t<thumb>          (cuando ffmpeg termina cada miniatura faltante)
# Miniaturas cacheadas por hash de path+size+mtime en ~/.cache/wallpicker
# Orden: alfabético global (todas las extensiones mezcladas).
set -u

DIR="${1:-$HOME/Wallpapers}"
CACHE="${HOME}/.cache/wallpicker"
mkdir -p "$CACHE"
# tmp huérfanos de corridas interrumpidas
rm -f "$CACHE"/*.tmp.* 2>/dev/null || true

emit() { printf '%b\n' "$*"; }
row() { emit "ROW\\t${1}\\t${2}\\t${3}"; }
thumb_done() { emit "THUMB\\t${1}\\t${2}"; }

shopt -s nullglob nocaseglob
files=()
for f in "$DIR"/*.mp4 "$DIR"/*.webm "$DIR"/*.mkv "$DIR"/*.mov "$DIR"/*.avi; do
  [[ -f "$f" ]] || continue
  files+=("$f")
done

# Orden alfabético por basename (LC_ALL=C, estable)
mapfile -t sorted < <(
  for f in "${files[@]}"; do printf '%s\t%s\n' "$(basename "$f")" "$f"; done | LC_ALL=C sort -t "$(printf '\t')" -k1,1 | cut -f2
)

pending=()
for f in "${sorted[@]}"; do
  [[ -n "$f" && -f "$f" ]] || continue
  sig=$(stat -Lc '%s:%Y' -- "$f" 2>/dev/null) || continue
  key=$(printf '%s:%s' "$f" "$sig" | sha1sum | cut -c1-12)
  thumb="$CACHE/$key.jpg"
  name=$(basename "$f")
  if [[ -s "$thumb" ]]; then
    row "$f" "$name" "$thumb"
  else
    row "$f" "$name" ""
    pending+=("$f|$thumb")
  fi
done

# Genera faltantes en orden; emite THUMB por cada uno (el grid se llena en vivo)
for item in "${pending[@]}"; do
  f="${item%%|*}"
  thumb="${item#*|}"
  tmp="$thumb.tmp.$$"
  # -ss 2 seek rápido antes de abrir input; scale 480 ancho; sin audio;
  # -f image2 porque el tmp no tiene extensión .jpg (escritura atómica)
  ffmpeg -nostdin -y -v error -ss 2 -i "$f" -an -map 0:v:0 -vframes 1 \
    -f image2 -vf "scale=480:-2:flags=bicubic" -q:v 5 "$tmp" 2>/dev/null
  if [[ -s "$tmp" ]]; then
    mv -f "$tmp" "$thumb"
    thumb_done "$f" "$thumb"
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
done
emit "DONE"

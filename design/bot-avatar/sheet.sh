#!/usr/bin/env bash
# Contact sheet of every style (rows) and state 0-4 (columns) from the WebPs
# frames.sh wrote: ./sheet.sh <webp dir> [out.png, default styles.png]
set -euo pipefail
src=${1:?usage: sheet.sh <webp dir> [out.png]}; out=${2:-styles.png}
styles=${STYLES:-"default inbox researcher coder checker blogger pa"}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pick=(0 15 3 4 -1)   # a telling frame per state: rest, looking, scanning, pulse peak, final pose
rows=()
for style in $styles; do
  cells=()
  for state in 0 1 2 3 4; do
    magick "$src/$style-$state.webp" -coalesce "$work/f-%03d.png"
    frames=("$work"/f-*.png); i=${pick[$state]}; [ "$i" -lt 0 ] && i=$((${#frames[@]} - 1))
    cp "${frames[$i]}" "$work/$style-$state.png"; rm -f "$work"/f-*.png
    cells+=("$work/$style-$state.png")
  done
  magick "${cells[@]}" -background '#101418' -resize 80x80 -gravity center -extent 80x80 +append "$work/row-$style.png"
  rows+=("$work/row-$style.png")
done
magick "${rows[@]}" -background '#101418' -append -bordercolor '#101418' -border 8 "$out"
echo "wrote $out"

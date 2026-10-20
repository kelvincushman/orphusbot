#!/usr/bin/env bash
# Contact sheets from the WebPs frames.sh wrote:
#   ./sheet.sh <webp dir> [out.png] [library.png]
# out.png (default styles.png): every style (rows) by state 0-4 (columns).
# library.png (default styles-library.png): state 0 of every style in a
# labelled grid, for picking a face.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=${1:?usage: sheet.sh <webp dir> [out.png] [library.png]}
out=${2:-styles.png}; lib=${3:-styles-library.png}
styles=${STYLES:-$(cat "$here/styles.txt")}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pick=(0 7 3 4 -1)   # a telling frame per state: rest, looking, scanning, pulse peak, final pose
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
labelled=()
for style in $styles; do
  magick "$work/$style-0.png" -background '#101418' -resize 80x80 -gravity center -extent 96x84 \
    -font "${FONT:-Liberation-Sans}" -fill '#C9D1DC' -pointsize 13 -gravity south -splice 0x18 -annotate +0+2 "$style" "$work/lib-$style.png"
  labelled+=("$work/lib-$style.png")
done
magick montage "${labelled[@]}" -tile 6x -geometry +4+4 -background '#101418' "$lib"
echo "wrote $out $lib"

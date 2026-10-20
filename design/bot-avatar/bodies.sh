#!/usr/bin/env bash
# Sheets of the Robot artboard: ./bodies.sh [bodies.png] [bodies-states.png]
#   bodies.png         every style at rest (state 0), labelled, in a grid
#   bodies-states.png  a few styles (SHOW="a b ...") across states 0-5, with the
#                      self-destruct shown as shake, boom, flying apart, dizzy
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rive=${RIVE:-$HOME/.rive/bin/rive}
out=${1:-bodies.png}; out2=${2:-bodies-states.png}
styles=${STYLES:-$(cat "$here/styles.txt")}
show=${SHOW:-"default coder bolt fox orchestrator sprout"}
font=${FONT:-Liberation-Sans}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
shot() {   # shot <style> <state> <frames> <png>
  local d="$work/p-$1-$2-$3"; mkdir -p "$d"; cp "$here/rive.yaml" "$d/"
  python3 "$here/gen.py" "$1" "$2" >"$d/scene.rml"
  (cd "$d" && "$rive" . --quiet --artboard=Robot --screenshot="$4" --advance="$3" >/dev/null 2>&1)
  magick "$4" -fuzz 3% -fill '#101418' -opaque '#1D1D1D' "$4"
}
cells=()
for style in $styles; do
  shot "$style" 0 30 "$work/$style.png"
  magick "$work/$style.png" -resize 120x156 -background '#101418' -gravity south -splice 0x18 \
    -font "$font" -fill '#C9D1DC' -pointsize 13 -annotate +0+2 "$style" "$work/l-$style.png"
  cells+=("$work/l-$style.png")
done
magick montage "${cells[@]}" -tile 10x -geometry +2+2 -background '#101418' "$out"
# state, frames to advance, column label
cols=("0 50 idle" "1 50 thinking" "2 20 working" "3 12 needs you" "4 26 done" "5 30 5: shake" "5 52 5: boom" "5 76 5: apart" "5 260 5: dizzy")
rows=()
for style in $show; do
  row=()
  for c in "${cols[@]}"; do
    read -r st fr label <<<"$c"
    shot "$style" "$st" "$fr" "$work/s-$style-$st-$fr.png"
    row+=("$work/s-$style-$st-$fr.png")
  done
  magick "${row[@]}" -resize 120x156 +append "$work/row-$style.png"; rows+=("$work/row-$style.png")
done
labels=()
for c in "${cols[@]}"; do
  read -r st fr label <<<"$c"
  magick -size 120x22 xc:'#101418' -font "$font" -fill '#C9D1DC' -pointsize 13 -gravity center -annotate +0+0 "$label" "$work/h-$fr-$st.png"
  labels+=("$work/h-$fr-$st.png")
done
magick "${labels[@]}" +append "$work/head.png"
magick "$work/head.png" "${rows[@]}" -background '#101418' -append -bordercolor '#101418' -border 8 "$out2"
echo "wrote $out $out2"

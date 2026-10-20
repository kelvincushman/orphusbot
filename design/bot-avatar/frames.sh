#!/usr/bin/env bash
# Renders each face style and state as an animated WebP for places that can't
# play Rive, such as the Omarchy bar panel (QML): ./frames.sh <out dir>
# writes <out>/<style>-<state>.webp for every style (STYLES="a b" to limit).
# One full loop per state (20 fps; 10 fps for the slow resting and thinking
# loops), drawn at 400 px, the screenshot's background (#1D1D1D) cut out, then
# shrunk to 56 px (the panel shows them at about 26) to keep the files small;
# done plays once.
set -euo pipefail
mkdir -p "${1:?usage: frames.sh <out dir>}"
out=$(realpath "$1")
here=$(cd "$(dirname "$0")" && pwd)
rive=${RIVE:-$HOME/.rive/bin/rive}
styles=${STYLES:-$(cat "$here/styles.txt")}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
for style in $styles; do
  # state: first frame (after the 200 ms blend in), frames in one loop
  for spec in "0 240 240" "1 180 180" "2 60 60" "3 60 60" "4 1 54"; do
    read -r state from count <<<"$spec"
    dir="$work/$style-$state"; mkdir -p "$dir"; cp "$here/rive.yaml" "$dir/"
    python3 "$here/gen.py" "$style" "$state" >"$dir/scene.rml"
    step=3; [ "$state" -le 1 ] && step=6
    for ((f = 0; f < count; f += step)); do
      (cd "$dir" && "$rive" . --quiet --viewport=400x400 --fit=contain \
        --screenshot="$dir/$(printf %03d $f).png" --advance=$((from + f)) >/dev/null 2>&1)
    done
    loop=0; [ "$state" = 4 ] && loop=1   # done plays once and stays
    magick -delay $((step * 5 / 3)) -dispose background "$dir"/[0-9]*.png \
      -fuzz 4% -transparent '#1D1D1D' -resize 56x56 -loop $loop \
      -quality 90 -define webp:alpha-quality=100 "$out/$style-$state.webp"
  done
done
ls -l "$out"

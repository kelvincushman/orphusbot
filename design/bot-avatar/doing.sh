#!/usr/bin/env bash
# Sheets of what state 2 is doing and the hand-off reactions, every style a row:
# ./doing.sh [doing.png] [doing-faces.png]
#   doing.png        the Robot artboard: doing 0-9 (state 2), then give and receive
#   doing-faces.png  the same for the Avatar artboard
# Check by eye: each prop is visible, the right way up and clear of the face.
# STYLES="a b" limits the rows; JOBS (default 3) styles render at once.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rive=${RIVE:-$HOME/.rive/bin/rive}
out=$(realpath "${1:-doing.png}"); out2=$(realpath "${2:-doing-faces.png}")
styles=${STYLES:-$(cat "$here/styles.txt")}
font=${FONT:-Liberation-Sans}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
# label, state, doing, reaction, frames to advance (props have settled by 75; the reactions are mid-reach)
cols=("0 other:2:0::75" "1 read:2:1::75" "2 write:2:2::75" "3 command:2:3::75" "4 browse:2:4::75" "5 search:2:5::75"
      "6 talk:2:6::75" "7 google:2:7::75" "8 media:2:8::75" "9 phone:2:9::75" "give:0:0:give:26" "receive:0:0:receive:20")
row() {   # row <style>: one strip per artboard
  local style=$1 n=0 d
  for c in "${cols[@]}"; do
    IFS=: read -r _ st doing fire fr <<<"$c"
    d="$work/$style/$((n++))"; mkdir -p "$d"; cp "$here/rive.yaml" "$d/"
    python3 "$here/gen.py" "$style" "$st" "$doing" $fire >"$d/scene.rml"
    for a in Robot Avatar; do
      (cd "$d" && "$rive" . --quiet --artboard=$a --screenshot="$d/$a.png" --advance="$fr" >/dev/null 2>&1)
    done
  done
  for a in Robot Avatar; do
    magick -size 90x130 xc:'#1D1D1D' -font "$font" -fill '#C9D1DC' -pointsize 13 -gravity center -annotate +0+0 "$style" \
      $(for ((i = 0; i < n; i++)); do echo "$work/$style/$i/$a.png"; done) -resize x130 -gravity center -background '#1D1D1D' +append "$work/$a-$style.png"
  done
}
for style in $styles; do
  row "$style" &
  while (($(jobs -rp | wc -l) >= ${JOBS:-3})); do wait -n; done
done
wait
for a in Robot Avatar; do
  w=$([ $a = Robot ] && echo 100 || echo 130)   # a cell's width at 130 px high
  heads=(-size 90x22 xc:'#1D1D1D')
  for c in "${cols[@]}"; do
    heads+=(\( -size "${w}x22" xc:'#1D1D1D' -font "$font" -fill '#C9D1DC' -pointsize 12 -gravity center -annotate +0+0 "${c%%:*}" \))
  done
  magick "${heads[@]}" +append "$work/head-$a.png"
  magick "$work/head-$a.png" $(for s in $styles; do echo "$work/$a-$s.png"; done) -background '#1D1D1D' -append -depth 8 \
    -bordercolor '#1D1D1D' -border 8 "$([ $a = Robot ] && echo "$out" || echo "$out2")"
done
echo "wrote $out $out2"

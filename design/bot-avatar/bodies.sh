#!/usr/bin/env bash
# Sheets, mostly of the Robot artboard:
# ./bodies.sh [bodies.png] [bodies-states.png] [doing.png] [doing-faces.png]
#   bodies.png         every style at rest (state 0), labelled, in a grid
#   bodies-states.png  a few styles (SHOW="a b ...") across states 0-5, with the
#                      self-destruct shown as shake, boom, flying apart, dizzy
#   doing.png          every style a row: `doing` 0-9 in state 2, then give and receive
#   doing-faces.png    the same for the Avatar artboard
# Check the last two by eye: each prop visible, the right way up, clear of the face.
# They take a while; JOBS (default 3) styles render at once.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rive=${RIVE:-$HOME/.rive/bin/rive}
out=${1:-bodies.png}; out2=${2:-bodies-states.png}; out3=${3:-doing.png}; out4=${4:-doing-faces.png}
styles=${STYLES:-$(cat "$here/styles.txt")}
show=${SHOW:-"default coder bolt fox orchestrator sprout"}
font=${FONT:-Liberation-Sans}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
shot() {   # shot <style> <state> <frames> <png> [artboard] [doing] [poke|give|receive]
  local d="$work/p-$1-$2-$3-${5:-}-${6:-}-${7:-}"; mkdir -p "$d"; cp "$here/rive.yaml" "$d/"
  python3 "$here/gen.py" "$1" "$2" ${6:+"$6"} ${7:+"$7"} >"$d/scene.rml"
  (cd "$d" && "$rive" . --quiet --artboard="${5:-Robot}" --screenshot="$4" --advance="$3" >/dev/null 2>&1)
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
# doing: column label, doing, reaction, frames (props have settled by 75; the reactions are mid-reach)
dcols=("0 other:0::75" "1 read:1::75" "2 write:2::75" "3 command:3::75" "4 browse:4::75" "5 search:5::75" "6 talk:6::75"
       "7 google:7::75" "8 media:8::75" "9 phone:9::75" "give:0:give:26" "receive:0:receive:20")
drow() {   # drow <style>: a labelled strip for each artboard
  local a c doing fire fr strip
  for a in Robot Avatar; do
    magick -size 90x130 xc:'#101418' -font "$font" -fill '#C9D1DC' -pointsize 13 -gravity center -annotate +0+0 "$1" "$work/dl-$a-$1.png"
    strip=("$work/dl-$a-$1.png")
    for c in "${dcols[@]}"; do
      IFS=: read -r _ doing fire fr <<<"$c"
      shot "$1" "$([ -n "$fire" ] && echo 0 || echo 2)" "$fr" "$work/d-$a-$1-$doing-$fire.png" "$a" "$doing" "$fire"
      strip+=("$work/d-$a-$1-$doing-$fire.png")
    done
    magick "${strip[@]}" -resize x130 +append "$work/d-$a-$1.png"
  done
}
for style in $styles; do
  drow "$style" &
  while (($(jobs -rp | wc -l) >= ${JOBS:-3})); do wait -n; done
done
wait
for a in Robot Avatar; do
  w=$([ $a = Robot ] && echo 100 || echo 130)   # a cell's width at 130 px high
  sheet=(\( -size 90x22 xc:'#101418')
  for c in "${dcols[@]}"; do
    sheet+=(\( -size "${w}x22" xc:'#101418' -font "$font" -fill '#C9D1DC' -pointsize 12 -gravity center -annotate +0+0 "${c%%:*}" \))
  done
  sheet+=(+append \))
  for style in $styles; do sheet+=("$work/d-$a-$style.png"); done
  magick "${sheet[@]}" -background '#101418' -append -depth 8 -bordercolor '#101418' -border 8 "$([ $a = Robot ] && echo "$out3" || echo "$out4")"
done
echo "wrote $out $out2 $out3 $out4"

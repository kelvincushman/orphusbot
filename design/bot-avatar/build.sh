#!/usr/bin/env bash
# Builds every style to build/faces/<style>.riv (artboards Avatar and Robot): ./build.sh
# Each style is generated into its own temp project, verified, inspected for
# problems, then built; a file over 25 KB is reported.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rive=${RIVE:-$HOME/.rive/bin/rive}
styles=${STYLES:-$(cat "$here/styles.txt")}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$here/build/faces"
for style in $styles; do
  mkdir -p "$work/$style"; cp "$here/rive.yaml" "$work/$style/"
  python3 "$here/gen.py" "$style" 0 >"$work/$style/scene.rml"
  (cd "$work/$style" && "$rive" . --verify --quiet &&
    { report=$("$rive" inspect . --summary); grep -q '"problems": \[\]' <<<"$report" || { echo "$style: rive inspect reports problems" >&2; exit 1; }; } &&
    "$rive" . --once --quiet)
  size=$(stat -c%s "$work/$style/build/bot-avatar.riv")
  [ "$size" -le 25600 ] || echo "warning: $style.riv is $size bytes, over 25 KB" >&2
  cp "$work/$style/build/bot-avatar.riv" "$here/build/faces/$style.riv"
done
ls -l "$here/build/faces"

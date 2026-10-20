#!/usr/bin/env bash
# Builds every face style to build/faces/<style>.riv: ./build.sh
# Each style is generated into its own temp project, verified, then built.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rive=${RIVE:-$HOME/.rive/bin/rive}
styles=${STYLES:-$(cat "$here/styles.txt")}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$here/build/faces"
for style in $styles; do
  mkdir -p "$work/$style"; cp "$here/rive.yaml" "$work/$style/"
  python3 "$here/gen.py" "$style" 0 >"$work/$style/scene.rml"
  (cd "$work/$style" && "$rive" . --verify --quiet && "$rive" . --once --quiet)
  cp "$work/$style/build/bot-avatar.riv" "$here/build/faces/$style.riv"
done
ls -l "$here/build/faces"

#!/usr/bin/env bash
# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
#
# Idempotent copyright-header injector for this repository.
#
# Usage:
#   scripts/add-copyright-headers.sh                # dry-run: list files that would be modified
#   scripts/add-copyright-headers.sh --apply        # actually inject headers
#   scripts/add-copyright-headers.sh --apply --root <path>   # target a custom subtree
#
# Behaviour:
#   - Walks the target tree (default: repository root)
#   - For each supported file extension, checks if the Kelvin header is already
#     present (grep for the copyright line). If yes, skip.
#   - If no, inserts the correct header style for the file type:
#       C family / Dart / Swift   → C-style block comment at top
#       Python / Shell / YAML / Kconfig / DTS / Zephyr conf → hash prefix
#       Markdown                  → HTML comment
#     Shell files get the header AFTER the shebang line.
#   - Files authored fresh by us (NEW in the monorepo, not copied from upstream
#     kelvinlee) can omit the "Derived from BasedHardware/kelvinlee" line. This script
#     always includes the derivation line since its primary purpose is marking
#     copied files. Set --no-derivation to drop it (e.g. for brand-new files).
#   - A sentinel file ".no-copyright" in a directory skips the whole subtree.
#
# Exit codes:
#   0  = success (or dry-run listed what it would do)
#   1  = no files matched or target dir missing
#   2  = argument error

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${REPO_ROOT}"
APPLY=0
INCLUDE_DERIVATION=1

usage() {
  sed -n '2,25p' "$0"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --root) TARGET="$2"; shift 2 ;;
    --no-derivation) INCLUDE_DERIVATION=0; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

if [[ ! -d "$TARGET" ]]; then
  echo "Target not found: $TARGET" >&2
  exit 1
fi

COPYRIGHT_LINE="Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT."
DERIVATION_LINE="Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM)."

# Build the header body (with or without derivation line)
header_body() {
  printf '%s' "$COPYRIGHT_LINE"
  if [[ $INCLUDE_DERIVATION -eq 1 ]]; then
    printf ' %s' "$DERIVATION_LINE"
  fi
}

has_header() {
  # Check the first 10 lines for the copyright line
  head -n 10 "$1" 2>/dev/null | grep -qF "$COPYRIGHT_LINE"
}

# Returns the header block for a file based on extension
# Args: file_path
header_for() {
  local f="$1" body
  body="$(header_body)"
  case "$f" in
    *.c|*.h|*.cpp|*.hpp|*.cc|*.dart|*.swift|*.java|*.js|*.ts|*.tsx)
      printf '/* %s */\n\n' "$body"
      ;;
    *.py|*.sh|*.bash|*.yaml|*.yml|*.overlay|*.conf|*.dts|*.dtsi|Kconfig|*.cmake|*.mk|Makefile|CMakeLists.txt)
      printf '# %s\n\n' "$body"
      ;;
    *.md|*.markdown|*.html|*.xml)
      printf '<!-- %s -->\n\n' "$body"
      ;;
    *)
      return 1   # unsupported extension
      ;;
  esac
}

# Inject header into a file, preserving shebang if present.
# The header is emitted with an explicit trailing blank line. Note: bash's
# command substitution `$(...)` strips ALL trailing newlines, so we can't rely
# on newlines inside the captured $hdr — we always append "\n\n" here.
inject() {
  local f="$1" hdr="$2" tmp
  tmp="$(mktemp)"
  if head -n 1 "$f" | grep -q '^#!'; then
    head -n 1 "$f" > "$tmp"
    printf '\n%s\n\n' "$hdr" >> "$tmp"
    tail -n +2 "$f" >> "$tmp"
  else
    printf '%s\n\n' "$hdr" > "$tmp"
    cat "$f" >> "$tmp"
  fi
  mv "$tmp" "$f"
}

count_added=0
count_skipped_has_header=0
count_skipped_unsupported=0
count_skipped_sentinel=0

while IFS= read -r -d '' f; do
  # Skip anything under a dir with a .no-copyright sentinel
  d="$f"
  skip=0
  while [[ "$d" != "$TARGET" && "$d" != "/" ]]; do
    d="$(dirname "$d")"
    if [[ -f "$d/.no-copyright" ]]; then skip=1; break; fi
  done
  if [[ $skip -eq 1 ]]; then
    count_skipped_sentinel=$((count_skipped_sentinel + 1))
    continue
  fi

  # Skip binary files
  if ! file --mime-encoding "$f" 2>/dev/null | grep -qv 'binary$'; then
    count_skipped_unsupported=$((count_skipped_unsupported + 1))
    continue
  fi

  # Build header block for this file
  if ! hdr="$(header_for "$f")"; then
    count_skipped_unsupported=$((count_skipped_unsupported + 1))
    continue
  fi

  if has_header "$f"; then
    count_skipped_has_header=$((count_skipped_has_header + 1))
    continue
  fi

  if [[ $APPLY -eq 1 ]]; then
    inject "$f" "$hdr"
    echo "[added] $f"
  else
    echo "[would-add] $f"
  fi
  count_added=$((count_added + 1))
done < <(find "$TARGET" -type f ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/build/*' ! -path '*/.dart_tool/*' -print0)

echo
echo "Summary:"
if [[ $APPLY -eq 1 ]]; then
  echo "  headers added:        $count_added"
else
  echo "  headers that WOULD be added: $count_added  (run again with --apply)"
fi
echo "  already had header:   $count_skipped_has_header"
echo "  unsupported / binary: $count_skipped_unsupported"
echo "  skipped (.no-copyright sentinel): $count_skipped_sentinel"

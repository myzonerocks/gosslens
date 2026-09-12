#!/usr/bin/env bash
# changelog-cut.sh --show prints the Unreleased section of CHANGELOG.md.
# changelog-cut.sh <tag> [date] moves that section under the tag, leaves a
# fresh empty Unreleased above it, and prints the section it cut.
set -euo pipefail
cd "$(dirname "$0")/.."
file=CHANGELOG.md

section() {
  awk -v head="$1" '
    $0 == head { on = 1; next }
    /^## / && on { exit }
    on { print }
  ' "$file" | awk 'NF { blank = 0 } !NF { blank++ } blank < 2' | sed -e '1{/^$/d;}' -e '${/^$/d;}'
}

if [ "${1:-}" = "--show" ]; then
  section "## Unreleased"
  exit 0
fi

tag="${1:?usage: changelog-cut.sh --show | <tag> [date]}"
date="${2:-$(date -u +%Y-%m-%d)}"

# A release rebuilt for the same version has already been cut; print what it cut then.
if grep -q "^## ${tag} (" "$file"; then
  section "$(grep -m1 "^## ${tag} (" "$file")"
  exit 0
fi

awk -v tag="$tag" -v date="$date" '
  /^## Unreleased/ && !seen { print; print ""; print "## " tag " (" date ")"; seen = 1; next }
  { print }
' "$file" > "$file.next"
mv "$file.next" "$file"
section "## $tag ($date)"

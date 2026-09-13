#!/bin/sh
# Zips a packaged lens (.lens-packages/<name>) the way a catalogue serves it: manifest.json
# at the archive root, plus a json sidecar with the sha256 and byte count a client verifies
# before unpacking. usage: tools/lens-zip.sh .lens-packages/<name> <out-dir>
set -eu
[ $# -eq 2 ] || { echo "usage: $0 <package-dir> <out-dir>" >&2; exit 2; }
pkg=$(cd "$1" && pwd)
name=$(basename "$pkg")
out=$(mkdir -p "$2" && cd "$2" && pwd)
[ -f "$pkg/manifest.json" ] || { echo "$pkg has no manifest.json" >&2; exit 1; }
zip="$out/$name.zip"
rm -f "$zip"
(cd "$pkg" && find . -type f ! -name '.DS_Store' | sed 's#^\./##' | LC_ALL=C sort | zip -q -X -D "$zip" -@)
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
bytes=$(wc -c < "$zip" | tr -d ' ')
printf '{"id":"%s","sha256":"%s","bytes":%s}\n' "$name" "$sha" "$bytes" > "$out/$name.json"

# Verify what a client verifies, so the archive is checked rather than trusted: the
# sidecar's digest and byte count against the file on disk, and manifest.json at the
# archive root where an unpacker looks for it first.
back=$(shasum -a 256 "$zip" | cut -d' ' -f1)
[ "$back" = "$sha" ] || { echo "$zip digest changed under the sidecar" >&2; exit 1; }
[ "$(wc -c < "$zip" | tr -d ' ')" = "$bytes" ] || { echo "$zip size does not match the sidecar" >&2; exit 1; }
grep -q '"sha256":"'"$sha"'"' "$out/$name.json" || { echo "$out/$name.json does not carry the digest" >&2; exit 1; }
unzip -l "$zip" | grep -qE ' manifest\.json$' || { echo "$zip has no manifest.json at its root" >&2; exit 1; }
echo "$zip $bytes $sha"

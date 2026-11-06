#!/usr/bin/env bash

# Rewrites the version a reader copies out of the install docs, so a pasted
# line is always a real published version, never a placeholder that fails to
# resolve. The release job runs it once the tag is known. The Swift line is a
# floor SwiftPM resolves forward from, so it only has to name a real release.
set -euo pipefail

version="${1:?usage: stamp-doc-versions.sh <version>}"
case "$version" in
  v*) version="${version#v}" ;;
esac

# The suffix is part of the version: without it a prerelease tag replaces the
# numbers and leaves the old suffix behind, and every release compounds it.
semver='[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}\(-[0-9A-Za-z.]\{1,\}\)\{0,1\}'

# Maven coordinate, JitPack coordinate (v-prefixed), and the SwiftPM floor.
sed -i.bak \
  -e "s|io\.github\.avosa:gosslens:${semver}|io.github.avosa:gosslens:${version}|g" \
  -e "s|com\.github\.myzonerocks:gosslens:v${semver}|com.github.myzonerocks:gosslens:v${version}|g" \
  -e "s|\(myzonerocks/gosslens\", from: \"\)${semver}|\1${version}|g" \
  README.md sdk/swift/README.md sdk/kotlin/README.md
rm -f README.md.bak sdk/swift/README.md.bak sdk/kotlin/README.md.bak

# The three SDKs carry one shared version equal to the engine's. The release
# overrides both at publish time, so only the tracked files drift.
sed -i.bak -e "s|^VERSION_NAME=${semver}$|VERSION_NAME=${version}|" sdk/kotlin/gradle.properties
sed -i.bak -e "s|\(\"version\": \"\)${semver}|\1${version}|" sdk/ts/package.json
rm -f sdk/kotlin/gradle.properties.bak sdk/ts/package.json.bak

echo "stamped install docs to ${version}"
grep -n "gosslens:${version}\|from: \"${version}\"" README.md sdk/swift/README.md sdk/kotlin/README.md || true

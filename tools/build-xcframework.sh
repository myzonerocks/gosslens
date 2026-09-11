#!/bin/sh
# Assembles GosslensKit.xcframework into zig-out/ from the three iOS slices, each a static framework
# named for its module so its header and module map travel inside the bundle; the release job
# runs this same script, and a checkout runs it to build the library from source.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
for a in zig-out/ios/libgosslens.a zig-out/ios-simulator/libgosslens.a zig-out/ios-simulator-x86_64/libgosslens.a; do
  [ -e "$a" ] || { echo "build-xcframework: missing $a; run zig build ios, ios-simulator and ios-simulator-x86 first" >&2; exit 1; }
done
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# One static framework bundle per platform, the simulator's binary universal.
frame() {
  dir="$work/$1/CGosslens.framework"
  mkdir -p "$dir/Headers" "$dir/Modules"
  cp "$2" "$dir/CGosslens"
  cp include/gosslens.h "$dir/Headers/"
  printf 'framework module CGosslens {\n  umbrella header "gosslens.h"\n  export *\n  module * { export * }\n}\n' > "$dir/Modules/module.modulemap"
  cat > "$dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.myzonerocks.gosslens.CGosslens</string>
  <key>CFBundleName</key><string>CGosslens</string>
  <key>CFBundleExecutable</key><string>CGosslens</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>MinimumOSVersion</key><string>17.0</string>
</dict></plist>
PLIST
}
libtool -static -o "$work/device.a" zig-out/ios/*.a
libtool -static -o "$work/sim-arm64.a" zig-out/ios-simulator/*.a
libtool -static -o "$work/sim-x86_64.a" zig-out/ios-simulator-x86_64/*.a
lipo -create "$work/sim-arm64.a" "$work/sim-x86_64.a" -output "$work/sim.a"
frame device "$work/device.a"
frame sim "$work/sim.a"
rm -rf zig-out/GosslensKit.xcframework zig-out/GosslensKit.xcframework.zip
xcodebuild -create-xcframework \
  -framework "$work/device/CGosslens.framework" \
  -framework "$work/sim/CGosslens.framework" \
  -output zig-out/GosslensKit.xcframework
( cd zig-out && zip -qry GosslensKit.xcframework.zip GosslensKit.xcframework )
swift package compute-checksum zig-out/GosslensKit.xcframework.zip > zig-out/GosslensKit.checksum.txt
echo "build-xcframework: zig-out/GosslensKit.xcframework $(du -sh zig-out/GosslensKit.xcframework | cut -f1), checksum $(cat zig-out/GosslensKit.checksum.txt)"

{
  mkShell,
  lib,
  stdenv,
  zig,
  bun,
  jdk21,
  ffmpeg,
  gnumake,
  git,
  jq,
  curl,
  python3,
  alejandra,
}:
mkShell {
  name = "gosslens";
  # zig is nixpkgs's 0.16.0, the version .zigversion pins; tools/toolchain-sync still serves
  # a machine without the shell. The Swift SDK builds with the system's Xcode.
  packages = [
    zig
    bun
    jdk21
    ffmpeg
    gnumake
    git
    jq
    curl
    python3
    alejandra
  ];

  shellHook = lib.optionalString stdenv.hostPlatform.isDarwin ''
    unset SDKROOT DEVELOPER_DIR NIX_CC NIX_CFLAGS_COMPILE NIX_LDFLAGS LD CC CXX CFLAGS CPPFLAGS LDFLAGS
    export PATH=$(echo "$PATH" | awk -v RS=: -v ORS=: '$0 !~ /xcrun/ || $0 == "/usr/bin" {print}' | sed 's/:$//')
  '';
}

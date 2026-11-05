# The pinned Zig as the official release binary, fetched by the digest the download index
# publishes: the same bytes tools/toolchain-sync installs. nixpkgs builds one zig per minor
# and lags a patch release, and build.zig refuses any version but the pinned one.
{
  lib,
  stdenvNoCC,
  fetchurl,
}: let
  version = lib.fileContents ../.zigversion;
  # Keyed by version so a moved pin with no digests here fails the shell rather than
  # fetching on trust. Digests are the sha256 values in ziglang.org/download/index.json.
  digests = {
    "0.17.1" = {
      aarch64-darwin = "75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d";
      x86_64-darwin = "9af07b20319fbd0c92ee46ad23e81d6a782b1aaea2cfb8dcbff35f1d2c7ddbb7";
      x86_64-linux = "3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a";
      aarch64-linux = "a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795";
    };
  };
  system = stdenvNoCC.hostPlatform.system;
  # nix's system names against the download index's.
  platforms = {
    aarch64-darwin = "aarch64-macos";
    x86_64-darwin = "x86_64-macos";
    x86_64-linux = "x86_64-linux";
    aarch64-linux = "aarch64-linux";
  };
  platform = platforms.${system};
in
  stdenvNoCC.mkDerivation {
    pname = "zig";
    inherit version;
    src = fetchurl {
      url = "https://ziglang.org/download/${version}/zig-${platform}-${version}.tar.xz";
      sha256 = digests.${version}.${system};
    };
    # The release binary is static and relocatable; the archive's own layout, the compiler
    # beside its lib directory, is what it finds its standard library by, so it is kept whole.
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      mkdir -p $out/bin
      cp -R . $out/zig-${version}
      ln -s ../zig-${version}/zig $out/bin/zig
    '';
    meta = {
      description = "The Zig compiler, the release binary at the version .zigversion pins";
      homepage = "https://ziglang.org";
      license = lib.licenses.mit;
      platforms = builtins.attrNames platforms;
    };
  }

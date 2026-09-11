#!/bin/sh
# Runs nix with the given arguments so a nix command in this repository never answers
# "command not found" or "experimental feature disabled": a Nix already on the machine is put
# back on this shell's PATH, a missing one is installed, and flakes are turned on once.
set -eu
for hook in /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh "$HOME/.nix-profile/etc/profile.d/nix.sh"; do
  # shellcheck disable=SC1090
  [ -r "$hook" ] && . "$hook"
done
if ! command -v nix >/dev/null 2>&1; then
  if [ "${1:-}" = "--reset" ]; then
    shift
    echo "nix: removing the Nix Store volume of an earlier install (sudo)" >&2
    sudo launchctl bootout system/org.nixos.darwin-store 2>/dev/null || true
    sudo launchctl bootout system/org.nixos.nix-daemon 2>/dev/null || true
    sudo diskutil apfs deleteVolume "Nix Store"
  elif [ "$(uname)" = Darwin ] && diskutil apfs list 2>/dev/null | grep -q "Nix Store"; then
    echo "nix: a Nix Store volume from an earlier install exists but no nix runs; run nix/ensure.sh --reset develop to remove it and install afresh, or install the Determinate package: https://dtr.mn/determinate-nix" >&2
    exit 1
  fi
  echo "nix: not installed; installing with the Determinate installer (it asks for sudo once)" >&2
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
conf="${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf"
if ! grep -qs "experimental-features" "$conf" /etc/nix/nix.conf; then
  mkdir -p "$(dirname "$conf")"
  echo "experimental-features = nix-command flakes" >> "$conf"
fi
export NIX_CONFIG="experimental-features = nix-command flakes"
exec nix "$@"

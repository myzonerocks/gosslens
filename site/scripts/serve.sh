#!/usr/bin/env bash
# Keeps the preview server up. A stray kill elsewhere should not take the site
# down while somebody is reading it.
set -u
PORT="${1:-5180}"
cd "$(dirname "$0")/.."
while true; do
  bun run dev --port "$PORT" --strictPort --host
  echo "dev server exited, restarting in 2s" >&2
  sleep 2
done

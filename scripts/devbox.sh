#!/bin/sh
set -eu

version=0.17.5
checksum=eb2d8fb34266ba3befc294d7d6f56e2cd4da2cacb7a0cf52db5b8092575544f8
root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
bin_dir=${DEVBOX_BIN_DIR:-"$root/.devbox/bin"}
bin="$bin_dir/devbox"

if command -v devbox >/dev/null 2>&1 && [ "$(devbox version)" = "$version" ]; then
  exec devbox "$@"
fi

if [ ! -x "$bin" ] || [ "$("$bin" version 2>/dev/null || true)" != "$version" ]; then
  if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
    printf 'Devbox %s is required; install it and rerun ./check.\n' "$version" >&2
    exit 1
  fi

  archive=$(mktemp)
  trap 'rm -f "$archive"' EXIT
  curl --fail --location --silent --show-error \
    "https://github.com/jetify-com/devbox/releases/download/$version/devbox_${version}_linux_amd64.tar.gz" \
    --output "$archive"
  printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check
  mkdir -p "$bin_dir"
  tar -xzf "$archive" -C "$bin_dir" devbox
  chmod +x "$bin"
fi

exec "$bin" "$@"

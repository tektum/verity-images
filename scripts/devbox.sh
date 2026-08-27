#!/bin/sh
set -eu

version=0.17.5
amd64_checksum=eb2d8fb34266ba3befc294d7d6f56e2cd4da2cacb7a0cf52db5b8092575544f8
arm64_checksum=880901fff1ce7bf48086c12d84535bc14c257b56cb0d05e93e037f2cb1b1d529
root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
bin_dir=${DEVBOX_BIN_DIR:-"$root/.devbox/bin"}
bin="$bin_dir/devbox"

if command -v devbox >/dev/null 2>&1 && [ "$(devbox version)" = "$version" ]; then
  exec devbox "$@"
fi

if [ ! -x "$bin" ] || [ "$("$bin" version 2>/dev/null || true)" != "$version" ]; then
  if [ "$(uname -s)" != Linux ]; then
    printf 'Devbox %s is required; install it and rerun ./check.\n' "$version" >&2
    exit 1
  fi
  case "$(uname -m)" in
    x86_64) architecture=amd64; checksum=$amd64_checksum ;;
    aarch64|arm64) architecture=arm64; checksum=$arm64_checksum ;;
    *)
      printf 'Devbox %s is required; install it and rerun ./check.\n' "$version" >&2
      exit 1
      ;;
  esac

  archive=$(mktemp)
  trap 'rm -f "$archive"' EXIT
  curl --fail --location --silent --show-error \
    "https://github.com/jetify-com/devbox/releases/download/$version/devbox_${version}_linux_${architecture}.tar.gz" \
    --output "$archive"
  printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check
  mkdir -p "$bin_dir"
  tar -xzf "$archive" -C "$bin_dir" devbox
  chmod +x "$bin"
fi

exec "$bin" "$@"

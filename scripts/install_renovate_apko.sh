#!/bin/bash
set -euo pipefail

version=${APKO_VERSION:?APKO_VERSION is required}
checksum=${APKO_SHA256:?APKO_SHA256 is required}
if [[ $(uname -m) != x86_64 ]]; then
  printf 'unsupported Renovate runner architecture: %s\n' "$(uname -m)" >&2
  exit 2
fi

archive="apko_${version}_linux_amd64.tar.gz"
curl -fsSL "https://github.com/chainguard-dev/apko/releases/download/v${version}/${archive}" \
  -o "/tmp/${archive}"
printf '%s  %s\n' "$checksum" "/tmp/${archive}" | sha256sum --check
tar -xzf "/tmp/${archive}" -C /tmp
sudo install "/tmp/apko_${version}_linux_amd64/apko" /usr/local/bin/apko

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
chmod 0777 "$tmp"
printf '%s\n' 'signed payload' >"$tmp/blob"

docker run --rm -e COSIGN_PASSWORD= -v "$tmp:/work" -w /work "$image" generate-key-pair
docker run --rm -e COSIGN_PASSWORD= -v "$tmp:/work" -w /work "$image" sign-blob --yes --tlog-upload=false --key cosign.key --output-signature blob.sig blob
docker run --rm -v "$tmp:/work" -w /work "$image" verify-blob --key cosign.pub --signature blob.sig blob

printf '%s\n' 'tampered payload' >"$tmp/blob"
if docker run --rm -v "$tmp:/work" -w /work "$image" verify-blob --key cosign.pub --signature blob.sig blob >/dev/null 2>&1; then
  printf '%s\n' 'tampered blob unexpectedly verified' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"

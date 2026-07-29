#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container=$(docker create "$image" /bin/true)
trap 'docker rm -f "$container" >/dev/null 2>&1 || true' EXIT INT TERM
docker export "$container" | tar -tf - | grep -q '^etc/ssl/certs/ca-certificates.crt$'

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
docker run --rm "$image" sh -c 'grep -q "^12" /etc/debian_version && apt-get --version >/dev/null'

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
test "$(docker run --rm "$image" -c 'apk --version >/dev/null && printf wolfi')" = wolfi

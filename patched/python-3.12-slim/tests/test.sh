#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
docker run --rm "$image" python -c 'import sys; assert sys.version_info[:2] == (3, 12)'

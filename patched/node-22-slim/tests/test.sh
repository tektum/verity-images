#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
docker run --rm "$image" node -e 'if (process.versions.node.split(".")[0] !== "22") process.exit(1)'

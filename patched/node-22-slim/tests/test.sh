#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
docker run --rm "$image" sh -c '
  node -e '\''if (process.versions.node.split(".")[0] !== "22") process.exit(1)'\''
  test -n "$(npm --version)"
  dir=$(mktemp -d)
  cd "$dir"
  printf '\''{"name":"smoke","version":"1.0.0"}\n'\'' > package.json
  npm pack --ignore-scripts >/dev/null
  test -f smoke-1.0.0.tgz
'

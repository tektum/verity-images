#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/curl"]' ]
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in null|'[]') ;; *) exit 1;; esac
docker run --rm "$image" --version | grep -q '^curl 8\.'
docker run --rm "$image" --fail --silent --output /dev/null file:///etc/ssl/certs/ca-certificates.crt

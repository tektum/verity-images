#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
created=

cleanup() {
  [ -z "$created" ] || docker rm -f "$created" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/crossplane"]' ]
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in null|'[]') ;; *) exit 1;; esac
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ]

created=$(docker create "$image")
contents=$(docker export "$created" | tar -tf -)
printf '%s\n' "$contents" | grep -qx 'usr/bin/crossplane'
printf '%s\n' "$contents" | grep -qx 'cache/xpkg/'
printf '%s\n' "$contents" | grep -qx 'cache/xfn/'
metadata=$(docker export "$created" | tar --numeric-owner -tvf -)
printf '%s\n' "$metadata" | grep -Eq '^drwxr-xr-x +65532/65532 +.* cache/xpkg/$'
printf '%s\n' "$metadata" | grep -Eq '^drwxr-xr-x +65532/65532 +.* cache/xfn/$'
docker rm "$created" >/dev/null
created=

docker run --rm --user 65532 "$image" --version | grep -qx v2.3.4
docker run --rm --user 65532 "$image" core start --help >/dev/null
if docker run --rm --user 65532 "$image" --not-a-real-flag >/dev/null 2>&1; then
  exit 1
fi

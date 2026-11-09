#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}

fail() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/nginx-ingress"]' ] || fail "unexpected entrypoint"
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 101 ] || fail "unexpected user"

exposed_ports=$(docker image inspect --format '{{range $port, $_ := .Config.ExposedPorts}}{{println $port}}{{end}}' "$image")
[ "$(printf '%s\n' "$exposed_ports" | grep -c .)" -eq 2 ] || fail "unexpected exposed port count"
for port in 80 443; do
  printf '%s\n' "$exposed_ports" | grep -qx "$port/tcp" || fail "missing exposed port $port"
done

arch=$(docker image inspect --format '{{.Architecture}}' "$image")
case $arch in amd64 | arm64) ;; *) fail "unsupported candidate architecture $arch" ;; esac

version=$(docker run --rm "$image" --version 2>&1) || fail "--version failed"
case $version in
  "NGINX Ingress Controller Version=5."*) ;;
  *) fail "unexpected version output: $version" ;;
esac
nginx_version=$(docker run --rm --entrypoint nginx "$image" -v 2>&1) || fail "nginx binary is unavailable"
case $nginx_version in
  "nginx version: nginx/"*) ;;
  *) fail "unexpected nginx output: $nginx_version" ;;
esac
case $nginx_version in *[Pp]lus*) fail "image must be the open source edition" ;; esac

out=$(docker run --rm "$image" 2>&1) && fail "controller started outside a cluster"
case $out in
  *"unable to load in-cluster configuration"*) ;;
  *) fail "missing documented in-cluster configuration error: $out" ;;
esac

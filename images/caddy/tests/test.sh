#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
flavor=${2:-plain}
set --
container="verity-caddy-test-$$"
config=$(mktemp)
binary=$(mktemp)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -f "$binary" "$config"
}
trap cleanup EXIT INT TERM

created=$(docker create "$image")
docker cp "$created:/usr/bin/caddy" "$binary"
docker rm "$created" >/dev/null
if [ "$flavor" = fips ]; then
  go version -m "$binary" | grep -q 'GOFIPS140=v1.0.0'
else
  if go version -m "$binary" | grep -q 'GOFIPS140='; then
    exit 1
  fi
fi

if [ "$flavor" = fips ]; then
  cat >"$config" <<'EOF'
https://localhost:8443 {
  tls internal
  respond "Caddy FIPS works!"
}
EOF
  chmod 644 "$config"
  docker run --name "$container" -d -e GODEBUG=fips140=only \
    -v "$config:/tmp/Caddyfile:ro" -p 127.0.0.1::8443 "$image" \
    run --config /tmp/Caddyfile --adapter caddyfile >/dev/null
  port=$(docker port "$container" 8443/tcp | awk -F: 'NR == 1 { print $2 }')
  url="https://localhost:$port/"
  set -- --insecure
  expected='Caddy FIPS works!'
else
  docker run --name "$container" -d -p 127.0.0.1::80 "$image" \
    run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
  port=$(docker port "$container" 80/tcp | awk -F: 'NR == 1 { print $2 }')
  url="http://127.0.0.1:$port/"
  expected='<title>Caddy works!</title>'
fi

i=0
until response=$(curl --fail --silent "$@" "$url"); do
  i=$((i + 1))
  [ "$i" -lt 20 ] || exit 1
  sleep 1
done

printf '%s' "$response" | grep -q "$expected"

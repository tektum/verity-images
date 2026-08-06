#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fixture=$(mktemp -d)
container=configmap-reload-smoke-$$

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")
test "$entrypoint" = '["/usr/bin/configmap-reload"]'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532

mkdir -p "$fixture/watch/data-1"
chmod 755 "$fixture" "$fixture/watch"

docker run -d --name "$container" \
  -v "$fixture:/fixture:ro" \
  --entrypoint /bin/sh \
  "$image" -c '
    { printf "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" | nc -l -N 127.0.0.1 8080 >/dev/null && printf "webhook-called\n" >&2; } &
    exec /usr/bin/configmap-reload \
      -volume-dir=/fixture/watch \
      -webhook-url=http://127.0.0.1:8080/reload
  ' >/dev/null

for _ in $(seq 1 100); do
  if docker exec "$container" wget -q -O - http://127.0.0.1:9533/metrics > "$fixture/metrics"; then
    break
  fi
  sleep 0.1
done
test -s "$fixture/metrics" || {
  docker logs "$container" >&2
  printf 'metrics endpoint did not respond\n' >&2
  exit 1
}

ln -s data-1 "$fixture/watch/..data"
for _ in $(seq 1 100); do
  docker logs "$container" 2>&1 | grep -qx webhook-called && break
  sleep 0.1
done
docker logs "$container" 2>&1 | grep -qx webhook-called || {
  docker logs "$container" >&2
  printf '..data event did not trigger webhook\n' >&2
  exit 1
}

if docker run --rm "$image" >/dev/null 2>&1; then
  printf 'missing required arguments unexpectedly succeeded\n' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"

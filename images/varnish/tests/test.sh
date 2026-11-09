#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
label="verity-test=varnish-$$"
network="verity-varnish-net-$$"
backend="verity-varnish-backend-$$"
container="verity-varnish-test-$$"
fixture=$(mktemp -d)

cleanup() {
  docker rm -f "$container" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532
entrypoint=$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')
printf '%s\n' "$entrypoint" | grep -q '"/usr/bin/varnishd"'

version=$(docker run --rm --label "$label" --entrypoint /usr/bin/varnishd "$image" -V 2>&1)
printf '%s\n' "$version"
printf '%s\n' "$version" | grep -q 'varnish-9\.1\.'

# Negative: a VCL that does not compile must fail with a readable error.
cat > "$fixture/bad.vcl" <<'VCL'
vcl 4.1;
backend default none;
sub vcl_recv { this_is_not_vcl; }
VCL
chmod 644 "$fixture/bad.vcl"
status=0
bad=$(docker run --rm --label "$label" -v "$fixture/bad.vcl:/etc/varnish/bad.vcl:ro" \
  --entrypoint /usr/bin/varnishd "$image" -C -f /etc/varnish/bad.vcl 2>&1) || status=$?
printf '%s\n' "$bad" | tail -5
test "$status" -ne 0 || {
  printf 'varnishd accepted an invalid VCL\n' >&2
  exit 1
}

# Origin: a second varnishd answering every request from VCL (no extra images needed).
docker network create --label "$label" "$network" >/dev/null
cat > "$fixture/origin.vcl" <<'VCL'
vcl 4.1;

backend default none;

sub vcl_recv {
    return (synth(200, "OK"));
}

sub vcl_synth {
    set resp.http.Cache-Control = "max-age=60";
    set resp.body = "hello from the origin\n";
    return (deliver);
}
VCL
chmod 644 "$fixture/origin.vcl"
docker run -d --name "$backend" --label "$label" --network "$network" \
  --network-alias origin -v "$fixture/origin.vcl:/etc/varnish/origin.vcl:ro" \
  --entrypoint /usr/bin/varnishd "$image" -F -j none \
  -a :8081 -f /etc/varnish/origin.vcl >/dev/null
sleep 3
test "$(docker inspect --format '{{.State.Running}}' "$backend")" = true || {
  docker logs "$backend" >&2
  exit 1
}

cat > "$fixture/default.vcl" <<'VCL'
vcl 4.1;

backend default {
    .host = "origin";
    .port = "8081";
}

sub vcl_backend_response {
    # The origin is varnishd too; drop its own tracing headers.
    unset beresp.http.X-Varnish;
    unset beresp.http.Via;
    set beresp.ttl = 60s;
}
VCL
chmod 644 "$fixture/default.vcl"

docker run -d --name "$container" --label "$label" --network "$network" \
  -v "$fixture/default.vcl:/etc/varnish/default.vcl:ro" \
  -p 127.0.0.1::8080 "$image" >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port"

i=0
until curl -fsS -D "$fixture/h1" -o "$fixture/b1" "http://127.0.0.1:$port/index.html" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || {
    docker logs "$container" >&2
    exit 1
  }
  sleep 1
done
tr -d '\r' < "$fixture/h1" > "$fixture/h1.txt"
cat "$fixture/h1.txt"
grep -q 'hello from the origin' "$fixture/b1"
grep -qi '^x-varnish: [0-9][0-9]*$' "$fixture/h1.txt" || {
  printf 'first request was not a cache miss\n' >&2
  exit 1
}

curl -fsS -D "$fixture/h2" -o "$fixture/b2" "http://127.0.0.1:$port/index.html"
tr -d '\r' < "$fixture/h2" > "$fixture/h2.txt"
cat "$fixture/h2.txt"
grep -q 'hello from the origin' "$fixture/b2"
grep -qi '^x-varnish: [0-9][0-9]* [0-9][0-9]*$' "$fixture/h2.txt" || {
  printf 'second request was not a cache hit\n' >&2
  exit 1
}
age=$(awk 'tolower($1) == "age:" { print $2 }' "$fixture/h2.txt")
test -n "$age"

hits=$(docker exec "$container" /usr/bin/varnishstat -1 -f MAIN.cache_hit |
  awk '$1 == "MAIN.cache_hit" { print $2 }')
test "${hits:-0}" -ge 1 || {
  printf 'varnishstat reports no cache hits\n' >&2
  exit 1
}

# varnishadm attaches to the default instance without -n.
docker exec "$container" /usr/bin/varnishadm ping | grep -q PONG

# Origin gone: the cached object is still served until its TTL expires.
docker rm -f "$backend" >/dev/null
curl -fsS "http://127.0.0.1:$port/index.html" | grep -q 'hello from the origin'

# SIGTERM must stop varnishd cleanly.
docker stop -t 30 "$container" >/dev/null
exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container")
test "$exit_code" = 0 || {
  docker logs "$container" >&2
  printf 'varnishd exited %s after SIGTERM\n' "$exit_code" >&2
  exit 1
}

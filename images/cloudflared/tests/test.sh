#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/cloudflared"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["version"]' ] \
  || fail 'unexpected image command'
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected image user'

docker run --rm --network none "$image" version | grep -Fq 'cloudflared version 2026.10.' \
  || fail 'unexpected cloudflared version'

cat >"$work/good.yml" <<'YAML'
ingress:
  - hostname: app.example.com
    service: http://127.0.0.1:8080
  - service: http_status:404
YAML
cat >"$work/bad.yml" <<'YAML'
ingress:
  - hostname: app.example.com
    service: http://127.0.0.1:8080
YAML
chmod 755 "$work"
chmod 644 "$work/good.yml" "$work/bad.yml"

run() {
  config=$1
  shift
  docker run --rm --network none -v "$work/$config:/tmp/config.yml:ro" "$image" \
    tunnel --config /tmp/config.yml "$@"
}

run good.yml ingress validate 2>&1 | grep -Fxq OK || fail 'valid ingress configuration was rejected'
rule=$(run good.yml ingress rule https://app.example.com/path 2>&1) || fail 'ingress rule lookup failed'
printf '%s\n' "$rule" | grep -Fq 'service: http://127.0.0.1:8080' || fail 'ingress rule matched the wrong service'
rule=$(run good.yml ingress rule https://other.example.com/ 2>&1) || fail 'catch-all rule lookup failed'
printf '%s\n' "$rule" | grep -Fq 'service: http_status:404' || fail 'catch-all rule matched the wrong service'

if output=$(run bad.yml ingress validate 2>&1); then
  fail 'ingress without a catch-all rule was accepted'
fi
printf '%s\n' "$output" | grep -Fq 'last ingress rule must match all URLs' || fail 'invalid ingress failed without the catch-all diagnostic'

if output=$(docker run --rm --network none "$image" no-such-command 2>&1); then
  fail 'unknown command succeeded'
fi
printf '%s\n' "$output" | grep -Fq 'did not specify any valid additional argument' || fail 'unknown command diagnostic not found'

# Without network access a quick tunnel must fail with the connectivity error, not crash.
status=0
output=$(docker run --rm --network none "$image" tunnel --no-autoupdate --url http://127.0.0.1:1 2>&1) || status=$?
[ "$status" -ne 0 ] || fail 'quick tunnel succeeded without network access'
printf '%s\n' "$output" | grep -Fq 'failed to request quick Tunnel' || fail 'quick tunnel connectivity diagnostic not found'

printf 'SMOKE PASS image=%s\n' "$image"

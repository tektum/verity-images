#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
name="verity-podinfo-smoke-$$"

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$name" >&2 2>&1 || true
  exit 1
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
test "$user" = 65532 || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")
test "$entrypoint" = null || fail "unexpected entrypoint: $entrypoint"
cmd=$(docker image inspect -f '{{json .Config.Cmd}}' "$image")
test "$cmd" = '["/usr/bin/podinfo"]' || fail "unexpected cmd: $cmd"
workdir=$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")
test "$workdir" = /home/app || fail "unexpected working directory: $workdir"

version=$(docker run --rm --network none "$image" podinfo --version)
printf '%s\n' "$version" | grep -Eq '^6\.17\.[0-9]+$' || fail "unexpected version: $version"
# Upstream manifests start ./podinfo from the working directory.
compat=$(docker run --rm --network none "$image" ./podinfo --version)
test "$compat" = "$version" || fail "./podinfo reports $compat, want $version"
docker run --rm --network none "$image" podcli version | grep -Fq "$version" \
  || fail 'podcli version mismatch'

# Negative: an invalid flag value exits non-zero with a readable error.
set +e
output=$(docker run --rm --network none "$image" podinfo --port=not-a-port 2>&1)
status=$?
set -e
test "$status" -ne 0 || fail 'invalid port was accepted'
printf '%s\n' "$output" | grep -q 'invalid argument "not-a-port" for "--port' \
  || fail "unexpected invalid-port error: $output"

docker run -d --name "$name" -p 127.0.0.1::9898 "$image" >/dev/null
port=$(docker port "$name" 9898/tcp | awk -F: 'NR == 1 { print $NF }')
test -n "$port" || fail 'podinfo port was not published'
base="http://127.0.0.1:$port"

ready=
for _ in $(seq 1 60); do
  if curl -fsS --connect-timeout 1 --max-time 5 "$base/readyz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
test -n "$ready" || fail 'podinfo did not become ready on :9898'

health=$(curl -fsS --connect-timeout 1 --max-time 5 "$base/healthz")
printf '%s\n' "$health" | tr -d ' \n' | grep -Fq '"status":"OK"' \
  || fail "unexpected /healthz body: $health"

info=$(curl -fsS --connect-timeout 1 --max-time 5 "$base/version")
printf '%s\n' "$info" | tr -d ' \n' | grep -Fq "\"version\":\"$version\"" \
  || fail "unexpected /version body: $info"
printf '%s\n' "$info" | tr -d ' \n' | grep -Eq '"commit":"[0-9a-f]{40}"' \
  || fail "missing source commit in /version: $info"

# Browsers get the UI template rendered from /home/app/ui.
curl -fsS --connect-timeout 1 --max-time 5 -A 'Mozilla/5.0' "$base/" | grep -Fq '<title>' \
  || fail 'UI was not served from /home/app/ui'
# /artifact serves a tarball of the bundled /home/app/kustomize manifests.
curl -fsS --connect-timeout 1 --max-time 5 -o /dev/null "$base/artifact" || fail '/artifact was not served'

# SIGTERM must shut the server down cleanly.
docker stop -t 30 "$name" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
test "$code" = 0 || fail "podinfo exited $code after SIGTERM, want 0"

printf 'SMOKE PASS image=%s\n' "$image"

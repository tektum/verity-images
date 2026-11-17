#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
version=$(sed -n 's/^  version: "\([0-9.]*\)".*/\1/p' "$here/../melange.yaml")
fixture_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
container="verity-cert-exporter-test-$$"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the package version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/cert-exporter"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'

# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the fixture by its own per-platform child digest.
# The index bytes are verified against the pinned digest before a child is
# chosen, which keeps the pin authoritative.
image_arch=$(docker image inspect --format '{{.Architecture}}' "$image")
fixture_raw=$(docker buildx imagetools inspect --raw "$fixture_index") ||
  fail 'cannot inspect fixture image index'
[ "sha256:$(printf '%s' "$fixture_raw" | sha256sum | cut -d' ' -f1)" = "${fixture_index#*@}" ] ||
  fail 'fixture image index digest mismatch'
fixture_digest=$(printf '%s' "$fixture_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve fixture image digest'
case $fixture_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch fixture image in $fixture_index" ;;
esac
fixture=docker.io/curlimages/curl@$fixture_digest
docker pull --quiet --platform "linux/$image_arch" "$fixture" >/dev/null ||
  fail 'cannot pull fixture image'

curl_fixture() {
  docker run --rm --network "container:$container" "$fixture" "$@"
}

docker run --rm --network none "$image" --help >"$work/help" 2>&1 || true
grep -F -- '-include-cert-glob' "$work/help" >/dev/null ||
  fail "help does not list -include-cert-glob: $(cat "$work/help")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

rc=0
docker run --rm --network none "$image" --polling-period=soon >"$work/period" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid polling period unexpectedly succeeded'
grep -F 'invalid value "soon" for flag -polling-period' "$work/period" >/dev/null ||
  fail "invalid polling period diagnostic is missing: $(cat "$work/period")"

# Fixtures: a certificate that is watched and one excluded by glob.
mkdir -p "$work/certs"
for name in smoke skip-me; do
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=verity-$name" \
    -keyout "$work/$name.key" -out "$work/certs/$name.pem" >/dev/null 2>&1 ||
    fail "cannot create the $name fixture certificate"
done
chmod 0755 "$work/certs"
chmod 0644 "$work/certs/"*.pem

docker run -d --name "$container" --read-only --cap-drop=ALL -e NODE_NAME=verity-node \
  -v "$work/certs:/certs:ro" "$image" \
  --include-cert-glob='/certs/*.pem' --exclude-cert-glob='/certs/skip-*.pem' \
  --prometheus-listen-address=:8080 >/dev/null

i=0
until curl_fixture --fail --silent http://127.0.0.1:8080/metrics >"$work/metrics" 2>/dev/null &&
  grep -F 'cert_exporter_cert_not_after_timestamp{' "$work/metrics" >/dev/null; do
  [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] ||
    fail "exporter exited: $(docker logs "$container" 2>&1)"
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail "exporter did not publish certificate metrics: $(docker logs "$container" 2>&1)"
  sleep 1
done

expected=$(date -u -d "$(openssl x509 -enddate -noout -in "$work/certs/smoke.pem" | cut -d= -f2)" +%s)
labels='cn="verity-smoke",filename="/certs/smoke.pem",issuer="verity-smoke",nodename="verity-node"'
actual=$(awk -v l="{$labels}" '$1 == "cert_exporter_cert_not_after_timestamp" l { printf "%d\n", $2 }' \
  "$work/metrics")
test "$actual" = "$expected" ||
  fail "cert_exporter_cert_not_after_timestamp is '$actual', want $expected: $(grep cert_exporter_cert "$work/metrics")"
remaining=$(awk -v l="{$labels}" '$1 == "cert_exporter_cert_expires_in_seconds" l { printf "%d\n", $2 }' \
  "$work/metrics")
[ -n "$remaining" ] || fail 'cert_exporter_cert_expires_in_seconds is missing for the fixture'
# 30 days minus a generous margin for slow runners.
[ "$remaining" -gt 2588000 ] && [ "$remaining" -le 2592000 ] ||
  fail "cert_exporter_cert_expires_in_seconds is $remaining, want about 30 days"
if grep -F 'verity-skip-me' "$work/metrics" >/dev/null; then
  fail 'excluded certificate is reported'
fi
errors=$(awk '$1 == "cert_exporter_error_total" { print $2 }' "$work/metrics")
[ "$errors" = 0 ] ||
  fail "cert_exporter_error_total is '$errors', want 0: $(grep cert_exporter_error_total "$work/metrics")"
docker logs "$container" 2>&1 | grep -F "Starting cert-exporter" | grep -F "version=$version" >/dev/null ||
  fail "startup log does not carry the version: $(docker logs "$container" 2>&1 | head -5)"

# cert-exporter installs no signal handler, so SIGTERM ends it through the Go
# runtime: status 143, or 2 when the kernel ignores the re-raised signal for a
# PID 1 process. 137 would mean docker had to SIGKILL it.
docker stop --time 10 "$container" >/dev/null
case $(docker inspect --format '{{.State.ExitCode}}' "$container") in
  2 | 143) ;;
  *) fail "exporter did not stop on SIGTERM: exit $(docker inspect --format '{{.State.ExitCode}}' "$container")" ;;
esac
# Exit 2 is also the Go runtime's status for a panic or fatal error, so only
# accept it when the log shows no crash.
if docker logs "$container" 2>&1 | grep -Eq '^(panic: |fatal error: |goroutine [0-9]+ \[)'; then
  docker logs "$container" 2>&1 | tail -n 40 >&2
  fail 'cert-exporter crashed (Go panic or fatal error) instead of stopping on SIGTERM'
fi

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"

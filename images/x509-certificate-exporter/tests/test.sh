#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
version=$(sed -n 's/^  version: "\([0-9.]*\)".*/\1/p' "$here/../melange.yaml")
fixture_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
container="verity-x509-certificate-exporter-test-$$"
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
  '["/usr/bin/x509-certificate-exporter"]' || fail 'unexpected entrypoint'
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

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "Version:    $version" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"
grep -Ex 'Git commit: [0-9a-f]{40}' "$work/version" >/dev/null || fail 'git commit is not stamped'

# Negative: no sources, an unknown flag and an unparsable config all exit
# non-zero with a readable diagnostic.
rc=0
docker run --rm --network none "$image" >"$work/nosource" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'start without sources unexpectedly succeeded'
grep -F 'no sources configured' "$work/nosource" >/dev/null ||
  fail "missing sources diagnostic: $(cat "$work/nosource")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

mkdir -p "$work/certs"
printf 'sources: [unterminated\n' >"$work/certs/bad.yaml"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=verity-smoke \
  -keyout "$work/key.pem" -out "$work/certs/smoke.pem" >/dev/null 2>&1 ||
  fail 'cannot create the fixture certificate'
chmod 0755 "$work/certs"
chmod 0644 "$work/certs/bad.yaml" "$work/certs/smoke.pem"

rc=0
docker run --rm --network none -v "$work/certs:/certs:ro" "$image" \
  -C /certs/bad.yaml >"$work/badconfig" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'unparsable config unexpectedly succeeded'
grep -F 'load config: parse config /certs/bad.yaml' "$work/badconfig" >/dev/null ||
  fail "bad config diagnostic is missing: $(cat "$work/badconfig")"

# Watch the fixture certificate on a read-only root with no capabilities.
docker run -d --name "$container" --read-only --cap-drop=ALL \
  -v "$work/certs:/certs:ro" "$image" -f /certs/smoke.pem -b :9793 >/dev/null

i=0
until [ "$(curl_fixture --silent http://127.0.0.1:9793/readyz 2>/dev/null)" = ready ]; do
  [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] ||
    fail "exporter exited: $(docker logs "$container" 2>&1)"
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail "exporter did not become ready: $(docker logs "$container" 2>&1)"
  sleep 1
done

curl_fixture --fail --silent --show-error http://127.0.0.1:9793/metrics >"$work/metrics" ||
  fail 'metrics scrape failed'
expected=$(date -u -d "$(openssl x509 -enddate -noout -in "$work/certs/smoke.pem" | cut -d= -f2)" +%s)
actual=$(awk '/^x509_cert_not_after\{/ && /subject_CN="verity-smoke"/ && /filepath="\/certs\/smoke.pem"/ {
  printf "%d\n", $NF }' "$work/metrics")
test "$actual" = "$expected" ||
  fail "x509_cert_not_after is '$actual', want $expected"
grep -E '^x509_cert_expired\{.*subject_CN="verity-smoke".*\} 0$' "$work/metrics" >/dev/null ||
  fail 'fixture certificate is not reported as unexpired'
grep -E "^x509_exporter_build_info\{.*version=\"$version\".*\} 1$" "$work/metrics" >/dev/null ||
  fail 'build info metric does not carry the version'
grep -E '^x509_read_errors(_total)? ' "$work/metrics" | grep -Ev ' 0$' >/dev/null &&
  fail 'exporter reported read errors'

# SIGTERM shuts the exporter down cleanly.
docker stop --time 10 "$container" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ||
  fail "exporter did not exit cleanly: $(docker logs "$container" 2>&1 | tail -5)"
docker logs "$container" 2>&1 | grep -F 'shutdown signal received' >/dev/null ||
  fail 'shutdown was not logged'

echo 'SMOKE PASS'

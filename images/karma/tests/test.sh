#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
expected_version="v$expected_version"
# Catalog Alertmanager, pinned by index digest, is the upstream karma reads.
alertmanager_index=ghcr.io/tektum/alertmanager@sha256:223f821e04dc2bce3c53050f7e14ff51282faf2629c846d67b8a5aaaf7cd2369
suffix="verity-karma-test-$$"
net="$suffix-net"
alertmanager="$suffix-am"
karma="$suffix-karma"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$karma" "$alertmanager" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for name in "$karma" "$alertmanager"; do
    docker logs "$name" >&2 2>&1 || true
  done
  exit 1
}

wait_http() {
  i=0
  until curl --fail --silent --show-error --connect-timeout 1 --max-time 5 "$1" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || fail "$1 never became ready"
    sleep 1
  done
}

# Upstream contract: ENTRYPOINT ["/karma"], no CMD, WORKDIR /, port 8080.
# This image runs non-root and keeps /karma as a compatibility path.
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/karma"]' ] ||
  fail 'unexpected entrypoint'
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in
  null | '[]') ;;
  *) fail 'unexpected default command' ;;
esac
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ] || fail 'unexpected working directory'

version=$(docker run --rm --network none "$image" --version) || fail '--version failed'
[ "$version" = "$expected_version" ] || fail "--version printed '$version', expected '$expected_version'"
version=$(docker run --rm --network none --entrypoint /karma "$image" --version) ||
  fail '--version through /karma failed'
[ "$version" = "$expected_version" ] || fail "/karma --version printed '$version'"

# Negative cases: an unknown flag, an invalid log level, and a malformed
# configuration file must all be rejected before karma starts serving.
if docker run --rm --network none "$image" --no-such-flag >"$work/out" 2>&1; then
  fail 'unknown flag was accepted'
fi
grep -Fq 'no-such-flag' "$work/out" || fail "unknown flag error is not reported: $(cat "$work/out")"
if docker run --rm --network none "$image" --alertmanager.uri=http://127.0.0.1:9093 \
  --log.level=bogus >"$work/out" 2>&1; then
  fail 'invalid log level was accepted'
fi
grep -Fq "unknown log level 'bogus'" "$work/out" || fail "invalid log level error is not reported: $(cat "$work/out")"
printf '%s\n' 'alertmanager: [' >"$work/invalid.yaml"
chmod 644 "$work/invalid.yaml"
if docker run --rm --network none -v "$work/invalid.yaml:/tmp/karma.yaml:ro" "$image" \
  --config.file=/tmp/karma.yaml >"$work/out" 2>&1; then
  fail 'malformed configuration file was accepted'
fi
grep -Fq 'failed to load configuration file' "$work/out" ||
  fail "malformed configuration error is not reported: $(cat "$work/out")"
printf '%s\n' 'alertmanager:' '  servers:' '    - name: smoke' '      uri: http://127.0.0.1:9093' >"$work/valid.yaml"
chmod 644 "$work/valid.yaml"
docker run --rm --network none -v "$work/valid.yaml:/tmp/karma.yaml:ro" "$image" \
  --config.file=/tmp/karma.yaml --check-config >"$work/out" 2>&1 ||
  fail "--check-config rejected a valid configuration: $(cat "$work/out")"
if docker run --rm --network none -v "$work/invalid.yaml:/tmp/karma.yaml:ro" "$image" \
  --config.file=/tmp/karma.yaml --check-config >"$work/out" 2>&1; then
  fail '--check-config accepted a malformed configuration'
fi

cat >"$work/alertmanager.yml" <<'EOF'
route:
  receiver: sink
receivers:
  - name: sink
EOF
chmod 644 "$work/alertmanager.yml"

docker network create "$net" >/dev/null
docker run --name "$alertmanager" -d --network "$net" --read-only \
  --tmpfs /alertmanager:uid=65532,gid=65532 -p 127.0.0.1::9093 \
  -v "$work/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro" \
  "$alertmanager_index" --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/alertmanager >/dev/null
am_port=$(docker port "$alertmanager" 9093/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$am_port" ] || fail 'alertmanager port was not published'
am="http://127.0.0.1:$am_port"
wait_http "$am/-/ready"

starts_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl --fail --silent --show-error --max-time 10 -H 'Content-Type: application/json' \
  -d "[{\"labels\":{\"alertname\":\"VeritySmoke\",\"severity\":\"critical\",\"instance\":\"karma-test\"},\"annotations\":{\"summary\":\"karma smoke test\"},\"startsAt\":\"$starts_at\"}]" \
  "$am/api/v2/alerts" >/dev/null || fail 'posting an alert to alertmanager failed'
curl --fail --silent --show-error --max-time 10 "$am/api/v2/alerts?filter=alertname%3DVeritySmoke" |
  jq -e 'length == 1' >/dev/null || fail 'alertmanager did not store the alert'

docker run --name "$karma" -d --network "$net" --read-only -p 127.0.0.1::8080 "$image" \
  --alertmanager.uri="http://$alertmanager:9093" --alertmanager.name=smoke \
  --alertmanager.interval=2s >/dev/null
port=$(docker port "$karma" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'karma port 8080 was not published'
base="http://127.0.0.1:$port"
wait_http "$base/health"

health=$(curl --fail --silent --show-error --max-time 5 "$base/health") || fail '/health failed'
[ "$health" = Pong ] || fail "/health returned '$health'"

curl --fail --silent --show-error --max-time 5 "$base/version" >"$work/version.json" || fail '/version failed'
jq -e --arg v "$expected_version" '.version == $v' "$work/version.json" >/dev/null ||
  fail "/version is $(cat "$work/version.json"), expected $expected_version"

# The embedded UI: index HTML plus a referenced asset.
curl --fail --silent --show-error --max-time 5 -D "$work/index.headers" "$base/" >"$work/index.html" ||
  fail 'UI index failed'
grep -Fiq 'content-type: text/html' "$work/index.headers" || fail 'UI index is not text/html'
grep -Fq '<title>karma</title>' "$work/index.html" || fail 'UI index has no karma title'
asset=$(grep -o 'src="[^"]*assets/[^"]*\.js"' "$work/index.html" | head -n 1 | sed 's/^src="//; s/"$//')
[ -n "$asset" ] || fail 'UI index references no script asset'
case $asset in /*) ;; *) asset="/$asset" ;; esac
curl --fail --silent --show-error --max-time 5 -o "$work/asset.js" "$base$asset" || fail "UI asset $asset failed"
[ -s "$work/asset.js" ] || fail "UI asset $asset is empty"

# /alerts.json must list the upstream as healthy and include the posted alert.
i=0
while :; do
  if curl --fail --silent --show-error --max-time 10 -H 'Content-Type: application/json' \
    -d '{"filters":[],"gridLabel":"","sortOrder":"","sortLabel":"","defaultGroupLimit":50,"gridLimits":{},"groupLimits":{}}' \
    "$base/alerts.json" >"$work/alerts.json" 2>"$work/alerts.err" &&
    jq -e '.totalAlerts >= 1' "$work/alerts.json" >/dev/null; then
    break
  fi
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail "karma never reported the alert: $(cat "$work/alerts.err" "$work/alerts.json" 2>/dev/null)"
  sleep 2
done
jq -e --arg v "$expected_version" '.version == $v' "$work/alerts.json" >/dev/null ||
  fail 'alerts.json reports the wrong karma version'
jq -e '.upstreams.counters.total == 1 and .upstreams.counters.healthy == 1 and .upstreams.counters.failed == 0' \
  "$work/alerts.json" >/dev/null || fail "unexpected upstream counters: $(jq -c .upstreams.counters "$work/alerts.json")"
jq -e --arg uri "http://$alertmanager:9093" \
  '.upstreams.instances | length == 1 and .[0].name == "smoke" and .[0].uri == $uri and .[0].error == "" and .[0].version != ""' \
  "$work/alerts.json" >/dev/null || fail "unexpected upstream instances: $(jq -c .upstreams.instances "$work/alerts.json")"
jq -e '[.grids[].alertGroups[].alerts[] | select(.labels[] | (.name == "alertname" and .value == "VeritySmoke"))] | length == 1' \
  "$work/alerts.json" >/dev/null || fail 'posted alert is missing from alerts.json'

docker stop "$karma" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$karma")" = 0 ] || fail 'karma did not exit cleanly on SIGTERM'

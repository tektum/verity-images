#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
recipe="$here/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
container="verity-yace-test-$$"
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

[ -n "$version" ] || fail 'could not read the pinned yace version'

# OCI contract: upstream image entrypoint and default config path, nonroot user.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/yace"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["--config.file=/etc/yace/config.yml"]' || fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

reported=$(docker run --rm --network none "$image" version 2>&1) ||
  fail "version failed: $reported"
test "$reported" = "$version" || fail "version reports '$reported', want '$version'"

# The bundled default configuration parses.
docker run --rm --network none "$image" verify-config --config.file=/etc/yace/config.yml \
  >"$work/default-config" 2>&1 || fail "bundled config rejected: $(cat "$work/default-config")"
grep -F 'Config file is valid' "$work/default-config" >/dev/null ||
  fail "bundled config not reported valid: $(cat "$work/default-config")"

# A static CloudWatch job; it needs no resource discovery and no credentials to load.
cat >"$work/config.yml" <<'EOF'
apiVersion: v1alpha1
static:
  - namespace: AWS/AutoScaling
    name: verity-smoke
    regions: [us-east-1]
    dimensions:
      - name: AutoScalingGroupName
        value: verity-smoke
    metrics:
      - name: GroupInServiceInstances
        statistics: [Minimum]
        period: 60
        length: 300
EOF
# The job lacks a region, which yace rejects during config validation.
cat >"$work/bad.yml" <<'EOF'
apiVersion: v1alpha1
static:
  - namespace: AWS/AutoScaling
    name: verity-smoke
    metrics:
      - name: GroupInServiceInstances
        statistics: [Minimum]
        period: 60
        length: 300
EOF
chmod 0644 "$work/config.yml" "$work/bad.yml"

docker run --rm --network none -v "$work/config.yml:/etc/yace/config.yml:ro" \
  "$image" verify-config --config.file=/etc/yace/config.yml >"$work/verify-good" 2>&1 ||
  fail "valid config rejected: $(cat "$work/verify-good")"

rc=0
docker run --rm --network none -v "$work/bad.yml:/etc/yace/config.yml:ro" \
  "$image" verify-config --config.file=/etc/yace/config.yml >"$work/verify-bad" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'verify-config accepted a job without regions'
grep -F "Couldn't read config file" "$work/verify-bad" >/dev/null ||
  fail "missing invalid config diagnostic: $(cat "$work/verify-bad")"
grep -F 'Regions should not be empty' "$work/verify-bad" >/dev/null ||
  fail "invalid config diagnostic does not name the missing regions: $(cat "$work/verify-bad")"

# The exporter itself refuses to serve an invalid or missing configuration.
rc=0
docker run --rm --network none -v "$work/bad.yml:/etc/yace/config.yml:ro" \
  "$image" >"$work/serve-bad" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'exporter started with an invalid config'
grep -F "couldn't read /etc/yace/config.yml" "$work/serve-bad" >/dev/null ||
  fail "missing invalid config startup diagnostic: $(cat "$work/serve-bad")"

rc=0
docker run --rm --network none "$image" --config.file=/does/not/exist.yml \
  >"$work/serve-missing" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'exporter started without a config file'
grep -F 'no such file or directory' "$work/serve-missing" >/dev/null ||
  fail "missing config file diagnostic: $(cat "$work/serve-missing")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/bad-flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'unknown flag unexpectedly accepted'
grep -F 'flag provided but not defined' "$work/bad-flag" >/dev/null ||
  fail "unknown flag diagnostic is missing: $(cat "$work/bad-flag")"

# Serve the static job without any AWS credentials. IMDS is disabled so the
# credential chain fails fast; every endpoint must still answer.
docker run --name "$container" -d --read-only --publish 127.0.0.1::5000 \
  --env AWS_EC2_METADATA_DISABLED=true \
  -v "$work/config.yml:/etc/yace/config.yml:ro" \
  "$image" --config.file=/etc/yace/config.yml --scraping-interval=5 >/dev/null || fail 'exporter failed to start'
port=$(docker port "$container" 5000/tcp | sed -n 's/^127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' | sed -n 1p)
[ -n "$port" ] || fail "exporter port is not published: $(docker port "$container")"
base="http://127.0.0.1:$port"

i=0
until health=$(curl --fail --silent --connect-timeout 1 --max-time 5 "$base/healthz"); do
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    docker logs "$container" >&2 || true
    fail 'exporter /healthz never became ready'
  fi
  sleep 1
done
test "$health" = ok || fail "/healthz returned '$health'"

curl --fail --silent --max-time 5 "$base/" >"$work/index" || fail '/ request failed'
grep -F '<title>Yet Another CloudWatch Exporter</title>' "$work/index" >/dev/null ||
  fail "index page is not yace: $(cat "$work/index")"
grep -F "Version: $version" "$work/index" >/dev/null ||
  fail "index page does not report version $version: $(cat "$work/index")"

# The static job resolves the account through STS first; without credentials
# that fails and the scrape stops before it calls CloudWatch.
i=0
until docker logs "$container" 2>&1 | grep -F "Couldn't get account Id" >"$work/scrape-error"; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    docker logs "$container" >&2 || true
    fail 'scrape without credentials did not report an error'
  fi
  sleep 1
done
grep -F 'get credentials' "$work/scrape-error" >/dev/null ||
  fail "scrape error is not a credential failure: $(cat "$work/scrape-error")"
docker logs "$container" >"$work/logs" 2>&1
grep -F 'Yace startup completed' "$work/logs" >/dev/null ||
  fail "startup log is missing: $(cat "$work/logs")"
grep -F "version=$version, branch=HEAD, revision=" "$work/logs" >/dev/null ||
  fail "startup log does not report build info for $version: $(cat "$work/logs")"

curl --fail --silent --max-time 5 "$base/metrics" >"$work/metrics" || fail '/metrics request failed'
grep -Fx '# TYPE yace_cloudwatch_getmetricdata_requests_total counter' "$work/metrics" >/dev/null ||
  fail "yace GetMetricData counter missing from /metrics: $(cat "$work/metrics")"
grep -Fx 'yace_cloudwatch_getmetricdata_requests_total 0' "$work/metrics" >/dev/null ||
  fail "GetMetricData was called without credentials: $(cat "$work/metrics")"
grep -E '^yace_cloudwatch_resourcegrouptaggingapi_requests_total [0-9]' "$work/metrics" >/dev/null ||
  fail "yace tagging API counter missing from /metrics: $(cat "$work/metrics")"
if grep -E '^aws_autoscaling_' "$work/metrics" >/dev/null; then
  fail 'CloudWatch data served without credentials'
fi

# Reload is POST-only and re-reads the mounted config.
status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 "$base/reload")
test "$status" = 404 || fail "GET /reload returned $status, want 404"
status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 -X POST "$base/reload")
test "$status" = 200 || fail "POST /reload returned $status, want 200"
i=0
until [ "$(docker logs "$container" 2>&1 | grep -c 'Reset clients cache')" -ge 1 ]; do
  i=$((i + 1))
  [ "$i" -lt 10 ] || fail 'reload did not re-read the configuration'
  sleep 1
done

docker stop "$container" >/dev/null || fail 'exporter did not stop'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"

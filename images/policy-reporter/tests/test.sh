#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
recipe="$here/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
work=$(mktemp -d)
stub=
container=
probe=

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [ -n "$container" ]; then
    printf -- '--- container logs ---\n' >&2
    docker logs "$container" >&2 2>&1 || true
  fi
  if [ -s "$work/kube.log" ]; then
    printf -- '--- Kubernetes API stub requests ---\n' >&2
    cat "$work/kube.log" >&2
  fi
  exit 1
}

cleanup() {
  [ -z "$container" ] || docker rm -f "$container" >/dev/null 2>&1 || true
  [ -z "$probe" ] || docker rm -f "$probe" >/dev/null 2>&1 || true
  [ -z "$stub" ] || kill "$stub" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

write_kubeconfig() {
  cat >"$1" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: smoke
    cluster:
      server: http://127.0.0.1:$2
users:
  - name: smoke
    user: {}
contexts:
  - name: smoke
    context:
      cluster: smoke
      user: smoke
current-context: smoke
EOF
  chmod 0644 "$1"
}

[ -n "$version" ] || fail 'could not read the pinned policy-reporter version'

# Upstream image contract: USER 1234, WORKDIR /app, and
# ENTRYPOINT ["/app/policyreporter", "run"] with no CMD, so Helm chart args
# are flags for the run subcommand.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1234 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/app/policyreporter","run"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /app ||
  fail 'unexpected working directory'

# The binary carries the release version the way the upstream Makefile stamps it.
docker run --rm --network none --entrypoint /app/policyreporter "$image" version \
  >"$work/version" 2>&1 || fail "version failed: $(cat "$work/version")"
grep -Fx "AppVersion: $version" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

# The report templates and license sit in /app as in the upstream image.
probe=$(docker create "$image")
mkdir "$work/app"
docker cp "$probe:/app/templates" "$work/app/templates" >/dev/null ||
  fail '/app/templates is missing'
docker cp "$probe:/app/LICENSE.md" "$work/app/LICENSE.md" >/dev/null ||
  fail '/app/LICENSE.md is missing'
docker rm "$probe" >/dev/null
probe=
for template in summary.html violations.html; do
  grep -F '{{' "$work/app/templates/$template" >/dev/null ||
    fail "/app/templates/$template is not a Go template"
done
grep -F 'MIT License' "$work/app/LICENSE.md" >/dev/null || fail 'unexpected /app/LICENSE.md'

# Negative cases: an unknown flag for the run subcommand, a configuration that
# fails validation, and a kubeconfig whose API server is closed.
rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/badflag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'unknown flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/badflag" >/dev/null ||
  fail "unknown flag diagnostic is missing: $(cat "$work/badflag")"

printf 'rest:\n  enabled: false\n  waitForInitialReports: true\n' >"$work/invalid.yaml"
chmod 0644 "$work/invalid.yaml"
rc=0
docker run --rm --network none -v "$work/invalid.yaml:/app/config.yaml:ro" "$image" \
  >"$work/badconfig" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid configuration unexpectedly succeeded'
grep -F 'rest.waitForInitialReports requires rest.enabled' "$work/badconfig" >/dev/null ||
  fail "configuration validation diagnostic is missing: $(cat "$work/badconfig")"

closed=$(free_port)
write_kubeconfig "$work/closed-kubeconfig" "$closed"
rc=0
docker run --rm --network host -v "$work/closed-kubeconfig:/kubeconfig:ro" "$image" \
  --kubeconfig=/kubeconfig >"$work/nocluster" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'started against a closed Kubernetes API endpoint'
grep -F 'no valid reporting API group found in the cluster' "$work/nocluster" >/dev/null ||
  fail "closed API endpoint diagnostic is missing: $(cat "$work/nocluster")"

# Policy Reporter exits unless API discovery finds a PolicyReport group, so the
# server cannot be exercised against an unreachable API. A stub API serves one
# PolicyReport and one ClusterPolicyReport (see fake_kube_api.py).
kube_port=$(free_port)
api_port=$(free_port)
python3 "$here/fake_kube_api.py" "$kube_port" "$work/kube.log" &
stub=$!
ready=0
for _ in $(seq 1 50); do
  if python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1)' "$kube_port" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.1
done
test "$ready" -eq 1 || fail 'Kubernetes API stub did not start'
write_kubeconfig "$work/kubeconfig" "$kube_port"

# Configure only through the default ./config.yaml in /app, the path the Helm
# chart mounts, with the SQLite database on a volume as the chart does.
cat >"$work/config.yaml" <<EOF
k8sClient:
  kubeconfig: /kubeconfig
api:
  port: $api_port
rest:
  enabled: true
metrics:
  enabled: true
dbfile: /sqlite/database.db
EOF
chmod 0644 "$work/config.yaml"
mkdir "$work/sqlite"
chmod 0777 "$work/sqlite"
container=$(docker run -d --network host --read-only --tmpfs /tmp \
  -v "$work/config.yaml:/app/config.yaml:ro" \
  -v "$work/kubeconfig:/kubeconfig:ro" \
  -v "$work/sqlite:/sqlite" \
  "$image") || fail 'server container did not start'

url="http://127.0.0.1:$api_port"
ready=0
for _ in $(seq 1 120); do
  if curl -fsS "$url/ready" >"$work/ready" 2>/dev/null; then
    ready=1
    break
  fi
  test "$(docker inspect --format '{{.State.Running}}' "$container")" = true ||
    fail 'server exited before readiness'
  sleep 0.5
done
test "$ready" -eq 1 || fail 'server never became ready'
test "$(cat "$work/ready")" = '{}' || fail "unexpected readiness body: $(cat "$work/ready")"
curl -fsS "$url/healthz" >"$work/healthz" || fail 'healthz failed'
test "$(cat "$work/healthz")" = '{}' || fail "unexpected healthz body: $(cat "$work/healthz")"

# Each report reaches the REST API and the metrics through its own informer,
# queue worker, and listener, so poll for every one of them.
poll_until() {
  path=$1 out=$2 pattern=$3
  for _ in $(seq 1 60); do
    curl -fsS "$url$path" >"$out" || fail "$path request failed"
    if grep -E "$pattern" "$out" >/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  fail "$path never matched $pattern: $(cat "$out")"
}

poll_until /v1/policy-reports "$work/polr.json" '"count":1'
python3 - "$work/polr.json" <<'EOF' || fail "unexpected policy-reports body: $(cat "$work/polr.json")"
import json
import sys

items = json.load(open(sys.argv[1]))["items"]
assert len(items) == 1, items
report = items[0]
assert report["name"] == "smoke-polr", report
assert report["namespace"] == "smoke", report
assert (report["pass"], report["fail"]) == (1, 1), report
EOF
poll_until /v1/cluster-policy-reports "$work/cpolr.json" '"name":"smoke-cpolr"'
curl -fsS "$url/v2/policies" >"$work/policies.json" || fail 'v2 policies request failed'
grep -F '"policy":"require-run-as-non-root","severity":"high","results":{"fail":1}' \
  "$work/policies.json" >/dev/null || fail "v2 policies missing failure: $(cat "$work/policies.json")"

# The HTML violations report renders from the report templates.
curl -fsS "$url/v1/html-report/violations" >"$work/violations.html" ||
  fail 'violations report request failed'
grep -F 'PolicyReport Summary' "$work/violations.html" >/dev/null ||
  fail 'violations report did not render the template'
grep -F 'smoke-pod' "$work/violations.html" >/dev/null ||
  fail 'violations report is missing the failing resource'

poll_until /metrics "$work/metrics" \
  '^policy_report_result\{.*policy="require-run-as-non-root".*status="fail".*\} 1$'
poll_until /metrics "$work/metrics" \
  '^cluster_policy_report_result\{.*policy="require-namespace-labels".*status="warn".*\} 1$'

# The SQLite database is written by uid 1234 with gid 0, as with the upstream
# image, which has no passwd entry for that user.
test -s "$work/sqlite/database.db" || fail 'SQLite database was not created'
test "$(stat -c '%u:%g' "$work/sqlite/database.db")" = 1234:0 ||
  fail "unexpected database owner: $(stat -c '%u:%g' "$work/sqlite/database.db")"

# Like upstream, SIGTERM stops the process promptly by signal.
start=$(date +%s)
docker stop --time 20 "$container" >/dev/null || fail 'docker stop failed'
elapsed=$(($(date +%s) - start))
test "$elapsed" -lt 15 || fail "SIGTERM took ${elapsed}s"
test "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 143 ||
  fail "unexpected exit code after SIGTERM: $(docker inspect --format '{{.State.ExitCode}}' "$container")"

echo 'SMOKE PASS'

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
chmod 755 "$work"

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

recipe="$here/../melange.yaml"
expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "$recipe")
expected_commit=$(awk '$1 == "source-commit:" { print $2; exit }' "$recipe")
[ -n "$expected_version" ] || fail 'could not read the recipe version'
[ -n "$expected_commit" ] || fail 'could not read the recipe source commit'
expected_branch="release-$(printf '%s' "$expected_version" | tr . -)"
operator=/usr/local/bin/percona-server-mongodb-operator

run() {
  docker run --rm --network none --read-only "$@"
}

# OCI contract. The upstream Deployment runs `percona-server-mongodb-operator`
# through PATH and the CR pods run /init-entrypoint.sh from this image.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  "[\"$operator\"]" || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" >"$work/env"
grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' "$work/env" >/dev/null ||
  fail 'CA bundle environment is missing'
grep -E '^PATH=(.*:)?/usr/local/bin(:.*)?$' "$work/env" >/dev/null ||
  fail 'PATH does not resolve the operator by name'
run --entrypoint /bin/sh "$image" -c 'command -v percona-server-mongodb-operator' >"$work/which" 2>&1 ||
  fail "operator is not on PATH: $(cat "$work/which")"
test "$(cat "$work/which")" = "$operator" || fail "operator resolves to $(cat "$work/which")"

# Flag parsing: the operator has no version flag; it prints its stamped
# build info in the first startup log line.
run "$image" -help >"$work/help" 2>&1 || fail "operator -help failed: $(cat "$work/help")"
for flag in -metrics-bind-address -health-probe-bind-address -leader-elect \
  -zap-log-level -zap-devel -zap-encoder; do
  grep -F -e "  $flag" "$work/help" >/dev/null || fail "operator help is missing $flag"
done

status=0
run "$image" --definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" = 2 || fail "invalid flag exited $status, want 2"
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

# Startup without WATCH_NAMESPACE: build stamps are logged, then it refuses to run.
status=0
run "$image" -zap-encoder console >"$work/nowatch" 2>&1 || status=$?
test "$status" = 1 || fail "startup without WATCH_NAMESPACE exited $status, want 1"
grep -F 'Manager starting up' "$work/nowatch" >"$work/startup" ||
  fail "startup log line is missing: $(cat "$work/nowatch")"
grep -F "\"gitCommit\": \"$expected_commit\"" "$work/startup" >/dev/null ||
  fail "operator GitCommit is not stamped: $(cat "$work/startup")"
grep -F "\"gitBranch\": \"$expected_branch\"" "$work/startup" >/dev/null ||
  fail "operator GitBranch is not stamped: $(cat "$work/startup")"
grep -E '"buildTime": "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' "$work/startup" \
  >/dev/null || fail "operator BuildTime is not stamped: $(cat "$work/startup")"
grep -F 'WATCH_NAMESPACE must be set' "$work/nowatch" >/dev/null ||
  fail 'missing WATCH_NAMESPACE diagnostic'

# With both namespaces resolved it reaches the Kubernetes client config and
# fails there, outside a cluster.
printf 'psmdb\n' >"$work/namespace"
chmod 644 "$work/namespace"
status=0
run -e WATCH_NAMESPACE=psmdb -e KUBERNETES_SERVICE_HOST= \
  -v "$work/namespace:/var/run/secrets/kubernetes.io/serviceaccount/namespace:ro" \
  "$image" -zap-encoder console >"$work/noconfig" 2>&1 || status=$?
test "$status" = 1 || fail "startup outside a cluster exited $status, want 1"
grep -F 'failed to get config' "$work/noconfig" >/dev/null ||
  fail "operator did not reach client configuration: $(cat "$work/noconfig")"

# Companion files keep the upstream paths that the operator references.
cat >"$work/files.sh" <<'EOF'
set -eu
for f in /init-entrypoint.sh /ps-entry.sh /physical-restore-ps-entry.sh /pbm-entry.sh \
  /mongot-entrypoint.sh /logcollector/entrypoint.sh /mongodb-healthcheck; do
  [ -f "$f" ] || { echo "missing $f"; exit 1; }
  [ -x "$f" ] || { echo "not executable $f"; exit 1; }
done
for f in /init-entrypoint.sh /ps-entry.sh /physical-restore-ps-entry.sh /pbm-entry.sh \
  /mongot-entrypoint.sh /logcollector/entrypoint.sh; do
  bash -n "$f" || { echo "bash syntax error in $f"; exit 1; }
done
for f in fluentbit/fluentbit.conf fluentbit/fluentbit_mongo.conf fluentbit/fluentbit_mongos.conf \
  fluentbit/parsers_multiline.conf fluentbit/custom/default.conf logrotate/logrotate.conf; do
  [ -f "/logcollector/$f" ] && [ -r "/logcollector/$f" ] || { echo "missing /logcollector/$f"; exit 1; }
done
echo ok
EOF
chmod 644 "$work/files.sh"
run --entrypoint /bin/sh -v "$work/files.sh:/tmp/files.sh:ro" "$image" /tmp/files.sh \
  >"$work/files" 2>&1 || fail "companion files are wrong: $(cat "$work/files")"

# mongodb-healthcheck: version stamps, help, and a failing check without credentials.
# It writes its log file under the working directory, so give it a writable one.
hc() {
  docker run --rm --network none --read-only --tmpfs /work:mode=1777 -w /work \
    --entrypoint /mongodb-healthcheck "$image" "$@"
}
hc --version >"$work/hc-version" 2>&1 || fail "healthcheck --version failed: $(cat "$work/hc-version")"
grep -Ex 'mongodb-healthcheck version [0-9]+\.[0-9]+\.[0-9]+' "$work/hc-version" >/dev/null ||
  fail "unexpected healthcheck version: $(cat "$work/hc-version")"
grep -Fx "git commit $expected_commit, branch $expected_branch" "$work/hc-version" >/dev/null ||
  fail "healthcheck build stamps are wrong: $(cat "$work/hc-version")"
hc --help >"$work/hc-help" 2>&1 || fail "healthcheck --help failed: $(cat "$work/hc-help")"
for word in --username --password --ssl k8s; do
  grep -F -e "$word" "$work/hc-help" >/dev/null || fail "healthcheck help is missing $word"
done
status=0
hc k8s liveness >"$work/hc-nocreds" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'healthcheck without credentials unexpectedly succeeded'
grep -E 'required flag --(username|password) not provided' "$work/hc-nocreds" >/dev/null ||
  fail "healthcheck credential diagnostic is missing: $(cat "$work/hc-nocreds")"
status=0
hc --definitely-invalid >"$work/hc-invalid" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'healthcheck invalid flag unexpectedly succeeded'
grep -F "unknown long flag '--definitely-invalid'" "$work/hc-invalid" >/dev/null ||
  fail "healthcheck invalid flag diagnostic is missing: $(cat "$work/hc-invalid")"

# The pod init container runs /init-entrypoint.sh as the pod user to copy the
# companions into the shared /opt/percona volume.
docker run --rm --network none --read-only --user 1001:1001 \
  --tmpfs /opt/percona:uid=1001,gid=1001,mode=0755,exec \
  --entrypoint /bin/sh "$image" -c '
    out=$(/init-entrypoint.sh 2>&1) || { printf "%s\\n" "$out"; exit 1; }
    for f in ps-entry.sh physical-restore-ps-entry.sh mongodb-healthcheck pbm-entry.sh \
      mongot-entrypoint.sh logcollector/entrypoint.sh; do
      [ -x "/opt/percona/$f" ] || { echo "init did not install /opt/percona/$f"; exit 1; }
    done
    [ -f /opt/percona/logcollector/fluentbit/fluentbit.conf ] || { echo "logcollector config not copied"; exit 1; }
    cd /opt/percona && /opt/percona/mongodb-healthcheck --version
  ' >"$work/init" 2>&1 || fail "init entrypoint failed: $(cat "$work/init")"
grep -Fx "git commit $expected_commit, branch $expected_branch" "$work/init" >/dev/null ||
  fail "copied healthcheck does not run: $(cat "$work/init")"

printf 'SMOKE PASS image=%s\n' "$image"

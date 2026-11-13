#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
container=
cleanup() {
  [ -z "$container" ] || docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# Runtime contract of the upstream gha-runner-scale-set-controller image
# (Dockerfile on gcr.io/distroless/static:nonroot).
inspect() {
  docker image inspect --format "$1" "$image"
}
[ "$(inspect '{{.Config.User}}')" = 65532:65532 ] || fail "unexpected OCI user: $(inspect '{{.Config.User}}')"
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/manager"]' ] || fail 'unexpected entrypoint'
[ "$(inspect '{{json .Config.Cmd}}')" = null ] || fail 'unexpected default command'
working_dir=$(inspect '{{.Config.WorkingDir}}')
[ -z "$working_dir" ] || [ "$working_dir" = / ] || fail "unexpected working directory: $working_dir"
inspect '{{range .Config.Env}}{{println .}}{{end}}' |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

run() {
  docker run --rm --network none --read-only "$@"
}

# The Helm charts start the listener as /ghalistener and the legacy controller
# components by their root paths; every binary the upstream image ships is here.
container=$(docker create "$image")
docker export "$container" >"$work/rootfs.tar" || fail 'image export failed'
docker rm "$container" >/dev/null
container=
mkdir "$work/rootfs"
tar -xf "$work/rootfs.tar" -C "$work/rootfs" --exclude='dev/*' || fail 'image rootfs extraction failed'
for path in manager ghalistener github-webhook-server actions-metrics-server sleep \
  etc/ssl/certs/ca-certificates.crt usr/share/zoneinfo/Etc/UTC; do
  [ -s "$work/rootfs/$path" ] || fail "image is missing /$path"
done
for bin in manager ghalistener github-webhook-server actions-metrics-server sleep; do
  [ -x "$work/rootfs/$bin" ] || fail "/$bin is not executable"
done
head -c 4 "$work/rootfs/usr/share/zoneinfo/Etc/UTC" | grep -Fx TZif >/dev/null ||
  fail 'zoneinfo database is not readable'

# The image is the controller only, like the distroless upstream image.
# Check the exported rootfs so a present tool cannot pass by rejecting the
# probe's arguments.
for tool in bin/sh usr/bin/kubectl; do
  if [ -e "$work/rootfs/$tool" ] || [ -L "$work/rootfs/$tool" ]; then
    fail "unexpected /$tool in the image"
  fi
done

status=0
run "$image" -help >"$work/help" 2>&1 || status=$?
[ "$status" -eq 0 ] || fail "manager -help exited $status: $(cat "$work/help")"
for flag in auto-scaling-runner-set-only metrics-addr health-probe-bind-address enable-leader-election \
  log-level log-format watch-single-namespace; do
  grep -E -- "^ +-${flag}( |$)" "$work/help" >/dev/null || fail "manager help is missing -$flag"
done

# Negative cases: unknown flag, invalid log format, missing pod namespace, and
# no cluster. Each must fail fast with its diagnostic instead of crash-looping.
status=0
run "$image" -definitely-invalid >"$work/invalid" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'unknown flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "unknown flag diagnostic is missing: $(cat "$work/invalid")"

status=0
run "$image" -auto-scaling-runner-set-only -log-format yaml >"$work/logformat" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'invalid log format unexpectedly succeeded'
grep -F 'Error: creating logger' "$work/logformat" >/dev/null ||
  fail "invalid log format diagnostic is missing: $(cat "$work/logformat")"

status=0
run "$image" -auto-scaling-runner-set-only >"$work/nonamespace" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'manager without a pod namespace unexpectedly succeeded'
grep -F 'unable to obtain manager pod namespace' "$work/nonamespace" >/dev/null ||
  fail "pod namespace diagnostic is missing: $(cat "$work/nonamespace")"

status=0
timeout 60 docker run --rm --network none --read-only \
  -e CONTROLLER_MANAGER_POD_NAMESPACE=arc-systems \
  "$image" -auto-scaling-runner-set-only >"$work/nocluster" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'manager outside a cluster unexpectedly succeeded'
[ "$status" -ne 124 ] || fail 'manager hung outside a cluster instead of failing fast'
grep -F 'unable to get kubeconfig' "$work/nocluster" >/dev/null ||
  fail "no-cluster diagnostic is missing: $(cat "$work/nocluster")"

# The listener reads its JSON configuration from LISTENER_CONFIG_PATH and
# validates it before contacting GitHub.
status=0
run --entrypoint /ghalistener "$image" >"$work/listener-noenv" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'listener without configuration unexpectedly succeeded'
grep -F 'LISTENER_CONFIG_PATH environment variable is not set' "$work/listener-noenv" >/dev/null ||
  fail "listener missing-config diagnostic is missing: $(cat "$work/listener-noenv")"

printf '{}\n' >"$work/listener.json"
chmod 0644 "$work/listener.json"
status=0
run -v "$work/listener.json:/etc/listener/config.json:ro" \
  -e LISTENER_CONFIG_PATH=/etc/listener/config.json \
  --entrypoint /ghalistener "$image" >"$work/listener-empty" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'listener with an empty configuration unexpectedly succeeded'
grep -F 'GitHubConfigUrl is not provided' "$work/listener-empty" >/dev/null ||
  fail "listener validation diagnostic is missing: $(cat "$work/listener-empty")"

# The sleep helper honors its duration flag and exits cleanly.
run --entrypoint /sleep "$image" -seconds 0 >"$work/sleep" 2>&1 || fail "sleep failed: $(cat "$work/sleep")"
grep -Fx 'sleeping for 0 seconds' "$work/sleep" >/dev/null || fail "unexpected sleep output: $(cat "$work/sleep")"
grep -Fx 'done sleeping' "$work/sleep" >/dev/null || fail "sleep did not finish: $(cat "$work/sleep")"

for bin in github-webhook-server actions-metrics-server; do
  status=0
  run --entrypoint "/$bin" "$image" -help >"$work/$bin" 2>&1 || status=$?
  [ "$status" -eq 0 ] || fail "$bin -help exited $status: $(cat "$work/$bin")"
  grep -E -- '^ +-webhook-addr( |$)' "$work/$bin" >/dev/null || fail "$bin help is missing -webhook-addr"
done

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"

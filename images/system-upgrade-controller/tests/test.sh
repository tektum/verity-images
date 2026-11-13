#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'
expected_commit=$(awk '$1 == "source-commit:" { print substr($2, 1, 7); exit }' \
  "$here/../melange.yaml")
[ -n "$expected_commit" ] || fail 'could not read the recipe source commit'

# Runtime contract of the upstream release image (package/Dockerfile, target controller).
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65534:65534 ||
  fail "unexpected OCI user: $(docker image inspect --format '{{.Config.User}}' "$image")"
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/bin/system-upgrade-controller"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
working_dir=$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")
[ -z "$working_dir" ] || [ "$working_dir" = / ] ||
  fail "unexpected working directory: $working_dir"
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

run() {
  docker run --rm --network none --read-only "$@"
}

# The binary is stamped like the upstream release: tag version and short commit.
run "$image" --version >"$work/version" 2>&1 || fail 'controller --version failed'
grep -Fx "system-upgrade-controller version v${expected_version} (${expected_commit})" \
  "$work/version" >/dev/null || fail "unexpected version output: $(cat "$work/version")"

run "$image" --help >"$work/help" 2>&1 || fail 'controller --help failed'
grep -F "v${expected_version} (${expected_commit})" "$work/help" >/dev/null ||
  fail 'help does not report the stamped version'
for pair in debug:DEBUG leader-elect:LEADER_ELECT kubeconfig:KUBE_CONFIG master:MASTER_URL \
  name:NAME node-name:NODE_NAME namespace:NAMESPACE threads:THREADS; do
  flag=${pair%%:*}
  env_name=SYSTEM_UPGRADE_CONTROLLER_${pair#*:}
  grep -E -- "^ +--${flag}( value)? +.*\[\\\$${env_name}\]" "$work/help" >/dev/null ||
    fail "help is missing --${flag} bound to \$${env_name}"
done
grep -E -- '--threads value +\(default: 2\)' "$work/help" >/dev/null ||
  fail 'help is missing the default thread count'

# The image ships the controller only, like the scratch-based upstream image;
# kubectl runs in the separate SYSTEM_UPGRADE_JOB_KUBECTL_IMAGE job image.
for tool in kubectl sh; do
  if run --entrypoint "/usr/bin/$tool" "$image" version >/dev/null 2>&1; then
    fail "unexpected $tool in the image"
  fi
done

# Upstream copies the zoneinfo database into the image; keep that path.
container=$(docker create "$image")
docker cp "$container:/usr/share/zoneinfo/Europe/Berlin" "$work/zoneinfo" >/dev/null 2>&1 ||
  status=$?
docker rm "$container" >/dev/null
head -c 4 "$work/zoneinfo" 2>/dev/null | grep -Fx TZif >/dev/null ||
  fail 'zoneinfo database is missing'

# Negative cases: unknown flag, missing required settings, and no cluster.
status=0
run "$image" --definitely-invalid >"$work/invalid" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'unknown flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "unknown flag diagnostic is missing: $(cat "$work/invalid")"

status=0
run "$image" >"$work/required" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'controller without name and namespace unexpectedly succeeded'
grep -F 'Required flags \"name, namespace\" not set' "$work/required" >/dev/null ||
  fail "required flag diagnostic is missing: $(cat "$work/required")"

# Settings come from SYSTEM_UPGRADE_CONTROLLER_* env, as in the upstream manifests.
# Outside a cluster and without a kubeconfig it must fail fast, not crash-loop.
status=0
timeout 60 docker run --rm --network none --read-only \
  -e SYSTEM_UPGRADE_CONTROLLER_NAME=system-upgrade-controller \
  -e SYSTEM_UPGRADE_CONTROLLER_NAMESPACE=system-upgrade \
  "$image" >"$work/nocluster" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'controller outside a cluster unexpectedly succeeded'
[ "$status" -ne 124 ] || fail 'controller hung outside a cluster instead of failing fast'
grep -F 'unable to load in-cluster configuration, KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined' \
  "$work/nocluster" >/dev/null || fail "in-cluster diagnostic is missing: $(cat "$work/nocluster")"
grep -F 'level=fatal msg="invalid configuration: no configuration has been provided' \
  "$work/nocluster" >/dev/null || fail "no-cluster fatal error is missing: $(cat "$work/nocluster")"

status=0
timeout 60 docker run --rm --network none --read-only \
  -e SYSTEM_UPGRADE_CONTROLLER_NAME=system-upgrade-controller \
  -e SYSTEM_UPGRADE_CONTROLLER_NAMESPACE=system-upgrade \
  -e SYSTEM_UPGRADE_CONTROLLER_KUBE_CONFIG=/nonexistent/kubeconfig \
  "$image" >"$work/nokubeconfig" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'controller with a missing kubeconfig unexpectedly succeeded'
[ "$status" -ne 124 ] || fail 'controller hung with a missing kubeconfig'
grep -F 'level=fatal msg="stat /nonexistent/kubeconfig: no such file or directory"' \
  "$work/nokubeconfig" >/dev/null ||
  fail "missing kubeconfig diagnostic is missing: $(cat "$work/nokubeconfig")"

printf 'SMOKE PASS image=%s\n' "$image"

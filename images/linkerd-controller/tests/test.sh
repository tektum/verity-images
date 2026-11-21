#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
recipe="$(dirname "$0")/../melange.yaml"
container=

cleanup() {
  [ -z "$container" ] || docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# fail MESSAGE [LOG]: report the broken assertion and the log behind it.
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [ -n "${2:-}" ] && [ -f "$2" ]; then
    printf -- '--- %s\n' "$2" >&2
    tail -n 20 "$2" >&2
  fi
  exit 1
}

# Hardened like the Linkerd chart: read-only root, no capabilities, no network.
run() {
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges "$@"
}

# expect_fail NAME TEXT ARGS...: the run must exit non-zero and log TEXT.
expect_fail() {
  name=$1 text=$2
  shift 2
  if run "$@" >"$work/$name.log" 2>&1; then
    fail "$name unexpectedly succeeded" "$work/$name.log"
  fi
  grep -F -- "$text" "$work/$name.log" >/dev/null ||
    fail "$name: missing '$text'" "$work/$name.log"
}

[ -f "$recipe" ] || fail "recipe not found: $recipe"
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")
[ -n "$version" ] || fail 'cannot read package.version from melange.yaml'
expected="edge-${version}"

# OCI contract: upstream entrypoint and working directory; non-root default
# user matching the chart's controllerUID.
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/controller"]' || fail 'entrypoint is not /controller'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'image unexpectedly sets a default command'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 2103 ||
  fail 'default user is not 2103'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'working directory is not /'

# Upstream file layout.
container=$(docker create "$image")
docker export "$container" | tar -tvf - >"$work/files"
for path in controller linkerd-policy-controller; do
  grep -E "^-rwxr-xr-x .* ${path}\$" "$work/files" >/dev/null ||
    fail "/$path is missing or not executable"
done
grep -E '^-rw-r--r-- .* linkerd/LICENSE$' "$work/files" >/dev/null ||
  fail '/linkerd/LICENSE is missing'
grep -E ' etc/ssl/certs/ca-certificates\.crt( -> .*)?$' "$work/files" >/dev/null ||
  fail 'CA bundle is missing'
docker cp "$container:/linkerd/LICENSE" "$work/LICENSE"
grep -F 'Apache License' "$work/LICENSE" >/dev/null || fail 'LICENSE is not Apache-2.0'
docker cp -L "$container:/etc/ssl/certs/ca-certificates.crt" "$work/ca.crt"
grep -F 'BEGIN CERTIFICATE' "$work/ca.crt" >/dev/null || fail 'CA bundle has no certificates'

# Subcommand dispatch, as upstream: no listing, an explicit error.
expect_fail no-subcommand 'expected a subcommand' "$image"
expect_fail bad-subcommand 'unknown subcommand: bogus' "$image" bogus

# Every upstream subcommand dispatches, parses its flags, and reports the
# stamped release; a runtime override cannot change it.
for sub in destination heartbeat identity proxy-injector service-mirror sp-validator; do
  log="$work/$sub-version.log"
  run "$image" "$sub" -version >"$log" 2>&1 || fail "$sub -version failed" "$log"
  test "$(cat "$log")" = "$expected" || fail "$sub -version did not print $expected" "$log"
  log="$work/$sub-help.log"
  run "$image" "$sub" -help >"$log" 2>&1 || fail "$sub -help failed" "$log"
  grep -F "Usage of $sub:" "$log" >/dev/null || fail "$sub -help has no usage header" "$log"
  grep -F -- '-kubeconfig' "$log" >/dev/null || fail "$sub -help does not list -kubeconfig" "$log"
done
log="$work/override.log"
run -e LINKERD_CONTAINER_VERSION_OVERRIDE=edge-0.0.0 "$image" destination -version >"$log" 2>&1 ||
  fail 'destination -version with override failed' "$log"
test "$(cat "$log")" = "$expected" || fail 'version override replaced the stamp' "$log"
expect_fail bad-flag 'flag provided but not defined: -definitely-invalid' \
  "$image" destination -definitely-invalid

# Policy controller (Rust). Upstream builds clap without its help feature, so
# --help is rejected exactly as by cr.l5d.io/linkerd/controller; parsing is
# proven instead by the required flag, value validation, and reaching the
# Kubernetes client with chart-style arguments.
policy='--entrypoint /linkerd-policy-controller'
policy_args='--default-opaque-ports=25,587,3306 --admin-addr=127.0.0.1:9990'
policy_args="$policy_args --grpc-addr=127.0.0.1:8090 --server-addr=127.0.0.1:9443"
# shellcheck disable=SC2086
expect_fail policy-help 'error: unexpected argument found' $policy "$image" --help
# shellcheck disable=SC2086
expect_fail policy-missing-required 'error: one or more required arguments were not provided' \
  $policy "$image"
# shellcheck disable=SC2086
expect_fail policy-bad-ports 'invalid digit found in string' \
  $policy "$image" --default-opaque-ports=notaport

# Negative: without an API server, every component fails on client setup.
no_config='no configuration has been provided'
expect_fail destination-no-cluster 'Failed to initialize K8s API Client' "$image" destination
grep -F "$no_config" "$work/destination-no-cluster.log" >/dev/null ||
  fail 'destination: missing Kubernetes configuration diagnostic' "$work/destination-no-cluster.log"
expect_fail proxy-injector-no-cluster "error building Kubernetes API config: invalid configuration: $no_config" \
  "$image" proxy-injector
expect_fail sp-validator-no-cluster "error building Kubernetes API config: invalid configuration: $no_config" \
  "$image" sp-validator
expect_fail service-mirror-no-cluster "Failed to initialize K8s API: error configuring Kubernetes API client" \
  "$image" service-mirror
# shellcheck disable=SC2086
expect_fail policy-no-cluster 'Error: failed to read an incluster environment variable' \
  $policy "$image" $policy_args
# shellcheck disable=SC2086
expect_fail policy-missing-kubeconfig "failed to read kubeconfig from '\"/definitely-missing\"'" \
  $policy "$image" $policy_args --kubeconfig=/definitely-missing
# Heartbeat reports the stamped version upstream and fails without a network.
expect_fail heartbeat-offline 'Failed to send heartbeat' "$image" heartbeat
grep -F "source=heartbeat&version=${expected}" "$work/heartbeat-offline.log" >/dev/null ||
  fail 'heartbeat does not report the stamped version' "$work/heartbeat-offline.log"

# Negative: identity rejects missing and malformed trust anchors offline.
identity_args='identity -identity-scheme=linkerd.io/tls -identity-trust-domain=cluster.local'
identity_args="$identity_args -controller-namespace=linkerd"
# shellcheck disable=SC2086
expect_fail identity-no-anchors 'could not read identity trust anchors PEM' \
  "$image" $identity_args
mkdir -p "$work/roots"
printf 'not a certificate\n' >"$work/roots/ca-bundle.crt"
chmod 0755 "$work/roots"
chmod 0644 "$work/roots/ca-bundle.crt"
# shellcheck disable=SC2086
expect_fail identity-bad-anchors 'Failed to read trust anchors' \
  -v "$work/roots:/var/run/linkerd/identity/trust-roots:ro" "$image" $identity_args

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected"

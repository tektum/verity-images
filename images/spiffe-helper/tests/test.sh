#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
recipe="$(dirname "$0")/../melange.yaml"
work=$(mktemp -d)
container="verity-spiffe-helper-test-$$"
label=verity.smoke=spiffe-helper
missing_socket=/run/spire/sockets/missing-agent.sock

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [ -n "${2:-}" ] && [ -f "$2" ]; then
    sed 's/^/  | /' "$2" >&2
  fi
  exit 1
}

# Runs the image read-only without a network. Output goes to $work/$1 and the
# container exit status to $status.
run_image() {
  name=$1
  shift
  set +e
  docker run --rm --network none --read-only --label "$label" "$@" >"$work/$name" 2>&1
  status=$?
  set -e
}

expected_version=$(awk '
  /^package:/ { in_package = 1; next }
  /^[^[:space:]]/ { in_package = 0 }
  in_package && $1 == "version:" { gsub(/"/, "", $2); print $2; exit }
' "$recipe")
[ -n "$expected_version" ] || fail "package.version not found in $recipe"

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'OCI user is not 1000'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/spiffe-helper"]' || fail 'entrypoint is not ["/usr/bin/spiffe-helper"]'
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in
  null | '[]') ;;
  *) fail 'command is not empty' ;;
esac
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'working directory is not /home/nonroot'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'SSL_CERT_FILE environment is missing'

run_image version "$image" -version
[ "$status" -eq 0 ] || fail "-version exited $status" "$work/version"
[ "$(cat "$work/version")" = "$expected_version" ] ||
  fail "-version does not print the recipe version $expected_version" "$work/version"

run_image invalid-flag "$image" -definitely-invalid
[ "$status" -eq 2 ] || fail "unknown flag exited $status, expected 2" "$work/invalid-flag"
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid-flag" >/dev/null ||
  fail 'unknown flag diagnostic is missing' "$work/invalid-flag"

# Without -config the helper reads helper.conf from the working directory.
run_image missing-config "$image"
[ "$status" -eq 1 ] || fail "missing config file exited $status, expected 1" "$work/missing-config"
grep -F 'msg="failed to parse configuration"' "$work/missing-config" >/dev/null ||
  fail 'missing config file did not report "failed to parse configuration"' "$work/missing-config"
grep -F 'open helper.conf: no such file or directory' "$work/missing-config" >/dev/null ||
  fail 'missing config file error does not name helper.conf' "$work/missing-config"

cat >"$work/unknown-key.conf" <<'EOF'
agent_address = "/run/spire/sockets/agent.sock"
definitely_unknown_key = "value"
EOF
chmod 644 "$work/unknown-key.conf"
run_image unknown-key -v "$work/unknown-key.conf:/etc/spiffe-helper/helper.conf:ro" \
  "$image" -config /etc/spiffe-helper/helper.conf
[ "$status" -eq 1 ] || fail "unknown config key exited $status, expected 1" "$work/unknown-key"
grep -F 'msg="invalid configuration"' "$work/unknown-key" >/dev/null ||
  fail 'unknown config key did not report "invalid configuration"' "$work/unknown-key"
grep -F 'unknown top level key(s): definitely_unknown_key' "$work/unknown-key" >/dev/null ||
  fail 'unknown config key error does not name the key' "$work/unknown-key"

# A valid one-shot configuration, mounted at the default path, against an
# agent socket that does not exist: the helper must fail on its own, quickly.
cat >"$work/helper.conf" <<EOF
agent_address = "$missing_socket"
cert_dir = "/tmp"
svid_file_name = "svid.pem"
svid_key_file_name = "svid_key.pem"
svid_bundle_file_name = "svid_bundle.pem"
daemon_mode = false
EOF
chmod 644 "$work/helper.conf"
docker run -d --name "$container" --label "$label" --network none --read-only \
  -v "$work/helper.conf:/home/nonroot/helper.conf:ro" "$image" >/dev/null ||
  fail 'could not start the missing agent socket container'
deadline=60
elapsed=0
while [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ]; do
  [ "$elapsed" -lt "$deadline" ] ||
    fail "helper still running ${deadline}s after start with a missing agent socket"
  sleep 1
  elapsed=$((elapsed + 1))
done
docker logs "$container" >"$work/missing-socket" 2>&1
status=$(docker inspect --format '{{.State.ExitCode}}' "$container")
[ "$status" -eq 1 ] || fail "missing agent socket exited $status, expected 1" "$work/missing-socket"
grep -F 'Using configuration file: \"helper.conf\"' "$work/missing-socket" >/dev/null ||
  fail 'helper did not read helper.conf from the working directory' "$work/missing-socket"
grep -F 'msg="Daemon mode disabled"' "$work/missing-socket" >/dev/null ||
  fail 'daemon_mode = false was not honored' "$work/missing-socket"
grep -F 'msg="Error fetching x509 certificates"' "$work/missing-socket" >/dev/null ||
  fail 'missing agent socket did not fail the X.509 SVID fetch' "$work/missing-socket"
grep -F 'code = Unavailable' "$work/missing-socket" >/dev/null ||
  fail 'missing agent socket error is not a gRPC Unavailable error' "$work/missing-socket"
grep -F "dial unix $missing_socket: connect: no such file or directory" \
  "$work/missing-socket" >/dev/null ||
  fail 'missing agent socket error does not name the socket' "$work/missing-socket"
grep -F 'msg="Error starting spiffe-helper"' "$work/missing-socket" >/dev/null ||
  fail 'missing agent socket did not report "Error starting spiffe-helper"' "$work/missing-socket"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"

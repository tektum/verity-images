#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config=$(mktemp)
trap 'rm -f "$config"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

user=$(docker image inspect --format '{{.Config.User}}' "$image")
[ -z "$user" ] || [ "$user" = 0 ] || fail "unexpected image user: $user"
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/kube-scheduler-1.36"]' ] \
  || fail 'unexpected image entrypoint'
metadata=$(dirname "$0")/../metadata.yaml
supported_channel=$(sed -n 's/^versions: *\[\([^]]*\)\].*/\1/p' "$metadata")
[ -n "$supported_channel" ] || fail 'supported version channel missing from metadata'
docker run --rm "$image" --version 2>&1 | grep -E "^Kubernetes v${supported_channel}\.[0-9]+$" >/dev/null \
  || fail 'kube-scheduler version channel check failed'

cat >"$config" <<'EOF'
apiVersion: kubescheduler.config.k8s.io/v99
kind: KubeSchedulerConfiguration
EOF
if output=$(docker run --rm -v "$config:/invalid.yaml:ro" "$image" --config=/invalid.yaml 2>&1); then
  fail 'invalid scheduler configuration unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'kubescheduler.config.k8s.io/v99' >/dev/null \
  || fail 'invalid scheduler configuration did not report the expected error'

printf 'SMOKE PASS image=%s\n' "$image"

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
prefix="verity-spire-agent-test-$$"
agent="$prefix-root"
unprivileged="$prefix-uid1000"
cli=/opt/spire/bin/spire-agent
work=$(mktemp -d)

cleanup() {
  docker rm -f "$agent" "$unprivileged" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || fail 'package version not found in melange.yaml'

# Upstream runs the agent as root; deployments may override the user.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 0 ||
  fail 'OCI user is not 0 as in the upstream agent image'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  "[\"$cli\",\"run\"]" || fail 'unexpected entrypoint'
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in
  null | '[]') ;;
  *) fail 'unexpected default command' ;;
esac
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /opt/spire ||
  fail 'unexpected working directory'

version=$(docker run --rm --network none --entrypoint "$cli" "$image" --version 2>&1) ||
  fail 'spire-agent --version failed'
[ "$version" = "$expected_version" ] ||
  fail "spire-agent reports version $version, expected $expected_version"

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'unknown flag diagnostic is missing'

if docker run --rm --network none --read-only "$image" >"$work/no-config" 2>&1; then
  fail 'agent started without a configuration file'
fi
grep -F 'could not find config file /opt/spire/conf/agent/agent.conf' "$work/no-config" \
  >/dev/null || fail 'missing configuration diagnostic is missing'

if docker run --rm --network none --entrypoint "$cli" "$image" healthcheck \
  >"$work/health" 2>&1; then
  fail 'healthcheck passed without a running agent'
fi
grep -F 'Agent is unhealthy: unable to determine health' "$work/health" >/dev/null ||
  fail 'healthcheck diagnostic is missing'

cat >"$work/agent.conf" <<'EOF'
agent {
  data_dir = "/tmp/spire-agent/data"
  log_level = "INFO"
  server_address = "127.0.0.1"
  server_port = "8081"
  socket_path = "/tmp/spire-agent/public/api.sock"
  trust_domain = "example.org"
  insecure_bootstrap = true
  join_token = "00000000-0000-4000-8000-000000000000"
}

plugins {
  KeyManager "memory" {
    plugin_data {}
  }
  NodeAttestor "join_token" {
    plugin_data {}
  }
  WorkloadAttestor "unix" {
    plugin_data {}
  }
}
EOF
sed 's/"example.org"/"Not A Domain"/' "$work/agent.conf" >"$work/invalid.conf"
chmod 644 "$work/agent.conf" "$work/invalid.conf"

docker run --rm --network none -v "$work/agent.conf:/etc/spire/agent/agent.conf:ro" \
  --entrypoint "$cli" "$image" validate -config /etc/spire/agent/agent.conf \
  >"$work/validate" 2>&1 || fail 'valid configuration was rejected'
grep -Fx 'SPIRE agent configuration file is valid.' "$work/validate" >/dev/null ||
  fail 'configuration validation output is missing'
if docker run --rm --network none -v "$work/invalid.conf:/etc/spire/agent/agent.conf:ro" \
  --entrypoint "$cli" "$image" validate -config /etc/spire/agent/agent.conf \
  >"$work/validate-invalid" 2>&1; then
  fail 'invalid trust domain passed validation'
fi
grep -F 'could not parse trust_domain "Not A Domain"' "$work/validate-invalid" >/dev/null ||
  fail 'invalid trust domain diagnostic is missing'

# With no SPIRE server reachable the agent loads its plugins, retries node
# attestation with backoff and then exits non-zero with the dial error.
start_agent() {
  name=$1
  shift
  docker run -d --name "$name" "$@" --network none --read-only \
    --tmpfs /tmp:rw,mode=1777 -v "$work/agent.conf:/etc/spire/agent/agent.conf:ro" \
    "$image" -config /etc/spire/agent/agent.conf >/dev/null || fail "could not start $name"
}
start_agent "$agent"
start_agent "$unprivileged" --user 1000:1000

for name in "$agent" "$unprivileged"; do
  i=0
  until [ "$(docker inspect --format '{{.State.Status}}' "$name")" = exited ]; do
    i=$((i + 1))
    if [ "$i" -ge 240 ]; then
      docker logs "$name" >&2 || true
      fail "agent in $name did not exit without a server"
    fi
    sleep 1
  done
  docker logs "$name" >"$work/$name.log" 2>&1
  test "$(docker inspect --format '{{.State.ExitCode}}' "$name")" = 1 ||
    fail "agent in $name did not exit with status 1 without a server"
  grep -F "msg=\"Starting agent\" data_dir=/tmp/spire-agent/data version=$expected_version" \
    "$work/$name.log" >/dev/null || fail "agent in $name did not start version $expected_version"
  grep -F 'plugin_name=unix plugin_type=WorkloadAttestor' "$work/$name.log" >/dev/null ||
    fail "agent in $name did not load the unix workload attestor"
  grep -F 'msg="SVID is not found. Starting node attestation"' "$work/$name.log" >/dev/null ||
    fail "agent in $name did not attempt node attestation"
  grep -F 'msg="Agent crashed"' "$work/$name.log" | grep -F \
    'dial tcp 127.0.0.1:8081: connect: connection refused' >/dev/null ||
    fail "agent in $name did not report the unreachable server"
done

printf 'SMOKE PASS image=%s\n' "$image"

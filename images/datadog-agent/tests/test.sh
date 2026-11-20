#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$recipe")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
source_commit=$(sed -n 's/^[[:space:]]*source-commit: \([0-9a-f]\{40\}\)$/\1/p' "$recipe")
[ -n "$source_commit" ] || { printf 'source commit not found\n' >&2; exit 1; }
short_commit=$(printf '%s' "$source_commit" | cut -c1-7)
agent=/opt/datadog-agent/bin/agent/agent
# Packet sender and HTTP reader. It joins the agent's network and PID
# namespaces, so neither container has any route off the host.
python_index='docker.io/library/python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e'
# Placeholder key: the agent only needs one to be configured. Nothing here can
# reach Datadog, because every container runs with --network none.
fake_api_key=00000000000000000000000000000000
suffix=$$
server="verity-datadog-agent-$suffix"
nokey="verity-datadog-agent-nokey-$suffix"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$server" "$nokey" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  for container in "$server" "$nokey"; do
    if docker inspect "$container" >/dev/null 2>&1; then
      docker logs --tail 80 "$container" >&2 || true
    fi
  done
  exit 1
}

inspect() {
  docker image inspect "$image" --format "$1"
}

# OCI contract: the command s6 runs for the core agent upstream, without the
# root s6-overlay entrypoint, and no baked-in API key.
[ "$(inspect '{{.Config.User}}')" = 65532 ] ||
  fail "image user is $(inspect '{{.Config.User}}'), want 65532"
[ "$(inspect '{{json .Config.Entrypoint}}')" = null ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"
[ "$(inspect '{{json .Config.Cmd}}')" = "[\"$agent\",\"run\"]" ] ||
  fail "unexpected cmd: $(inspect '{{json .Config.Cmd}}')"
inspect '{{json .Config.Env}}' | grep -F '"DOCKER_DD_AGENT=true"' >/dev/null ||
  fail 'DOCKER_DD_AGENT=true is not set'
if inspect '{{json .Config.Env}}' | grep -F '"DD_API_KEY=' >/dev/null; then
  fail 'the image environment sets DD_API_KEY'
fi

# Version stamp from the recipe: release, short commit, agent-payload version.
version=$(docker run --rm --network none "$image" agent version) ||
  fail 'agent version exited non-zero'
printf '%s\n' "$version" |
  grep -E "^Agent ${expected_version} - Commit: ${short_commit} - Serialization version: v5\.[0-9]+\.[0-9]+ - Go version: go1\." >/dev/null ||
  fail "unexpected version: $version"
printf 'VERSION %s\n' "$version"

# Negative case: JMXFetch is not built in, so the jmx command does not exist.
set +e
jmx=$(docker run --rm --network none "$image" agent jmx list everything 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail 'agent jmx succeeded without JMXFetch'
printf '%s\n' "$jmx" | grep -F 'unknown command "jmx"' >/dev/null ||
  fail "agent jmx did not report an unknown command (exit $status): $jmx"
printf 'agent jmx exits %s: unknown command\n' "$status"

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")

# Pull the pinned helper index by its per-platform child digest. A classic
# Docker image store cannot bind an index digest to a second platform's image,
# so the index bytes are verified against the pin before a child is chosen,
# which keeps the pin authoritative.
python_raw=$(docker buildx imagetools inspect --raw "$python_index") ||
  fail 'cannot inspect helper image index'
[ "sha256:$(printf '%s' "$python_raw" | sha256sum | cut -d' ' -f1)" = "${python_index#*@}" ] ||
  fail 'helper image index digest mismatch'
python_digest=$(printf '%s' "$python_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve helper image digest'
case $python_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch helper image in $python_index" ;;
esac
python=${python_index%%:*}@$python_digest
docker pull --quiet --platform "linux/$image_arch" "$python" >/dev/null ||
  fail 'cannot pull helper image'

# An integrations-core (Python) check config next to the built-in Go checks.
# Without the Python runtime the core loader must reject it.
mkdir -p "$work/http_check.d"
cat >"$work/http_check.d/conf.yaml" <<'YAML'
init_config:
instances:
  - name: verity-smoke
    url: http://127.0.0.1:5555/live
YAML

# Positive case: an isolated agent with a placeholder key runs its Go core
# checks, serves the health probe and the IPC API, and receives DogStatsD.
docker create --name "$server" --network none \
  -e DD_API_KEY="$fake_api_key" \
  -e DD_HOSTNAME=verity-datadog-agent-smoke \
  -e DD_HEALTH_PORT=5555 \
  -e DD_LOG_LEVEL=info \
  -e DD_CHECK_RUNNERS=2 \
  "$image" >/dev/null || fail 'cannot create the agent container'
docker cp "$work/http_check.d" "$server:/etc/datadog-agent/conf.d/http_check.d" >/dev/null ||
  fail 'cannot copy the Python check config'
docker start "$server" >/dev/null || fail 'cannot start the agent'

result=$(docker run --rm --network "container:$server" --pid "container:$server" \
  "$python" python3 -c '
import json
import socket
import sys
import time
import urllib.error
import urllib.request

GO_CHECKS = ("cpu", "disk", "file_handle", "io", "load", "memory", "uptime")

def get(url):
    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)

def wait_for(fetch, predicate, what):
    deadline = time.monotonic() + 120
    last = None
    while time.monotonic() < deadline:
        try:
            last = fetch()
            if predicate(last):
                return last
        except (OSError, ValueError):
            pass
        time.sleep(1)
    sys.exit(f"timed out waiting for {what}: {json.dumps(last)[:3000]}")

ready = wait_for(lambda: get("http://127.0.0.1:5555/ready"), lambda r: r[0] == 200, "the ready probe")
live = get("http://127.0.0.1:5555/live")

def expvar():
    return get("http://127.0.0.1:5000/debug/vars")[1]

def checks_ran(stats):
    checks = stats.get("runner", {}).get("Checks", {})
    ran = {}
    for name, instances in checks.items():
        for instance in instances.values():
            if instance.get("TotalRuns", 0) >= 1:
                ran[name] = instance
    return all(name in ran for name in GO_CHECKS)

wait_for(expvar, lambda s: "dogstatsd-udp" in s, "the DogStatsD UDP listener")
udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for i in range(25):
    udp.sendto(f"verity.smoke.count:{i}|c|#source:udp".encode(), ("127.0.0.1", 8125))
udp.sendto(b"_e{12,5}:verity smoke|hello|#source:udp", ("127.0.0.1", 8125))
udp.sendto(b"_sc|verity.smoke.check|0|#source:udp", ("127.0.0.1", 8125))
udp.sendto(b"verity.smoke.bad:notanumber|c", ("127.0.0.1", 8125))

final = wait_for(
    expvar,
    lambda s: checks_ran(s) and s["dogstatsd"]["MetricPackets"] >= 26 and s["dogstatsd"]["MetricParseErrors"] >= 1,
    "the Go core checks to run and the DogStatsD packets to be counted",
)
checks = {}
for name, instances in final["runner"]["Checks"].items():
    for instance in instances.values():
        checks[name] = {"runs": instance.get("TotalRuns", 0), "errors": instance.get("TotalErrors", 0), "last_error": instance.get("LastError", "")}
with open("/proc/1/status") as status:
    uid = next(line.split()[1] for line in status if line.startswith("Uid:"))
with open("/proc/1/cmdline", "rb") as cmdline:
    argv = cmdline.read().rstrip(b"\0").split(b"\0")
# On the non-native arch CI runs the image under qemu-user: /proc/1/cmdline is
# [qemu, executable path, argv...] with preserve-argv0 binfmt, or
# [qemu, executable path, argv[1:]...] without it.
if argv[0].rsplit(b"/", 1)[-1].startswith(b"qemu-") and len(argv) > 1:
    argv = argv[1:]
    if len(argv) > 1 and argv[0] == argv[1]:
        argv = argv[1:]
print(json.dumps({
    "uid": uid,
    "argv": [arg.decode() for arg in argv],
    "ready": ready[1],
    "live": {"status": live[0], "body": live[1]},
    "checks": checks,
    "dogstatsd": final["dogstatsd"],
    "udp": final["dogstatsd-udp"],
}, sort_keys=True))
') || fail "agent readiness, checks or packet exchange failed: $result"
printf 'STATS %s\n' "$result"

field() {
  printf '%s\n' "$result" | docker run --rm -i --network none "$python" python3 -c '
import json, sys
value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[key]
print(json.dumps(value) if isinstance(value, (list, dict)) else value)
' "$1"
}

[ "$(field uid)" = 65532 ] || fail "agent runs as UID $(field uid), want 65532"
[ "$(field argv)" = "[\"$agent\", \"run\"]" ] ||
  fail "unexpected process argv: $(field argv)"
[ "$(field live.status)" = 200 ] || fail "live probe returned $(field live.status)"
[ "$(field ready.Unhealthy)" = '[]' ] || fail "unhealthy components: $(field ready.Unhealthy)"
for check in cpu disk file_handle io load memory uptime; do
  [ "$(field "checks.$check.errors")" = 0 ] ||
    fail "core check $check failed: $(field "checks.$check.last_error")"
done
[ "$(field dogstatsd.MetricPackets)" = 26 ] ||
  fail "DogStatsD counted $(field dogstatsd.MetricPackets) metric packets, want 26"
[ "$(field dogstatsd.MetricParseErrors)" = 1 ] ||
  fail "DogStatsD counted $(field dogstatsd.MetricParseErrors) parse errors, want 1"
[ "$(field dogstatsd.EventPackets)" = 1 ] ||
  fail "DogStatsD counted $(field dogstatsd.EventPackets) events, want 1"
[ "$(field dogstatsd.ServiceCheckPackets)" = 1 ] ||
  fail "DogStatsD counted $(field dogstatsd.ServiceCheckPackets) service checks, want 1"
[ "$(field udp.PacketReadingErrors)" = 0 ] || fail 'UDP listener reported read errors'

# The CLI reaches the running agent over its authenticated IPC API.
health=$(docker exec "$server" agent health 2>&1) || fail "agent health failed: $health"
printf '%s\n' "$health" | grep -F 'Agent health: PASS' >/dev/null ||
  fail "unexpected agent health output: $health"
printf 'HEALTH %s\n' "$(printf '%s\n' "$health" | head -n 1)"

status_json=$(docker exec "$server" agent status --json 2>&1) ||
  fail "agent status failed: $status_json"
status_fields=$(printf '%s\n' "$status_json" | docker run --rm -i --network none "$python" python3 -c '
import json, sys
status = json.load(sys.stdin)
errors = status.get("runnerStats", {}).get("Checks", {})
loader = status.get("checkSchedulerStats", {}).get("LoaderErrors", {})
print(json.dumps({
    "version": status.get("version"),
    "hostname": status.get("hostnameStats", {}).get("hostname"),
    "python": status.get("python_version"),
    "loader_errors": loader,
}, sort_keys=True))
') || fail "cannot parse agent status: $status_json"
printf 'STATUS %s\n' "$status_fields"
status_value() {
  printf '%s\n' "$status_fields" | docker run --rm -i --network none "$python" python3 -c '
import json, sys
value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[key]
print(json.dumps(value) if isinstance(value, (list, dict)) else value)
' "$1"
}
[ "$(status_value version)" = "$expected_version" ] ||
  fail "agent status reports version $(status_value version)"
[ "$(status_value hostname)" = verity-datadog-agent-smoke ] ||
  fail "agent status reports hostname $(status_value hostname)"
# Negative case: the Python check config is reported as a loading error.
status_value loader_errors.http_check | grep -F 'not found in Catalog' >/dev/null ||
  fail "http_check did not fail to load: $(status_value loader_errors)"

configcheck=$(docker exec "$server" agent configcheck 2>&1) ||
  fail "agent configcheck failed: $configcheck"
for check in cpu memory uptime http_check; do
  printf '%s\n' "$configcheck" | grep -E "=== ${check} check ===" >/dev/null ||
    fail "agent configcheck does not list $check"
done

# Graceful stop on SIGTERM.
docker stop -t 30 "$server" >/dev/null || fail 'docker stop failed'
[ "$(docker inspect "$server" --format '{{.State.ExitCode}}')" = 0 ] ||
  fail "agent exited $(docker inspect "$server" --format '{{.State.ExitCode}}') on SIGTERM"

printf 'datadog-agent smoke test passed\n'

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$recipe")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
source_commit=$(sed -n 's/^[[:space:]]*source-commit: \([0-9a-f]\{40\}\)$/\1/p' "$recipe")
[ -n "$source_commit" ] || { printf 'source commit not found\n' >&2; exit 1; }
short_commit=$(printf '%s' "$source_commit" | cut -c1-7)
# Packet sender and expvar reader. It joins the server's network and PID
# namespaces, so neither container has any route off the host.
python_index='docker.io/library/python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e'
# Placeholder key: dogstatsd only needs one to be configured. Nothing here can
# reach Datadog, because every container runs with --network none.
fake_api_key=00000000000000000000000000000000
suffix=$$
server="verity-dogstatsd-$suffix"
socket_volume="verity-dogstatsd-socket-$suffix"

cleanup() {
  docker rm -f "$server" >/dev/null 2>&1 || true
  docker volume rm "$socket_volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if docker inspect "$server" >/dev/null 2>&1; then
    docker logs --tail 50 "$server" >&2 || true
  fi
  exit 1
}

inspect() {
  docker image inspect "$image" --format "$1"
}

# OCI contract: the upstream command, without its root shell entrypoint.
[ "$(inspect '{{.Config.User}}')" = 65532 ] ||
  fail "image user is $(inspect '{{.Config.User}}'), want 65532"
[ "$(inspect '{{json .Config.Entrypoint}}')" = null ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"
[ "$(inspect '{{json .Config.Cmd}}')" = '["/dogstatsd","-c","/etc/datadog-agent/","start"]' ] ||
  fail "unexpected cmd: $(inspect '{{json .Config.Cmd}}')"
inspect '{{json .Config.Env}}' | grep -F '"DD_DOGSTATSD_NON_LOCAL_TRAFFIC=true"' >/dev/null ||
  fail 'DD_DOGSTATSD_NON_LOCAL_TRAFFIC=true is not set'

# Version stamp from the recipe: release, short commit, agent-payload version.
version=$(docker run --rm --network none "$image" /dogstatsd version) ||
  fail 'dogstatsd version exited non-zero'
printf '%s\n' "$version" |
  grep -E "^DogStatsD ${expected_version} - Commit: ${short_commit} - Serialization version: v5\.[0-9]+\.[0-9]+ - Go version: go1\." >/dev/null ||
  fail "unexpected version: $version"
printf 'VERSION %s\n' "$version"

# Negative case: without an API key dogstatsd refuses to start.
set +e
missing_key=$(docker run --rm --network none -e DD_LOG_LEVEL=info "$image" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail 'dogstatsd started without an API key'
printf '%s\n' "$missing_key" | grep -F 'Error: no API key configured, exiting' >/dev/null ||
  fail "missing API key did not report the documented error (exit $status)"
printf 'missing API key exits %s\n' "$status"

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

# Positive case: an isolated server receives StatsD traffic over UDP and UDS.
docker volume create "$socket_volume" >/dev/null || fail 'cannot create socket volume'
docker run -d --name "$server" --network none \
  -e DD_API_KEY="$fake_api_key" \
  -e DD_HOSTNAME=verity-dogstatsd-smoke \
  -e DD_DOGSTATSD_SOCKET=/var/run/datadog/dsd.socket \
  -e DD_LOG_LEVEL=info \
  -v "$socket_volume:/var/run/datadog" \
  "$image" >/dev/null || fail 'cannot start dogstatsd'

result=$(docker run --rm --network "container:$server" --pid "container:$server" \
  -v "$socket_volume:/var/run/datadog" "$python" python3 -c '
import json
import os
import socket
import sys
import time
import urllib.request

def stats():
    with urllib.request.urlopen("http://127.0.0.1:5000/debug/vars", timeout=2) as response:
        return json.load(response)

def wait_for(predicate, what):
    deadline = time.monotonic() + 90
    last = None
    while time.monotonic() < deadline:
        try:
            last = stats()
            if predicate(last):
                return last
        except OSError:
            pass
        time.sleep(1)
    sys.exit(f"timed out waiting for {what}: {json.dumps(last)[:2000]}")

wait_for(lambda s: "dogstatsd-udp" in s and "dogstatsd-uds" in s, "the UDP and UDS listeners")
for _ in range(60):
    if os.path.exists("/var/run/datadog/dsd.socket"):
        break
    time.sleep(1)
else:
    sys.exit("UDS socket /var/run/datadog/dsd.socket was not created")

udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for i in range(25):
    udp.sendto(f"verity.smoke.count:{i}|c|#source:udp".encode(), ("127.0.0.1", 8125))
udp.sendto(b"_e{12,5}:verity smoke|hello|#source:udp", ("127.0.0.1", 8125))
udp.sendto(b"_sc|verity.smoke.check|0|#source:udp", ("127.0.0.1", 8125))
udp.sendto(b"verity.smoke.bad:notanumber|c", ("127.0.0.1", 8125))
uds = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
for i in range(3):
    uds.sendto(f"verity.smoke.gauge:{i}|g|#source:uds".encode(), "/var/run/datadog/dsd.socket")

final = wait_for(
    lambda s: s["dogstatsd"]["MetricPackets"] >= 28 and s["dogstatsd"]["MetricParseErrors"] >= 1,
    "the sent packets to be counted",
)
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
    "dogstatsd": final["dogstatsd"],
    "udp": final["dogstatsd-udp"],
    "uds": final["dogstatsd-uds"],
}, sort_keys=True))
') || fail "packet exchange failed: $result"
printf 'STATS %s\n' "$result"

field() {
  printf '%s\n' "$result" | docker run --rm -i --network none "$python" python3 -c '
import json, sys
value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[key]
print(json.dumps(value) if isinstance(value, list) else value)
' "$1"
}

[ "$(field uid)" = 65532 ] || fail "dogstatsd runs as UID $(field uid), want 65532"
[ "$(field argv)" = '["/dogstatsd", "-c", "/etc/datadog-agent/", "start"]' ] ||
  fail "unexpected process argv: $(field argv)"
[ "$(field dogstatsd.MetricPackets)" = 28 ] ||
  fail "dogstatsd counted $(field dogstatsd.MetricPackets) metric packets, want 28"
[ "$(field dogstatsd.MetricParseErrors)" = 1 ] ||
  fail "dogstatsd counted $(field dogstatsd.MetricParseErrors) parse errors, want 1"
[ "$(field dogstatsd.EventPackets)" = 1 ] ||
  fail "dogstatsd counted $(field dogstatsd.EventPackets) events, want 1"
[ "$(field dogstatsd.ServiceCheckPackets)" = 1 ] ||
  fail "dogstatsd counted $(field dogstatsd.ServiceCheckPackets) service checks, want 1"
[ "$(field udp.Packets)" = 28 ] ||
  fail "UDP listener read $(field udp.Packets) packets, want 28"
[ "$(field udp.PacketReadingErrors)" = 0 ] || fail 'UDP listener reported read errors'
[ "$(field uds.Bytes)" -gt 0 ] || fail 'UDS listener read no bytes'
[ "$(field uds.PacketReadingErrors)" = 0 ] || fail 'UDS listener reported read errors'

# Graceful stop on SIGTERM.
docker stop -t 30 "$server" >/dev/null || fail 'docker stop failed'
[ "$(docker inspect "$server" --format '{{.State.ExitCode}}')" = 0 ] ||
  fail "dogstatsd exited $(docker inspect "$server" --format '{{.State.ExitCode}}') on SIGTERM"

printf 'dogstatsd smoke test passed\n'

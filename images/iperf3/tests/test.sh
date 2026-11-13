#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - iperf3=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
server="verity-iperf3-server-$$"
work=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$server" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned iperf3 version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/iperf3"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["-s"]' ||
  fail 'unexpected command'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Ex "iperf $version( .*)?" "$work/version" >/dev/null ||
  fail "version does not report iperf $version"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unrecognized option' "$work/invalid" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

rc=0
docker run --rm --network none "$image" -c 127.0.0.1 -t 1 >"$work/refused" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'client without a server unexpectedly succeeded'
grep -F 'Connection refused' "$work/refused" >/dev/null ||
  fail 'connection refused diagnostic is missing'

# Default command: the server, on a read-only root with no capabilities.
docker run -d --name "$server" --read-only --tmpfs /tmp:rw,mode=1777 \
  --cap-drop=ALL "$image" >/dev/null
client() {
  docker run --rm --network "container:$server" --read-only \
    --tmpfs /tmp:rw,mode=1777 --cap-drop=ALL "$image" "$@"
}

# The server block-buffers its log when stdout is not a terminal, so readiness
# is a successful one-second client run rather than a log line.
ready=false
i=0
while [ "$i" -lt 30 ]; do
  if client -c 127.0.0.1 -t 1 >"$work/probe" 2>&1; then
    ready=true
    break
  fi
  i=$((i + 1))
  sleep 1
done
"$ready" || {
  cat "$work/probe" >&2
  docker logs "$server" >&2 || true
  fail 'server did not accept a client on 5201'
}
grep -F 'iperf Done.' "$work/probe" >/dev/null || fail 'probe client did not finish'

# Upload, then reverse mode (server sends), each for 2 seconds with JSON output.
client -c 127.0.0.1 -t 2 -J >"$work/upload.json" 2>&1 ||
  fail "upload test failed: $(cat "$work/upload.json")"
client -c 127.0.0.1 -t 2 -R -J >"$work/reverse.json" 2>&1 ||
  fail "reverse test failed: $(cat "$work/reverse.json")"

for mode in upload reverse; do
  python3 - "$work/$mode.json" "$version" "$mode" <<'PY' || fail "$mode result is not a valid iperf3 measurement"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
assert "error" not in result, result.get("error")
assert result["start"]["version"].startswith("iperf " + sys.argv[2]), result["start"]["version"]
assert result["start"]["test_start"]["protocol"] == "TCP"
assert result["start"]["test_start"]["reverse"] == (1 if sys.argv[3] == "reverse" else 0)
for key in ("sum_sent", "sum_received"):
    summary = result["end"][key]
    assert summary["bytes"] > 0, (key, summary)
    assert summary["bits_per_second"] > 0, (key, summary)
assert result["end"]["sum_received"]["seconds"] >= 1.5, result["end"]["sum_received"]
PY
done

# UDP at a fixed rate exercises the second protocol path.
client -c 127.0.0.1 -u -b 10M -t 2 -J >"$work/udp.json" 2>&1 ||
  fail "udp test failed: $(cat "$work/udp.json")"
python3 - "$work/udp.json" <<'PY' || fail 'udp result is not a valid iperf3 measurement'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
assert "error" not in result, result.get("error")
assert result["start"]["test_start"]["protocol"] == "UDP"
summary = result["end"]["sum"]
assert summary["bits_per_second"] > 0, summary
assert summary["packets"] > 0, summary
PY

# The server keeps serving after the clients and stops cleanly on SIGTERM.
docker inspect --format '{{.State.Running}}' "$server" | grep -Fx true >/dev/null ||
  fail 'server exited after serving clients'
docker stop -t 10 "$server" >/dev/null
code=$(docker inspect --format '{{.State.ExitCode}}' "$server")
case "$code" in
  0 | 143) ;;
  *) fail "server exit code $code after SIGTERM" ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"

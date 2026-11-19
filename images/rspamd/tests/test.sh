#!/bin/sh
set -eu

# Rspamd runs with --network none and no Redis; messages are submitted with the
# bundled rspamc client inside the same container.
image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^  version: "\([0-9][0-9.]*\)".*/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'rspamd melange version not found' >&2; exit 1; }
label="verity-test-rspamd-$$"
container=

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ -z "$container" ] || docker logs "$container" 2>&1 | tail -n 40 >&2 || true
  exit 1
}

inspect() {
  docker image inspect -f "$1" "$image"
}

[ "$(inspect '{{.Config.User}}')" = 11333 ] || fail "image user is $(inspect '{{.Config.User}}'), want 11333"
[ "$(inspect '{{json .Config.Entrypoint}} {{json .Config.Cmd}}')" = 'null ["/usr/bin/rspamd","-f"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}} {{json .Config.Cmd}}')"
[ "$(inspect '{{.Config.WorkingDir}}')" = /var/lib/rspamd ] || fail 'unexpected working directory'
[ "$(inspect '{{json .Config.Volumes}}')" = '{"/var/lib/rspamd":{}}' ] ||
  fail "unexpected volumes: $(inspect '{{json .Config.Volumes}}')"
env=$(inspect '{{range .Config.Env}}{{println .}}{{end}}')
printf '%s\n' "$env" | grep -Fx 'RSPAMD_LOCAL_ADDR=*' >/dev/null || fail 'RSPAMD_LOCAL_ADDR is not *'
printf '%s\n' "$env" | grep -Fx 'RSPAMD_LOG_TYPE=console' >/dev/null || fail 'RSPAMD_LOG_TYPE is not console'

version=$(docker run --rm --network none "$image" rspamd --version 2>&1) || fail "rspamd --version failed: $version"
printf '%s\n' "$version" | grep -F "$expected_version" >/dev/null || fail "unexpected version: $version"
out=$(docker run --rm --network none "$image" rspamadm configtest 2>&1) ||
  { printf '%s\n' "$out" >&2; fail 'shipped configuration failed configtest'; }
printf '%s\n' "$out" | grep -F 'syntax OK' >/dev/null || { printf '%s\n' "$out" >&2; fail 'configtest did not report syntax OK'; }

container=$(docker run -d --label "$label" --network none "$image")
attempts=0
until docker exec "$container" rspamc -h 127.0.0.1:11334 stat >/dev/null 2>&1; do
  [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] || fail 'rspamd exited during startup'
  attempts=$((attempts + 1))
  [ "$attempts" -lt 90 ] || fail 'controller did not become ready'
  sleep 1
done
logs=$(docker logs "$container" 2>&1)
for worker in normal controller rspamd_proxy; do
  printf '%s\n' "$logs" | grep -E "starting $worker process|$worker process" >/dev/null ||
    fail "$worker worker did not start"
done

message() {
  printf 'From: sender@example.test\r\nTo: rcpt@example.test\r\nSubject: %s\r\nMessage-ID: <%s@example.test>\r\nDate: Thu, 19 Nov 2026 12:00:00 +0000\r\n\r\n%s\r\n' "$1" "$2" "$3"
}

gtube='XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X'
spam=$(message 'gtube' gtube "$gtube" | docker exec -i "$container" rspamc -h 127.0.0.1:11333 symbols 2>&1) ||
  { printf '%s\n' "$spam" >&2; fail 'rspamc failed on the GTUBE message'; }
printf '%s\n' "$spam" | grep -F 'GTUBE' >/dev/null || { printf '%s\n' "$spam" >&2; fail 'GTUBE symbol not reported'; }
printf '%s\n' "$spam" | grep -E '^Action: reject' >/dev/null || { printf '%s\n' "$spam" >&2; fail 'GTUBE message was not rejected'; }

ham=$(message 'meeting notes' ham 'The notes from today are attached inline.' |
  docker exec -i "$container" rspamc -h 127.0.0.1:11333 symbols 2>&1) ||
  { printf '%s\n' "$ham" >&2; fail 'rspamc failed on the plain message'; }
printf '%s\n' "$ham" | grep -F 'GTUBE' >/dev/null && { printf '%s\n' "$ham" >&2; fail 'plain message matched GTUBE'; }
printf '%s\n' "$ham" | grep -E '^Action: reject' >/dev/null && { printf '%s\n' "$ham" >&2; fail 'plain message was rejected'; }

# Workers listen on all interfaces as in the upstream image.
for port in 11332 11333 11334; do
  printf '%s\n' "$logs" | grep -F "listen on: *:$port" >/dev/null || fail "worker on $port is not bound to all interfaces"
done

# Because the workers are reachable from the network, the File/Path/Shm
# message-source inputs that make rspamd read a client-named local file are
# disabled on every worker.
probe=$(docker run -d --label "$label" -p 127.0.0.1::11333 -p 127.0.0.1::11334 "$image")
probe_port=$(docker port "$probe" 11333/tcp | sed -n 's/^127\.0\.0\.1:\([0-9]*\)$/\1/p' | head -n1)
ui_port=$(docker port "$probe" 11334/tcp | sed -n 's/^127\.0\.0\.1:\([0-9]*\)$/\1/p' | head -n1)
[ -n "$probe_port" ] && [ -n "$ui_port" ] || { docker rm -f "$probe" >/dev/null; fail 'cannot resolve the published scan port'; }
file_probe=$(python3 - "$probe_port" "$ui_port" <<'PY'
import sys, time, urllib.error, urllib.request

url = f"http://127.0.0.1:{sys.argv[1]}/checkv2"
for _ in range(60):
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/ping", timeout=2).read()
        break
    except OSError:
        time.sleep(1)
# A worker that honors File opens the named path; a missing path then fails
# with "Cannot open file". A hardened worker never touches the filesystem.
request = urllib.request.Request(url, data=b"Subject: probe\r\n\r\nbody\r\n",
                                 headers={"File": "/nonexistent/verity-probe"}, method="POST")
try:
    body = urllib.request.urlopen(request, timeout=10).read().decode()
except urllib.error.HTTPError as error:
    body = f"{error.code} {error.read().decode()}"
ui = urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[2]}/", timeout=10).read().decode()
if "Rspamd Web Interface" not in ui:
    print("NOUI " + ui[:200])
    sys.exit(0)
print(("OPENED " if "Cannot open file" in body else "IGNORED ") + body[:200])
PY
) || true
docker rm -f "$probe" >/dev/null
case $file_probe in
  IGNORED*) ;;
  NOUI*) printf '%s\n' "$file_probe" >&2; fail 'controller does not serve the web interface' ;;
  *) printf '%s\n' "$file_probe" >&2; fail 'scan worker read a client-named local file over TCP' ;;
esac
printf '%s\n' "$logs" | grep -F 'accepts privileged File/Path/Shm' >/dev/null &&
  fail 'rspamd warns that a worker accepts File/Path/Shm inputs'

docker stop -t 20 "$container" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$container")
[ "$code" = 0 ] || fail "SIGTERM shutdown exited $code"

printf 'SMOKE PASS image=%s\n' "$image"

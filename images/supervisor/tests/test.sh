#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(dirname "$0")
container="verity-supervisor-test-$$"
rpc_container="verity-supervisor-rpc-$$"
fixture=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" "$rpc_container" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

ctl() {
  docker exec "$container" /usr/bin/supervisorctl "$@"
}

# Print the supervisorctl state word (RUNNING, STOPPED, ...) of one program.
state_of() {
  ctl status "$1" 2>/dev/null | awk -v name="$1" '$1 == name {print $2}'
}

wait_state() {
  i=0
  until [ "$(state_of "$1")" = "$2" ]; do
    [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || {
      docker logs "$container" >&2
      fail "supervisord exited before $1 reached $2"
    }
    i=$((i + 1))
    [ "$i" -lt 30 ] || {
      ctl status >&2 || true
      docker logs "$container" >&2
      fail "$1 did not reach $2"
    }
    sleep 1
  done
}

# Fetch a URL from inside the container network with the image's own Python.
http_get() {
  docker exec "$container" /usr/bin/python3 -c \
    'import sys, urllib.request; sys.stdout.write(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode())' "$1"
}

expected_version=$(sed -n 's/^ *- supervisor=\([0-9][0-9.]*\)-r[0-9]*$/\1/p' "$here/../apko.yaml")
[ -n "$expected_version" ] || fail 'could not derive supervisor version from apko.yaml'

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'image user is not 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/supervisord"]' ] || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["--nodaemon","--configuration","/etc/supervisord.conf"]' ] || fail 'unexpected image command'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ] || fail 'unexpected working directory'

version=$(docker run --rm --cpus 4 "$image" --version)
[ "$version" = "$expected_version" ] || fail "supervisord version $version, expected $expected_version"
# supervisorctl version asks the server; without one it must fail rather than invent a version.
if docker run --rm --cpus 4 --entrypoint /usr/bin/supervisorctl "$image" version > "$fixture/no-server.log" 2>&1; then
  fail 'supervisorctl version succeeded without a running supervisord'
fi
grep -F 'unix:///tmp/supervisor.sock no such file' "$fixture/no-server.log" >/dev/null || fail 'missing server diagnostic not found'

# The packaged default configuration boots with no programs and serves supervisorctl on its socket.
docker run --name "$container" --cpus 4 --cap-drop=ALL --read-only --tmpfs /tmp -d "$image" >/dev/null
i=0
until [ "$(ctl version 2>/dev/null)" = "$expected_version" ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || {
    docker logs "$container" >&2
    fail 'supervisorctl could not reach supervisord with the default configuration'
  }
  sleep 1
done
[ "$(ctl pid)" = 1 ] || fail 'supervisord is not PID 1 with the default configuration'
[ -z "$(ctl status)" ] || fail 'default configuration unexpectedly defines programs'
docker rm -f "$container" >/dev/null

cat > "$fixture/supervisord.conf" <<'EOF'
[unix_http_server]
file=/tmp/supervisor.sock

[supervisord]
logfile=/tmp/supervisord.log
pidfile=/tmp/supervisord.pid

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///tmp/supervisor.sock

[program:web]
command=/usr/bin/python3 -m http.server 8080 --bind 127.0.0.1 --directory /etc
startsecs=1
stopsignal=TERM

[program:ticker]
command=/usr/bin/python3 -u -c "import time; [print('verity-tick', flush=True) or time.sleep(0.2) for _ in iter(int, 1)]"
startsecs=1

[program:crasher]
command=/usr/bin/python3 -c "import sys, time; time.sleep(0.5); sys.exit(3)"
startsecs=0
autorestart=unexpected
exitcodes=0
startretries=100

[program:manual]
command=/usr/bin/python3 -c "import time; time.sleep(3600)"
autostart=false
startsecs=1
EOF
chmod 644 "$fixture/supervisord.conf"

# A caller configuration mounted over the default path is used by supervisord and supervisorctl.
docker run --name "$container" --cpus 4 --cap-drop=ALL --read-only --tmpfs /tmp -d \
  -v "$fixture/supervisord.conf:/etc/supervisord.conf:ro" "$image" >/dev/null

wait_state web RUNNING
wait_state ticker RUNNING
[ "$(state_of manual)" = STOPPED ] || fail "autostart=false program is not STOPPED: $(state_of manual)"

[ "$(ctl pid)" = 1 ] || fail 'supervisord is not PID 1'
[ "$(ctl version)" = "$expected_version" ] || fail 'supervisorctl version does not match supervisord'
[ "$(docker exec "$container" /usr/bin/python3 -c 'import os; print(os.getuid())')" = 65532 ] || fail 'container does not run as 65532'

page=$(http_get http://127.0.0.1:8080/supervisord.conf)
printf '%s\n' "$page" | grep -F '[program:web]' >/dev/null || fail 'supervised web server did not serve the program config'

ctl tail ticker | grep -F verity-tick >/dev/null || fail 'supervisorctl tail did not return ticker stdout'

ctl start manual >/dev/null || fail 'supervisorctl start manual failed'
wait_state manual RUNNING
manual_pid=$(ctl pid manual)
[ "$manual_pid" -gt 1 ] || fail "unexpected manual pid: $manual_pid"
ctl restart manual >/dev/null || fail 'supervisorctl restart manual failed'
wait_state manual RUNNING
[ "$(ctl pid manual)" != "$manual_pid" ] || fail 'restart did not replace the manual process'
ctl stop manual >/dev/null || fail 'supervisorctl stop manual failed'
[ "$(state_of manual)" = STOPPED ] || fail 'manual is not STOPPED after stop'

ctl stop web >/dev/null || fail 'supervisorctl stop web failed'
if http_get http://127.0.0.1:8080/supervisord.conf >/dev/null 2>&1; then
  fail 'web still answers after supervisorctl stop'
fi
ctl start web >/dev/null || fail 'supervisorctl start web failed'
wait_state web RUNNING
http_get http://127.0.0.1:8080/supervisord.conf | grep -F '[program:ticker]' >/dev/null || fail 'web did not serve after restart'

# The crasher exits with an unexpected code every 0.5s; supervisord must keep respawning it.
i=0
until [ "$(docker logs "$container" 2>&1 | grep -Fc 'exited: crasher (exit status 3; not expected)')" -ge 3 ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || {
    docker logs "$container" >&2
    fail 'crasher was not restarted after unexpected exits'
  }
  sleep 1
done

if ctl start missing > "$fixture/missing-program.log" 2>&1; then
  fail 'starting an unknown program unexpectedly succeeded'
fi
grep -F 'no such process' "$fixture/missing-program.log" >/dev/null || fail 'unknown program diagnostic not found'

docker stop --time 20 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] || fail 'supervisord did not exit cleanly on SIGTERM'
docker logs "$container" > "$fixture/stop.log" 2>&1
grep -F 'received SIGTERM indicating exit request' "$fixture/stop.log" >/dev/null || fail 'SIGTERM was not handled by supervisord'
grep -F 'stopped: web (terminated by SIGTERM)' "$fixture/stop.log" >/dev/null || fail 'web was not stopped on shutdown'

# XML-RPC over an authenticated TCP listener with a caller-supplied configuration.
mkdir "$fixture/rpc"
cat > "$fixture/rpc/supervisord.conf" <<'EOF'
[inet_http_server]
port=127.0.0.1:9001
username=verity
password=smoke-test-only

[supervisord]
nodaemon=true
logfile=/dev/null
logfile_maxbytes=0
pidfile=/tmp/supervisord.pid

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=http://127.0.0.1:9001
username=verity
password=smoke-test-only

[program:sleeper]
command=/usr/bin/python3 -c "import time; time.sleep(3600)"
startsecs=1
EOF
chmod 755 "$fixture/rpc"
chmod 644 "$fixture/rpc/supervisord.conf"
docker run --name "$rpc_container" --cpus 4 --cap-drop=ALL --read-only --tmpfs /tmp -d \
  -v "$fixture/rpc:/config:ro" "$image" --configuration /config/supervisord.conf >/dev/null

i=0
until docker exec "$rpc_container" /usr/bin/supervisorctl -c /config/supervisord.conf status sleeper 2>/dev/null | grep -F RUNNING >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || {
    docker logs "$rpc_container" >&2
    fail 'sleeper did not start under the TCP listener configuration'
  }
  sleep 1
done

state=$(docker exec "$rpc_container" /usr/bin/python3 -c '
import xmlrpc.client
proxy = xmlrpc.client.ServerProxy("http://verity:smoke-test-only@127.0.0.1:9001/RPC2")
print(proxy.supervisor.getState()["statename"], proxy.supervisor.getProcessInfo("sleeper")["statename"])
')
[ "$state" = 'RUNNING RUNNING' ] || fail "unexpected XML-RPC state: $state"

status=$(docker exec "$rpc_container" /usr/bin/python3 -c '
import xmlrpc.client
proxy = xmlrpc.client.ServerProxy("http://verity:wrong@127.0.0.1:9001/RPC2")
try:
    proxy.supervisor.getState()
except xmlrpc.client.ProtocolError as err:
    print(err.errcode)
else:
    print("accepted")
')
[ "$status" = 401 ] || fail "XML-RPC accepted wrong credentials: $status"

if docker exec "$rpc_container" /usr/bin/supervisorctl -s http://127.0.0.1:9001 -u verity -p wrong status > "$fixture/bad-auth.log" 2>&1; then
  fail 'supervisorctl with wrong credentials unexpectedly succeeded'
fi
grep -F 'Server requires authentication' "$fixture/bad-auth.log" >/dev/null || fail 'bad credential diagnostic not found'
docker rm -f "$rpc_container" >/dev/null

if docker run --rm --cpus 4 "$image" --configuration /etc/missing.conf > "$fixture/missing.log" 2>&1; then
  fail 'missing config unexpectedly succeeded'
fi
grep -F 'could not find config file /etc/missing.conf' "$fixture/missing.log" >/dev/null || fail 'missing config diagnostic not found'

cat > "$fixture/invalid.conf" <<'EOF'
[supervisord]
nodaemon=true

[program:broken]
autostart=true
EOF
chmod 644 "$fixture/invalid.conf"
if docker run --rm --cpus 4 -v "$fixture/invalid.conf:/etc/supervisord.conf:ro" "$image" > "$fixture/invalid.log" 2>&1; then
  fail 'program without a command unexpectedly started'
fi
grep -F 'program section program:broken does not specify a command' "$fixture/invalid.log" >/dev/null || fail 'invalid program diagnostic not found'

printf 'SMOKE PASS image=%s\n' "$image"

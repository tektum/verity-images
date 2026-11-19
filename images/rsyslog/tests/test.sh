#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
container="rsyslog-smoke-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

inspect() {
  docker image inspect --format "$1" "$image"
}

# OCI contract.
test "$(inspect '{{.Config.User}}')" = 65532 || fail 'unexpected OCI user'
test "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/rsyslogd","-n","-i","/run/rsyslogd/rsyslogd.pid"]' ||
  fail 'unexpected entrypoint'
test "$(inspect '{{json .Config.Cmd}}')" = '["-f","/etc/rsyslog.conf"]' || fail 'unexpected cmd'
test "$(inspect '{{.Config.WorkingDir}}')" = /var/lib/rsyslog || fail 'unexpected working directory'
env_json=$(inspect '{{json .Config.Env}}')
for entry in ENABLE_STATISTICS=off CNF_CALL_LOG_TO_LOGFILES= CNF_CALL_LOG_TO_LOGSENE= TZ=UTC; do
  case "$env_json" in
    *"\"$entry\""*) ;;
    *) fail "missing default environment $entry" ;;
  esac
done

# Version.
docker run --rm --network none "$image" -v >"$work/version" 2>&1 || fail 'rsyslogd -v failed'
grep -E '^rsyslogd +8\.2604\.[0-9]+ ' "$work/version" >/dev/null || fail 'unexpected rsyslogd version'
grep -E 'Config file:[[:space:]]+/etc/rsyslog\.conf$' "$work/version" >/dev/null || fail 'unexpected default config path'

# The shipped config, with its module loads and CNF_* includes, validates as nonroot.
docker run --rm --network none "$image" -N1 >"$work/n1.log" 2>&1 || {
  cat "$work/n1.log" >&2
  fail 'shipped config failed rsyslogd -N1'
}
grep -F 'End of config validation run' "$work/n1.log" >/dev/null || fail '-N1 did not finish the validation run'
if grep -E 'error|could not load module' "$work/n1.log" >/dev/null; then
  cat "$work/n1.log" >&2
  fail 'shipped config validation reported an error'
fi

# Negative: a config that loads an absent module must fail -N1.
printf 'module(load="imnosuchmodule")\n' >"$work/broken.conf"
chmod 0644 "$work/broken.conf"
if docker run --rm --network none -v "$work/broken.conf:/etc/rsyslog.conf:ro" "$image" -N1 \
  >"$work/broken.log" 2>&1; then
  fail 'broken config unexpectedly passed -N1'
fi
grep -F 'imnosuchmodule' "$work/broken.log" >/dev/null || fail 'broken config error did not name the module'

# Run the shipped config as uid 65532 with no capabilities.
docker run -d --name "$container" --cap-drop ALL --security-opt no-new-privileges \
  -p 127.0.0.1::514/tcp -p 127.0.0.1::514/udp -p 127.0.0.1::1601/tcp "$image" >/dev/null ||
  fail 'container did not start'

attempt=0
until docker logs "$container" 2>&1 | grep -F 'swVersion="8.2604' | grep -F '] start' >/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'rsyslogd did not log its start message'
  [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || fail 'rsyslogd exited'
  sleep 1
done
sleep 1
if docker logs "$container" 2>&1 | grep -E -i 'error|cannot|could not|permission denied' >/dev/null; then
  fail 'rsyslogd reported an error at startup'
fi

docker cp "$container:/run/rsyslogd/rsyslogd.pid" - | tar -xO >"$work/pid" || fail 'pid file was not written'
test "$(cat "$work/pid")" = 1 || fail 'pid file does not hold the rsyslogd pid'

host_port() {
  docker port "$container" "$1" | sed -n '1s/.*://p'
}
tcp_port=$(host_port 514/tcp)
udp_port=$(host_port 514/udp)
relp_port=$(host_port 1601/tcp)

cat >"$work/send.py" <<'EOF'
import socket
import sys

proto, port, message = sys.argv[1], int(sys.argv[2]), sys.argv[3]
if proto == "tcp":
    with socket.create_connection(("127.0.0.1", port), timeout=10) as s:
        s.sendall(message.encode())
elif proto == "udp":
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        for line in message.splitlines():
            s.sendto(line.encode(), ("127.0.0.1", port))
elif proto == "relp":
    def frame(txnr, command, data):
        body = data.encode()
        head = f"{txnr} {command} {len(body)}".encode()
        return head + (b" " + body if body else b"") + b"\n"

    with socket.create_connection(("127.0.0.1", port), timeout=10) as s:
        f = s.makefile("rb")
        offer = "relp_version=0\nrelp_software=smoke\ncommands=syslog"
        s.sendall(frame(1, "open", offer))
        reply = f.readline()
        if not reply.startswith(b"1 rsp ") or b" 200 OK" not in reply:
            sys.exit(f"unexpected RELP open reply: {reply!r}")
        # The open response carries the offers after the status line.
        while True:
            line = f.readline()
            if not line or line == b"\n" or line.startswith(b"commands="):
                break
        s.sendall(frame(2, "syslog", message.rstrip("\n")))
        reply = f.readline()
        while reply and not reply.startswith(b"2 "):
            reply = f.readline()
        if not reply.startswith(b"2 rsp ") or b"200 OK" not in reply:
            sys.exit(f"unexpected RELP syslog reply: {reply!r}")
        s.sendall(frame(3, "close", ""))
else:
    sys.exit(f"unknown protocol {proto}")
EOF

seen() {
  docker logs "$container" 2>&1 | grep -F "$1" >/dev/null
}

wait_for() {
  attempt=0
  until seen "$1"; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || fail "$2"
    sleep 1
  done
}

# TCP: a user-facility message the shipped config does not route, then a
# syslog-facility (PRI 46) message on the same connection.
tcp_token="tcp-smoke-$$"
dropped_token="tcp-dropped-$$"
python3 "$work/send.py" tcp "$tcp_port" \
  "<14>Nov 19 12:00:00 smokehost smoke: $dropped_token
<46>Nov 19 12:00:00 smokehost smoke: $tcp_token
" || fail 'could not send over TCP'
wait_for "$tcp_token" 'TCP syslog message did not appear on stdout'
if seen "$dropped_token"; then
  fail 'user-facility message reached stdout despite the shipped syslog.* routing'
fi

# UDP is lossy: resend until the message is on stdout.
udp_token="udp-smoke-$$"
attempt=0
until seen "$udp_token"; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'UDP syslog message did not appear on stdout'
  python3 "$work/send.py" udp "$udp_port" "<46>Nov 19 12:00:00 smokehost smoke: $udp_token" ||
    fail 'could not send over UDP'
  sleep 1
done

# RELP on 1601 through the rsyslog-relp plugin.
relp_token="relp-smoke-$$"
python3 "$work/send.py" relp "$relp_port" "<46>Nov 19 12:00:00 smokehost smoke: $relp_token" ||
  fail 'RELP session failed'
wait_for "$relp_token" 'RELP syslog message did not appear on stdout'

docker logs "$container" 2>&1 | grep -E "smokehost smoke: $tcp_token\$" >/dev/null ||
  fail 'TCP message was not rendered with its hostname and tag'

docker stop --time 15 "$container" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 || fail 'graceful shutdown did not exit 0'
docker logs "$container" 2>&1 | grep -F 'exiting on signal 15' >/dev/null || fail 'rsyslogd did not log a SIGTERM shutdown'

printf 'SMOKE PASS image=%s\n' "$image"

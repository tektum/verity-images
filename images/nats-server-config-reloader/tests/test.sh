#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# The repository NATS image is the reloaded server; the pinned index is resolved per platform.
nats_index='ghcr.io/tektum/nats@sha256:2839bc0bad776f981009e63814639dc8b99f08f3dd658bf834891885decd7207'
label=verity.test=nats-server-config-reloader-$$
server="verity-nats-reloader-server-$$"
reloader="verity-nats-reloader-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  for container in "$server" "$reloader"; do
    printf '%s logs:\n' "$container" >&2
    docker logs "$container" >&2 2>/dev/null || true
  done
  printf '%s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/nats-server-config-reloader"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

docker run --rm --network none --read-only "$image" --version >"$work/version" 2>&1 ||
  fail 'reloader --version failed'
grep -E "^NATS Server Config Reloader v${expected_version} \([0-9a-f]{12}, [0-9]{4}-" \
  "$work/version" >/dev/null || fail "unexpected version output: $(cat "$work/version")"

docker run --rm --network none --read-only "$image" --help >"$work/help" 2>&1 ||
  fail 'reloader --help failed'
for flag in -config -pid -signal -force-poll -poll-interval -max-retries; do
  grep -F -e "  $flag" "$work/help" >/dev/null || fail "help is missing $flag"
done

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

# Without a server process the reloader must give up instead of watching forever.
if docker run --rm --network none --read-only "$image" \
  -P /tmp/definitely-missing.pid --max-retries 1 --retry-wait-secs 1 \
  >"$work/nopid" 2>&1; then
  fail 'missing server process unexpectedly succeeded'
fi
grep -F 'too many errors attempting to find server process' "$work/nopid" >/dev/null ||
  fail "missing server process diagnostic is missing: $(cat "$work/nopid")"

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
pull_child() {
  raw=$(docker buildx imagetools inspect --raw "$1") || fail "cannot inspect $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] ||
    fail "index digest mismatch for $1"
  child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail "cannot resolve a child of $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $1" ;;
  esac
  docker pull --quiet --platform "linux/$image_arch" "${1%%@*}@$child" >/dev/null ||
    fail "cannot pull ${1%%@*}@$child"
  printf '%s' "${1%%@*}@$child"
}
nats_image=$(pull_child "$nats_index")

mkdir -p "$work/config" "$work/run"
cat >"$work/config/nats.conf" <<'EOF'
pid_file: "/var/run/nats/nats.pid"
max_payload: 1048576
EOF
chmod 0755 "$work/config"
chmod 0644 "$work/config/nats.conf"
chmod 0777 "$work/run"

docker run -d --label "$label" --name "$server" --network none \
  -v "$work/config:/etc/nats-config:ro" -v "$work/run:/var/run/nats" \
  "$nats_image" -c /etc/nats-config/nats.conf >/dev/null

attempts=0
until [ -s "$work/run/nats.pid" ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'NATS server never wrote its pid file'
  sleep 1
done

# The sidecar shares the server's PID namespace, as in a Kubernetes pod with
# shareProcessNamespace, and watches the same read-only config mount.
docker run -d --label "$label" --name "$reloader" --network none --read-only \
  --pid "container:$server" \
  -v "$work/config:/etc/nats-config:ro" -v "$work/run:/var/run/nats:ro" \
  "$image" -c /etc/nats-config/nats.conf -P /var/run/nats/nats.pid \
  --retry-wait-secs 1 >/dev/null

attempts=0
until docker logs "$reloader" 2>&1 | grep -F 'Live, ready to kick pid' >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'reloader never became ready'
  sleep 1
done
docker logs "$reloader" 2>&1 | grep -F 'Watching file: /etc/nats-config/nats.conf' >/dev/null ||
  fail 'reloader is not watching the config file'
if docker logs "$server" 2>&1 | grep -F 'Reloaded server configuration' >/dev/null; then
  fail 'server reloaded before the config changed'
fi

# Rewrite the file in place so the bind-mounted inode stays the same.
sed 's/^max_payload: 1048576$/max_payload: 2097152/' "$work/config/nats.conf" >"$work/next.conf"
cat "$work/next.conf" >"$work/config/nats.conf"

attempts=0
until docker logs "$server" 2>&1 | grep -F 'Reloaded server configuration' >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'server was never signalled to reload its configuration'
  sleep 1
done
docker logs "$reloader" 2>&1 | grep -E "Sending pid [0-9]+ 'hangup' signal to reload changes from: \[/etc/nats-config/nats.conf\]" \
  >/dev/null || fail 'reloader did not report the SIGHUP it sent'
docker logs "$server" 2>&1 | grep -F 'Reloaded: max_payload = 2097152' >/dev/null ||
  fail 'server did not apply the new max_payload'

docker stop --time 10 "$reloader" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$reloader")" = 0 ||
  fail 'reloader did not exit cleanly on SIGTERM'

printf 'SMOKE PASS image=%s\n' "$image"

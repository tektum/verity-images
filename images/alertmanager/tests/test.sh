#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-alertmanager-test-$$"
config=$(mktemp)
invalid_config=$(mktemp)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -f "$config" "$invalid_config"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/alertmanager"]' ]
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in null|'[]') ;; *) exit 1;; esac
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ]

cat >"$config" <<'EOF'
route:
  receiver: sink
receivers:
  - name: sink
EOF
printf '%s\n' 'route: [' >"$invalid_config"
chmod 644 "$config" "$invalid_config"

docker run --rm -v "$config:/tmp/alertmanager.yml:ro" --entrypoint /usr/bin/amtool \
  "$image" check-config /tmp/alertmanager.yml >/dev/null
if docker run --rm -v "$invalid_config:/tmp/alertmanager.yml:ro" --entrypoint /usr/bin/amtool \
  "$image" check-config /tmp/alertmanager.yml; then
  exit 1
fi

docker run --name "$container" -d --read-only --user 65532 \
  --tmpfs /alertmanager:uid=65532,gid=65532 \
  -v "$config:/tmp/alertmanager.yml:ro" -p 127.0.0.1::9093 "$image" \
  --config.file=/tmp/alertmanager.yml --storage.path=/alertmanager >/dev/null
port=$(docker port "$container" 9093/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || { docker logs "$container" >&2 || true; exit 1; }

i=0
until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/-/healthy"); do
  i=$((i + 1))
  [ "$i" -lt 20 ] || { docker logs "$container" >&2 || true; exit 1; }
  sleep 1
done
printf '%s' "$response" | grep -qx 'OK'

docker stop "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ]

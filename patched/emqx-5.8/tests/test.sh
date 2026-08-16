#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}

fail() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/docker-entrypoint.sh"]' ] || fail "unexpected entrypoint"
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["/opt/emqx/bin/emqx","foreground"]' ] || fail "unexpected command"
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = emqx ] || fail "unexpected user"
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /opt/emqx ] || fail "unexpected working directory"
[ "$(docker image inspect --format '{{json .Config.Volumes}}' "$image")" = '{"/opt/emqx/data":{},"/opt/emqx/log":{}}' ] || fail "unexpected volumes"

exposed_ports=$(docker image inspect --format '{{range $port, $_ := .Config.ExposedPorts}}{{println $port}}{{end}}' "$image")
[ "$(printf '%s\n' "$exposed_ports" | grep -c .)" -eq 7 ] || fail "unexpected exposed port count"
for port in 1883 4370 5369 8083 8084 8883 18083; do
  printf '%s\n' "$exposed_ports" | grep -qx "$port/tcp" || fail "missing exposed port $port"
done

arch=$(docker image inspect --format '{{.Architecture}}' "$image")
case $arch in amd64 | arm64) ;; *) fail "unsupported candidate architecture $arch" ;; esac

hostname=verity-emqx-$$.local
node=emqx@$hostname
container=verity-emqx-$$
volume=verity-emqx-data-$$

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || :
  docker volume rm -f "$volume" >/dev/null 2>&1 || :
}
trap cleanup 0 1 2 3 15

docker run --rm --hostname "$hostname" -e "EMQX_NODE_NAME=$node" "$image" \
  /opt/emqx/bin/emqx check_config >/dev/null || fail "valid configuration was rejected"
if docker run --rm -e EMQX_NODE_NAME=invalid "$image" \
  /opt/emqx/bin/emqx check_config >/dev/null 2>&1; then
  fail "invalid node name was accepted"
fi
docker run --rm --entrypoint sh "$image" -c \
  'test -r /opt/emqx/etc/emqx.conf && test -d /opt/emqx/data && test -d /opt/emqx/log' || \
  fail "configuration or data paths are unavailable"

wait_for_emqx() {
  attempts=0
  while ! status=$(timeout 5 docker exec "$container" /usr/bin/curl -fsS 'http://127.0.0.1:18083/status?format=json' 2>/dev/null); do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 90 ]; then
      docker logs "$container" >&2 || :
      fail "EMQX did not become ready within 90 seconds"
    fi
    sleep 1
  done
  printf '%s\n' "$status" | grep -Fq '"broker_status":"started"' || fail "broker is not ready: $status"
  printf '%s\n' "$status" | grep -Fq '"rel_vsn":"v5.10.4"' || fail "unexpected version: $status"
  printf '%s\n' "$status" | grep -Fq "\"node_name\":\"$node\"" || fail "unexpected node identity: $status"
}

docker volume create "$volume" >/dev/null
docker run -d --name "$container" --hostname "$hostname" -e "EMQX_NODE_NAME=$node" \
  -v "$volume:/opt/emqx/data" "$image" >/dev/null
wait_for_emqx
docker exec "$container" sh -c 'printf persisted > /opt/emqx/data/verity-smoke'
docker restart "$container" >/dev/null
wait_for_emqx
[ "$(docker exec "$container" cat /opt/emqx/data/verity-smoke)" = persisted ] || fail "data did not persist across restart"

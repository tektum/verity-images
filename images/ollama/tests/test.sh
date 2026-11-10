#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-ollama-test-$$"
volume="verity-ollama-data-$$"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'image user is not 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/ollama"]' ] || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["serve"]' ] || fail 'unexpected image command'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/ollama ] || fail 'unexpected image working directory'
docker image inspect --format '{{json .Config.Volumes}}' "$image" | grep -q '/home/ollama/.ollama' || fail 'model volume is not declared'
docker image inspect --format '{{json .Config.Env}}' "$image" | grep -q 'OLLAMA_HOST=0.0.0.0:11434' || fail 'OLLAMA_HOST default is missing'
docker run --rm --entrypoint sh "$image" -c 'test -w /home/ollama/.ollama' || fail 'model directory is not writable by the image user'

# CPU build only: the CPU backend must be present and no GPU runtime may ship.
docker run --rm --entrypoint sh "$image" -c 'test -x /usr/lib/ollama/llama-server' || fail 'CPU llama-server backend is missing'
if gpu=$(docker run --rm --entrypoint sh "$image" -c 'find / -xdev \( -iname "*cuda*" -o -iname "*rocm*" -o -iname "*hipblas*" -o -iname "*cublas*" -o -iname "*vulkan*" \) 2>/dev/null | head -3'); [ -n "$gpu" ]; then
  fail "unexpected GPU runtime files in the CPU-only image: $gpu"
fi

version=$(docker run --rm "$image" --version 2>&1 | sed -n 's/^Warning: client version is //p')
[ -n "$version" ] || fail 'ollama --version did not report a client version'

# Negative: an unusable listen address must stop the server with a readable error.
status=0
output=$(docker run --rm -e OLLAMA_HOST=bad:::host "$image" 2>&1) || status=$?
[ "$status" -ne 0 ] || fail 'invalid OLLAMA_HOST unexpectedly started the server'
printf '%s\n' "$output" | grep -q '^Error: listen' || fail "invalid OLLAMA_HOST gave no readable error: $output"

docker volume create "$volume" >/dev/null

start_server() {
  docker run --name "$container" -d -p 127.0.0.1::11434 -v "$volume:/home/ollama/.ollama" "$image" >/dev/null
  port=$(docker port "$container" 11434/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$port" ] || fail 'ollama port was not published'
  i=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/" 2>/dev/null | grep -q 'Ollama is running'; do
    [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || {
      docker logs "$container" >&2
      fail 'ollama exited before becoming ready'
    }
    i=$((i + 1))
    [ "$i" -lt 60 ] || {
      docker logs "$container" >&2
      fail 'ollama did not become ready'
    }
    sleep 1
  done
}

start_server
api_version=$(curl --fail --silent --max-time 5 "http://127.0.0.1:$port/api/version") || fail '/api/version request failed'
printf '%s\n' "$api_version" | grep -q "\"version\":\"$version\"" || fail "/api/version did not report $version, got: $api_version"
tags=$(curl --fail --silent --max-time 5 "http://127.0.0.1:$port/api/tags") || fail '/api/tags request failed'
printf '%s\n' "$tags" | grep -q '"models":\[\]' || fail "fresh model store is not empty: $tags"
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/api/show" -d '{"model":"does-not-exist"}')" = 404 ] ||
  fail 'showing an unknown model did not return 404'
docker exec "$container" ollama list | grep -q '^NAME' || fail 'ollama CLI could not reach the server'
docker logs "$container" 2>&1 | grep -q 'library=cpu' || fail 'server did not select the CPU inference library'

docker stop --time 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] || {
  docker logs "$container" >&2
  fail 'ollama did not exit cleanly on SIGTERM'
}

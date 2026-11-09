#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-qdrant-test-$$"
api_key="verity-api-key-$$"
volume="verity-qdrant-data-$$"
label="verity-test=qdrant-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/qdrant/qdrant"]'
test "$(docker image inspect "$image" --format '{{.Config.WorkingDir}}')" = /qdrant

version=$(docker run --rm --label "$label" "$image" --version)
printf '%s\n' "$version"
printf '%s\n' "$version" | grep -q '^qdrant '

# Negative: an invalid setting must fail with a readable error.
status=0
negative=$(docker run --rm --label "$label" -e QDRANT__SERVICE__HTTP_PORT=notaport "$image" 2>&1) ||
  status=$?
printf '%s\n' "$negative"
test "$status" -ne 0 || {
  printf 'qdrant accepted an invalid http_port\n' >&2
  exit 1
}
printf '%s' "$negative" | grep -q 'service.http_port'


docker volume create "$volume" >/dev/null

start_server() {
  docker run --name "$container" --label "$label" -d \
    -e "QDRANT__SERVICE__API_KEY=$api_key" \
    -e QDRANT__SERVICE__JWT_RBAC=true \
    -v "$volume:/qdrant/storage" \
    -p 127.0.0.1::6333 "$image" >/dev/null
  port=$(docker port "$container" 6333/tcp | awk -F: 'NR == 1 { print $2 }')
  test -n "$port"
  i=0
  until curl -fsS "http://127.0.0.1:$port/readyz" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || {
      docker logs "$container" >&2
      exit 1
    }
    sleep 1
  done
}

api() {
  method=$1
  path=$2
  body=${3:-}
  if [ -n "$body" ]; then
    curl -fsS -X "$method" -H "api-key: $api_key" -H 'Content-Type: application/json' \
      -d "$body" "http://127.0.0.1:$port$path"
  else
    curl -fsS -X "$method" -H "api-key: $api_key" "http://127.0.0.1:$port$path"
  fi
}

start_server

root=$(api GET /)
printf '%s\n' "$root"
printf '%s' "$root" | grep -q '"title":"qdrant - vector search engine"'
printf '%s' "$root" | grep -Fq "\"version\":\"${version#qdrant }\""

# Authentication: the API key and HS256 JWTs signed with it are the only way in.
status_of() {
  curl -s -o /dev/null -w '%{http_code}' "$@"
}

mint_jwt() {
  secret=$1
  access=$2
  python3 - "$secret" "$access" <<'PY'
import base64, hashlib, hmac, json, sys, time

def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

secret, access = sys.argv[1], sys.argv[2]
header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
payload = b64(json.dumps({"exp": int(time.time()) + 600, "access": access}).encode())
signature = hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest()
print(f"{header}.{payload}.{b64(signature)}")
PY
}

anon=$(status_of "http://127.0.0.1:$port/collections")
case "$anon" in 401 | 403) ;; *)
  printf 'unauthenticated request returned %s\n' "$anon" >&2
  exit 1
  ;;
esac
bad_key=$(status_of -H 'api-key: wrong' "http://127.0.0.1:$port/collections")
case "$bad_key" in 401 | 403) ;; *)
  printf 'wrong api key returned %s\n' "$bad_key" >&2
  exit 1
  ;;
esac
manage_jwt=$(mint_jwt "$api_key" m)
test "$(status_of -H "Authorization: Bearer $manage_jwt" "http://127.0.0.1:$port/collections")" = 200
forged_jwt=$(mint_jwt "not-the-api-key" m)
forged=$(status_of -H "Authorization: Bearer $forged_jwt" "http://127.0.0.1:$port/collections")
case "$forged" in 401 | 403) ;; *)
  printf 'JWT signed with the wrong secret returned %s\n' "$forged" >&2
  exit 1
  ;;
esac
read_jwt=$(mint_jwt "$api_key" r)
test "$(status_of -H "Authorization: Bearer $read_jwt" "http://127.0.0.1:$port/collections")" = 200
read_write=$(status_of -X PUT -H "Authorization: Bearer $read_jwt" -H 'Content-Type: application/json' \
  -d '{"vectors":{"size":4,"distance":"Dot"}}' "http://127.0.0.1:$port/collections/readonly-denied")
case "$read_write" in 401 | 403) ;; *)
  printf 'read-only JWT could write: %s\n' "$read_write" >&2
  exit 1
  ;;
esac

test "$(status_of "http://127.0.0.1:$port/dashboard/")" = 200

api PUT /collections/verity '{"vectors":{"size":4,"distance":"Dot"}}' | grep -q '"result":true'
api PUT '/collections/verity/points?wait=true' \
  '{"points":[{"id":1,"vector":[0.05,0.61,0.76,0.74],"payload":{"name":"one"}},{"id":2,"vector":[0.19,0.81,0.75,0.11],"payload":{"name":"two"}},{"id":3,"vector":[0.36,0.55,0.47,0.94],"payload":{"name":"three"}}]}' |
  grep -q '"status":"completed"'
hit=$(api POST /collections/verity/points/search \
  '{"vector":[0.2,0.1,0.9,0.7],"limit":1,"with_payload":true}')
printf '%s\n' "$hit"
printf '%s' "$hit" | grep -q '"id":1'
printf '%s' "$hit" | grep -q '"name":"one"'

# SIGTERM must stop the server cleanly.
docker stop -t 30 "$container" >/dev/null
exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container")
test "$exit_code" = 0 || {
  docker logs "$container" >&2
  printf 'qdrant exited %s after SIGTERM\n' "$exit_code" >&2
  exit 1
}
docker rm "$container" >/dev/null

# Persistence: the collection and its point survive a restart on the same volume.
start_server
count=$(api POST /collections/verity/points/count '{"exact":true}')
printf '%s\n' "$count"
printf '%s' "$count" | grep -q '"count":3'

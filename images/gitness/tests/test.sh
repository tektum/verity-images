#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
suffix="$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
container="verity-gitness-test-$suffix"
volume="verity-gitness-data-$suffix"
work=$(mktemp -d)
marker="verity-gitness-$suffix"
user=verity
password="Verity-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
space=verity
repo=smoke

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the gitness recipe version'

# OCI contract of upstream harness/harness (harness/gitness Dockerfile), with
# the documented non-root user.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/app/gitness","server"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /app ||
  fail 'unexpected working directory'
test "$(docker image inspect --format '{{json .Config.Volumes}}' "$image")" = \
  '{"/data":{}}' || fail 'unexpected volumes'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" >"$work/env"
for entry in XDG_CACHE_HOME=/data GITNESS_GIT_ROOT=/data \
  GITNESS_REGISTRY_FILESYSTEM_ROOT_DIRECTORY=/data/registry \
  GITNESS_DATABASE_DRIVER=sqlite3 GITNESS_DATABASE_DATASOURCE=/data/database.sqlite \
  GITNESS_METRIC_ENABLED=true GITNESS_METRIC_ENDPOINT=https://stats.drone.ci/api/v1/gitness \
  GITNESS_TOKEN_COOKIE_NAME=token GITNESS_DOCKER_API_VERSION=1.41 \
  GITNESS_SSH_ENABLE=true GITNESS_GITSPACE_ENABLE=true; do
  grep -Fx "$entry" "$work/env" >/dev/null || fail "missing environment entry $entry"
done

docker run --rm --network none --entrypoint /bin/sh "$image" -c \
  'readlink -f /app/gitness; id -u; git --version; git lfs version; cat /usr/lib/apk/db/installed' \
  >"$work/runtime" 2>&1 || fail "runtime inspection failed: $(cat "$work/runtime")"
sed -n 1p "$work/runtime" | grep -Fx /usr/bin/gitness >/dev/null ||
  fail "/app/gitness does not resolve to /usr/bin/gitness: $(cat "$work/runtime")"
sed -n 2p "$work/runtime" | grep -Fx 65532 >/dev/null ||
  fail 'container does not run as uid 65532'
grep '^git version ' "$work/runtime" >/dev/null || fail 'git is missing'
grep '^git-lfs/' "$work/runtime" >/dev/null || fail 'git-lfs is missing'
awk '/^P:verity-gitness$/ { p = 1; next } p && /^V:/ { print; exit }' "$work/runtime" |
  grep -Ex "V:$version-r[0-9]+" >/dev/null || fail "installed verity-gitness is not $version"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown long flag' "$work/flag" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/flag")"

start() {
  docker run -d --name "$container" -v "$volume:/data" \
    -p 127.0.0.1::3000 -p 127.0.0.1::3022 \
    -e GITNESS_METRIC_ENABLED=false "$image" >/dev/null
  port=$(docker port "$container" 3000/tcp | awk -F: 'NR == 1 { print $NF }')
  [ -n "$port" ] || fail 'http port is not published'
  api="http://127.0.0.1:$port/api/v1"
  i=0
  until code=$(curl --silent --connect-timeout 1 --max-time 5 -o /dev/null \
    -w '%{http_code}' "$api/system/health") && [ "$code" = 200 ]; do
    i=$((i + 1))
    if [ "$i" -ge 180 ]; then
      docker logs "$container" >&2 || true
      fail 'server did not become healthy'
    fi
    sleep 1
  done
  i=0
  until docker logs "$container" 2>&1 | grep -F '"message":"server started"' >/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 30 ] || fail 'server did not log startup'
    sleep 1
  done
  if docker logs "$container" 2>&1 | grep -F '"level":"error"' >"$work/errors"; then
    fail "server logged errors at startup: $(cat "$work/errors")"
  fi
}

# request METHOD PATH [BODY]: writes the body to $work/body, prints the status.
request() {
  set -- "$1" "$api$2" "${3-}" -H 'Content-Type: application/json'
  if [ -n "$token" ]; then
    set -- "$@" -H "Authorization: Bearer $token"
  fi
  if [ -n "$3" ]; then
    set -- "$@" --data "$3"
  fi
  method=$1
  url=$2
  shift 3
  curl --silent --show-error --max-time 30 -o "$work/body" -w '%{http_code}' \
    -X "$method" "$@" "$url"
}

expect() {
  want=$1
  shift
  got=$(request "$@") || fail "$1 $2 request failed"
  test "$got" = "$want" || fail "$1 $2 returned $got, want $want: $(cat "$work/body")"
}

json() {
  jq -er "$1" "$work/body" 2>/dev/null || fail "response lacks $1: $(cat "$work/body")"
}

# git runs inside the image itself, sharing the server's network namespace.
git_client() {
  docker run --rm -i --network "container:$container" --entrypoint /bin/sh \
    -e HOME=/tmp -e GIT_TERMINAL_PROMPT=0 -v "$work/ssh:/ssh:ro" "$image" -c "$1"
}

token=
start

expect 200 GET /system/version
test "$(cat "$work/body")" = "$version" ||
  fail "version endpoint returned $(cat "$work/body"), want $version"
docker logs "$container" 2>&1 | grep -F '"message":"server started"' |
  grep -F "\"version\":\"$version\"" >/dev/null || fail "server did not log version $version"
expect 200 GET /system/config
test "$(json .ssh_enabled)" = true || fail 'ssh is not enabled'
test "$(json .gitspace_enabled)" = true || fail 'gitspaces are not enabled'

# Negative cases: anonymous writes and bad credentials are rejected.
expect 401 POST /spaces "{\"identifier\":\"$space\"}"
expect 404 GET /system/definitely-missing

expect 200 POST /register \
  "{\"uid\":\"$user\",\"email\":\"$user@example.com\",\"display_name\":\"Verity\",\"password\":\"$password\"}"
token=$(json .access_token)
expect 200 GET /user
test "$(json .uid)" = "$user" || fail 'registered user lookup returned the wrong uid'
# The first registered user is the instance administrator.
test "$(json .admin)" = true || fail 'first registered user is not an administrator'

expect 201 POST /spaces "{\"identifier\":\"$space\",\"is_public\":false}"
expect 201 POST /repos \
  "{\"parent_ref\":\"$space\",\"identifier\":\"$repo\",\"default_branch\":\"main\",\"readme\":true}"
test "$(json .path)" = "$space/$repo" || fail 'created repository has the wrong path'
test "$(json .default_branch)" = main || fail 'created repository has the wrong default branch'

# Git over HTTP accepts personal access tokens and rejects session tokens.
expect 201 POST /user/tokens "{\"identifier\":\"verity-git\",\"lifetime\":86400000000000}"
pat=$(json .access_token)
mkdir "$work/ssh"
if git_client "git clone -q 'http://$user:$token@127.0.0.1:3000/git/$space/$repo.git' /tmp/repo" \
  >"$work/session-clone" 2>&1; then
  fail 'git clone unexpectedly accepted a session token'
fi
grep -F 'Authentication failed' "$work/session-clone" >/dev/null ||
  fail "session token rejection is missing: $(cat "$work/session-clone")"

# Push a commit over smart HTTP; gitness runs its git hooks during receive.
git_client "
set -eu
git config --global user.email verity@example.com
git config --global user.name Verity
git config --global init.defaultBranch main
git clone -q 'http://$user:$pat@127.0.0.1:3000/git/$space/$repo.git' /tmp/repo
cd /tmp/repo
test -f README.md
printf '%s\n' '$marker' >marker.txt
git add marker.txt
git commit -q -m '$marker'
git push -q origin main
" >"$work/push" 2>&1 || fail "http clone and push failed: $(cat "$work/push")"

expect 200 GET "/repos/$space%2F$repo/commits?git_ref=main&limit=1"
json '.commits[0].message' | grep -F "$marker" >/dev/null ||
  fail "pushed commit is not the head of main: $(cat "$work/body")"
expect 200 GET "/repos/$space%2F$repo/raw/marker.txt?git_ref=main"
grep -Fx "$marker" "$work/body" >/dev/null || fail 'pushed file content is wrong'

# Clone over the built-in SSH server on 3022 with a registered public key.
ssh-keygen -q -t ed25519 -N '' -C verity -f "$work/ssh/id_ed25519" ||
  fail 'ssh-keygen failed'
chmod 0644 "$work/ssh/id_ed25519"
pubkey=$(cat "$work/ssh/id_ed25519.pub")
expect 201 POST /user/keys \
  "{\"identifier\":\"verity\",\"usage\":\"auth\",\"scheme\":\"ssh\",\"content\":\"$pubkey\"}"
# The SSH listener starts after HTTP; under emulation it can lag, so retry
# only while the connection is refused.
i=0
until git_client "
set -eu
cp /ssh/id_ed25519 /tmp/key
chmod 0600 /tmp/key
export GIT_SSH_COMMAND='ssh -i /tmp/key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
git clone -q 'ssh://git@127.0.0.1:3022/$space/$repo.git' /tmp/ssh-repo
cat /tmp/ssh-repo/marker.txt
" >"$work/ssh-clone" 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 90 ] || ! grep -F 'Connection refused' "$work/ssh-clone" >/dev/null; then
    fail "ssh clone failed: $(cat "$work/ssh-clone")"
  fi
  sleep 2
done
grep -Fx "$marker" "$work/ssh-clone" >/dev/null ||
  fail "ssh clone returned the wrong content: $(cat "$work/ssh-clone")"

# Persistence: database and repositories live on /data.
docker exec "$container" test -s /data/database.sqlite ||
  fail 'database was not written to /data/database.sqlite'
docker rm -f "$container" >/dev/null
token=
start
expect 200 POST /login "{\"login_identifier\":\"$user\",\"password\":\"$password\"}"
token=$(json .access_token)
expect 200 GET "/repos/$space%2F$repo/raw/marker.txt?git_ref=main"
grep -Fx "$marker" "$work/body" >/dev/null || fail 'repository did not persist across restart'
token=
# gitness answers a wrong password with 404 so logins cannot enumerate users.
expect 404 POST /login "{\"login_identifier\":\"$user\",\"password\":\"wrong-$password\"}"

printf 'gitness %s smoke test passed\n' "$version"

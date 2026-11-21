#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$here/../melange.yaml")
id=$$
server="verity-code-server-$id"
open="verity-code-server-open-$id"
client="verity-code-server-client-$id"
net="verity-code-server-net-$id"
work=$(mktemp -d)
# A per-run secret; never a fixed credential.
password="smoke-$id-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$server" "$open"; do
    docker logs "$c" 2>&1 | tail -n 30 >&2 || true
  done
  exit 1
}

cleanup() {
  docker rm -f "$server" "$open" "$client" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  # Files written by uid 1000 in the bind-mounted home.
  docker run --rm --user 0 --entrypoint /bin/rm -v "$work:/work" "$image" -rf /work/home >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# Request a URL from a separate client container on the test network with the
# image's own Node.js, so the server must listen on a non-loopback address.
# Prints "STATUS", "location: ...", "set-cookie: ..." and then the body.
request() {
  docker exec "$client" /usr/bin/node -e '
const [method, url, body, cookie] = process.argv.slice(1);
const init = { method, redirect: "manual", headers: {} };
if (body) { init.body = body; init.headers["content-type"] = "application/x-www-form-urlencoded"; }
if (cookie) { init.headers.cookie = cookie; }
fetch(url, init)
  .then(async (r) => {
    console.log(r.status);
    console.log("location: " + (r.headers.get("location") || ""));
    console.log("set-cookie: " + (r.headers.get("set-cookie") || ""));
    process.stdout.write(await r.text());
  })
  .catch((e) => { console.error(e.message); process.exit(1); });
' "$@"
}

# CI also runs this test for arm64 under emulation; allow a slow first start.
wait_healthy() {
  i=0
  while [ "$i" -lt 240 ]; do
    if request GET "http://$1:8080/healthz" >"$work/healthz" 2>/dev/null &&
      [ "$(head -n1 "$work/healthz")" = 200 ]; then
      return 0
    fi
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ] ||
      fail "$1 exited before becoming ready"
    i=$((i + 1))
    sleep 1
  done
  fail "$1 /healthz did not become ready"
}

[ -n "$version" ] || fail 'could not read the code-server package version'

# OCI contract, matching upstream codercom/code-server.
test "$(docker image inspect -f '{{.Config.User}}' "$image")" = 1000 || fail 'unexpected OCI user'
test "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/entrypoint.sh","--bind-addr","0.0.0.0:8080","."]' || fail 'unexpected entrypoint'
test "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = null || fail 'unexpected command'
test "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /home/coder ||
  fail 'unexpected working directory'
docker image inspect -f '{{json .Config.Env}}' "$image" >"$work/env"
for e in HOME=/home/coder USER=coder LANG=en_US.UTF-8 ENTRYPOINTD=/entrypoint.d; do
  grep -F "\"$e\"" "$work/env" >/dev/null || fail "missing environment $e"
done

docker run --rm --network none --entrypoint /bin/sh "$image" -c 'id -u; id -g; id -un; echo "$HOME"' \
  >"$work/id" || fail 'id failed'
test "$(tr '\n' ' ' <"$work/id")" = '1000 1000 coder /home/coder ' ||
  fail "unexpected runtime identity: $(cat "$work/id")"
for setuid in /usr/bin/sudo /usr/local/bin/fixuid; do
  docker run --rm --network none --entrypoint /bin/sh "$image" -c "test ! -e $setuid" ||
    fail "$setuid must not be present"
done

# The entrypoint forwards arguments to code-server after upstream's defaults.
# code-server logs that it wrote a default config to the home before the version.
docker run --rm --network none "$image" --version >"$work/version" 2>&1 || fail 'version failed'
grep -E "^$version [0-9a-f]{40} with Code [0-9.]+$" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

# Native addons built for the Wolfi Node.js: a pty terminal runs a shell.
docker run --rm --network none --entrypoint /usr/bin/node -w /usr/lib/code-server/lib/vscode "$image" -e '
const pty = require("./node_modules/node-pty");
for (const m of ["@vscode/spdlog", "@parcel/watcher", "@vscode/sqlite3", "kerberos", "@vscode/native-watchdog"])
  require("./node_modules/" + m);
require("../../node_modules/argon2");
let out = "";
const p = pty.spawn("/bin/bash", ["-c", "echo pty-$((6*7))"], {});
p.onData((d) => { out += d; });
p.onExit(({ exitCode }) => { process.stdout.write(out); process.exit(exitCode); });
' >"$work/pty" 2>&1 || fail "native addons failed: $(cat "$work/pty")"
grep -F pty-42 "$work/pty" >/dev/null || fail "pty output missing: $(cat "$work/pty")"

docker network create "$net" >/dev/null
docker run -d --name "$client" --network "$net" --entrypoint /bin/sleep "$image" 3600 >/dev/null ||
  fail 'client container failed to start'

# Password auth from the environment, read-only root, no capabilities, and a
# bind-mounted writable home that holds settings, extensions and the workspace.
mkdir -p "$work/home/project"
printf 'hello from the workspace\n' >"$work/home/project/README.md"
chmod -R a+rwX "$work/home"
docker run -d --name "$server" --network "$net" --read-only --cap-drop=ALL \
  --tmpfs /tmp:rw,mode=1777 -e PASSWORD="$password" -v "$work/home:/home/coder" \
  "$image" >/dev/null || fail 'password server failed to start'
wait_healthy "$server"

head -n1 "$work/healthz" | grep -Fx 200 >/dev/null || fail '/healthz status'
tail -n +4 "$work/healthz" >"$work/healthz.json"
docker run --rm --network none -i --entrypoint /usr/bin/node "$image" -e '
let s = ""; process.stdin.on("data", (d) => { s += d; }).on("end", () => {
  const j = JSON.parse(s);
  if (!["alive", "expired"].includes(j.status) || typeof j.lastHeartbeat !== "number") process.exit(1);
});' <"$work/healthz.json" || fail "/healthz is not the expected JSON: $(cat "$work/healthz.json")"

request GET "http://$server:8080/" >"$work/root"
head -n1 "$work/root" | grep -Fx 302 >/dev/null || fail "unauthenticated / did not redirect: $(head -n2 "$work/root")"
sed -n 2p "$work/root" | grep -E '^location: \./login(\?|$)' >/dev/null ||
  fail "unauthenticated / did not redirect to login: $(sed -n 2p "$work/root")"

request GET "http://$server:8080/login" >"$work/login"
head -n1 "$work/login" | grep -Fx 200 >/dev/null || fail 'login page status'
grep -F 'name="password"' "$work/login" >/dev/null || fail 'login page has no password field'
grep -F 'code-server' "$work/login" >/dev/null || fail 'login page is not code-server'
grep -F 'PASSWORD' "$work/login" >/dev/null || fail 'login page does not name the PASSWORD source'
request GET "http://$server:8080/robots.txt" >"$work/robots"
head -n1 "$work/robots" | grep -Fx 200 >/dev/null || fail "robots.txt status: $(head -n1 "$work/robots")"

# Negative: a wrong password is rejected without a session cookie.
request POST "http://$server:8080/login" "password=wrong-$id" >"$work/bad-login"
head -n1 "$work/bad-login" | grep -Fx 200 >/dev/null || fail "wrong password status: $(head -n1 "$work/bad-login")"
grep -F 'Incorrect password' "$work/bad-login" >/dev/null || fail 'wrong password was not rejected'
sed -n 3p "$work/bad-login" | grep -F 'code-server-session=' >/dev/null &&
  fail 'wrong password set a session cookie'

request POST "http://$server:8080/login" "password=$password" >"$work/good-login"
head -n1 "$work/good-login" | grep -Fx 302 >/dev/null || fail "login status: $(head -n1 "$work/good-login")"
cookie=$(sed -n 's/^set-cookie: \(code-server-session=[^;]*\).*/\1/p' "$work/good-login")
[ -n "$cookie" ] || fail 'login did not set a session cookie'

request GET "http://$server:8080/?folder=/home/coder/project" "" "$cookie" >"$work/workbench"
head -n1 "$work/workbench" | grep -Fx 200 >/dev/null || fail "authenticated / status: $(head -n1 "$work/workbench")"
grep -F 'workbench' "$work/workbench" >/dev/null || fail 'authenticated / is not the VS Code workbench'

# Static workbench assets are served from the installed VS Code bundle.
static=$(grep -o 'src="[^"]*workbench\.js"' "$work/workbench" | head -n1 | sed 's/^src="//; s/"$//')
[ -n "$static" ] || fail 'workbench page references no workbench.js'
case "$static" in
  http*) ;;
  /*) static="http://$server:8080$static" ;;
  *) static="http://$server:8080/${static#./}" ;;
esac
request GET "$static" "" "$cookie" >"$work/static"
head -n1 "$work/static" | grep -Fx 200 >/dev/null || fail "workbench.js status: $(head -n1 "$work/static")"

request GET "http://$server:8080/does-not-exist" "" "$cookie" >"$work/missing"
head -n1 "$work/missing" | grep -Fx 404 >/dev/null || fail "unknown path status: $(head -n1 "$work/missing")"

# State lands in the writable home volume, owned by the coder user.
docker exec "$server" /bin/sh -c '
  test -d /home/coder/.local/share/code-server &&
  test "$(stat -c %u /home/coder/.local/share/code-server)" = 1000 &&
  test -f /home/coder/.config/code-server/config.yaml &&
  touch /home/coder/project/written-by-coder' || fail 'home volume state is missing or not writable'
test -f "$work/home/project/written-by-coder" || fail 'workspace write did not reach the volume'
docker exec "$server" /bin/sh -c 'touch /usr/lib/code-server/x' 2>/dev/null &&
  fail 'read-only root filesystem is writable'

rc=0
docker stop -t 15 "$server" >/dev/null
rc=$(docker inspect -f '{{.State.ExitCode}}' "$server")
case "$rc" in
  0 | 143) ;;
  *) fail "password server exit code $rc after SIGTERM" ;;
esac

# --auth none serves the workbench without a login.
docker run -d --name "$open" --network "$net" --read-only --cap-drop=ALL \
  --tmpfs /tmp:rw,mode=1777 -v "$work/home:/home/coder" "$image" --auth none >/dev/null ||
  fail 'auth none server failed to start'
wait_healthy "$open"
request GET "http://$open:8080/?folder=/home/coder/project" >"$work/open"
head -n1 "$work/open" | grep -Fx 200 >/dev/null || fail "auth none / status: $(head -n1 "$work/open")"
grep -F 'workbench' "$work/open" >/dev/null || fail 'auth none / is not the VS Code workbench'
request GET "http://$open:8080/login" >"$work/open-login"
head -n1 "$work/open-login" | grep -Fx 302 >/dev/null || fail 'auth none still serves a login page'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"

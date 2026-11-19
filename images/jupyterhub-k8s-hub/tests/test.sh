#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
recipe=$here/../melange.yaml
hub="verity-jupyterhub-hub-test-$$"
proxy="verity-jupyterhub-proxy-test-$$"
network="verity-jupyterhub-net-$$"
volume="verity-jupyterhub-data-$$"
label="verity-w5e=jupyterhub-k8s-hub"
config=/usr/local/etc/jupyterhub/jupyterhub_config.py
requirements_dir=/usr/share/verity-jupyterhub-k8s-hub
work=$(mktemp -d)

# Secrets are generated per run; nothing is stored in the repository.
token() { od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; }
api_token=$(token)
proxy_token=$(token)

# The expected release comes from the recipe, so a version bump needs no edit here.
expected_release=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$recipe" | head -n 1)
[ -n "$expected_release" ] || { printf 'package version not found in %s\n' "$recipe" >&2; exit 1; }

cleanup() {
  docker rm -f "$hub" "$proxy" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$hub" >&2 2>&1 || true
  docker logs "$proxy" >&2 2>&1 || true
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Every container runs as the image's user with no capabilities and a
# read-only root filesystem.
run() {
  docker run --label "$label" --read-only --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp:uid=1000,gid=1000,mode=1777 "$@"
}

inspect() { docker image inspect --format "$1" "$image"; }

# Upstream image contract (images/hub/Dockerfile).
test "$(inspect '{{.Config.User}}')" = 1000 || fail 'unexpected OCI user'
test "$(inspect '{{.Config.WorkingDir}}')" = /srv/jupyterhub || fail 'unexpected working directory'
test "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/tini","--"]' ||
  fail 'entrypoint is not tini'
test "$(inspect '{{json .Config.Cmd}}')" = "[\"jupyterhub\",\"--config\",\"$config\"]" ||
  fail 'default command does not start jupyterhub with the chart config path'

run --rm "$image" python3 -c '
import grp, os, pwd, shutil
user = pwd.getpwuid(os.getuid())
assert (user.pw_name, user.pw_uid, user.pw_gid) == ("jovyan", 1000, 1000), user
assert grp.getgrgid(os.getgid()).gr_name == "jovyan"
assert os.environ["HOME"] == user.pw_dir == "/home/jovyan", os.environ["HOME"]
assert os.getcwd() == "/srv/jupyterhub", os.getcwd()
st = os.stat("/srv/jupyterhub")
assert (st.st_uid, st.st_gid) == (1000, 1000), st
# The proxy is a separate chart component, as upstream: not in this image.
assert shutil.which("configurable-http-proxy") is None
assert shutil.which("jupyterhub") and shutil.which("tini") and shutil.which("sqlite3")
' || fail 'user, home, working directory or PATH contract broken'

# The image ships upstream's frozen requirements plus the recipe overrides, built
# for this release, and every module the chart and its documented options rely
# on imports.
run --rm -e EXPECTED_RELEASE="$expected_release" "$image" python3 -c '
import importlib, importlib.metadata as md, os, re
release = os.environ["EXPECTED_RELEASE"]
installed = open("/usr/lib/apk/db/installed").read()
assert f"P:verity-jupyterhub-k8s-hub\nV:{release}-r" in installed, "apk version is not " + release

def pins(path):
    result = {}
    for line in open(path):
        line = line.split("#")[0].strip()
        if line:
            name, version = line.split("==")
            result[re.sub(r"[-_.]+", "-", name).lower()] = version
    return result
frozen = pins("'"$requirements_dir"'/requirements.txt")
upstream = pins("'"$requirements_dir"'/upstream-requirements.txt")
have = {re.sub(r"[-_.]+", "-", d.metadata["Name"]).lower(): d.version for d in md.distributions()}
assert have == frozen, sorted(set(have.items()) ^ set(frozen.items()))
# Overrides only move versions of upstream pins; no package is added or dropped.
assert frozen.keys() == upstream.keys(), sorted(frozen.keys() ^ upstream.keys())
assert len(frozen) > 50, len(frozen)
key = lambda v: tuple(int(part) for part in v.split("."))
for name in sorted(frozen):
    if frozen[name] != upstream[name]:
        assert key(frozen[name]) > key(upstream[name]), (name, upstream[name], frozen[name])
        print("override", name, upstream[name], "->", frozen[name])

for module in """jupyterhub jupyterhub.app kubespawner kubernetes_asyncio oauthenticator
    oauthenticator.generic oauthenticator.github oauthenticator.google oauthenticator.mediawiki
    oauthenticator.azuread ldapauthenticator ltiauthenticator nativeauthenticator
    firstuseauthenticator hmacauthenticator tmpauthenticator jupyterhub_idle_culler
    google.auth google_auth_oauthlib mwoauth pycurl psycopg2 pymysql sqlalchemy_cockroachdb statsd
    yaml ruamel.yaml tornado.curl_httpclient""".split():
    importlib.import_module(module)

import kubespawner, pycurl, psycopg2
assert kubespawner.KubeSpawner.__module__ == "kubespawner.spawner"
assert "OpenSSL" in pycurl.version and "https" in pycurl.version_info()[8], pycurl.version
assert psycopg2.__libpq_version__ >= 140000, psycopg2.__libpq_version__
print("modules ok", md.version("jupyterhub"), md.version("jupyterhub-kubespawner"))
' >"$work/modules.txt" 2>&1 || { cat "$work/modules.txt" >&2; fail 'frozen requirements or module imports broken'; }
cat "$work/modules.txt"
hub_version=$(awk '/^modules ok/ { print $3 }' "$work/modules.txt")
test -n "$hub_version" || fail 'JupyterHub version not reported'

# Negative: a config naming an unknown authenticator stops the hub with an error.
printf 'c.JupyterHub.authenticator_class = "no_such_module.Authenticator"\n' >"$work/bad_config.py"
chmod 644 "$work/bad_config.py"
if run --rm -v "$work/bad_config.py:$config:ro" --tmpfs /srv/jupyterhub:uid=1000,gid=1000 \
  "$image" >"$work/bad.log" 2>&1; then
  fail 'hub started with an unknown authenticator class'
fi
grep -F 'no_such_module' "$work/bad.log" >/dev/null ||
  { cat "$work/bad.log" >&2; fail 'unknown authenticator was not reported'; }

docker network create --label "$label" "$network" >/dev/null
docker volume create --label "$label" "$volume" >/dev/null

# The proxy API stand-in runs from the same image (python3 and tornado).
run -d --name "$proxy" --network "$network" --network-alias proxy-api \
  -e CONFIGPROXY_AUTH_TOKEN="$proxy_token" \
  -v "$here/proxy_api.py:/srv/proxy_api.py:ro" "$image" python3 /srv/proxy_api.py >/dev/null

start_hub() {
  run -d --name "$hub" --network "$network" --network-alias hub \
    -e SMOKE_API_TOKEN="$api_token" -e CONFIGPROXY_AUTH_TOKEN="$proxy_token" \
    -v "$here/jupyterhub_config.py:$config:ro" -v "$volume:/srv/jupyterhub" \
    -p 127.0.0.1::8081 "$image" "$@" >/dev/null
  port=$(docker port "$hub" 8081/tcp | awk -F: 'NR == 1 { print $2 }')
  test -n "$port" || fail 'hub port was not published'
  base="http://127.0.0.1:$port/hub"
  attempts=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 "$base/health" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 60 ] || fail 'hub did not become healthy'
    sleep 1
  done
}

status() { # FILE [CURL ARGS...] -> HTTP status, body in FILE
  out=$1
  shift
  curl --silent --show-error --max-time 10 --output "$out" --write-out '%{http_code}' "$@"
}

# The default command (no arguments) loads the mounted config file: without
# it the hub would use its PAM authenticator and local process spawner.
start_hub
docker logs "$hub" 2>&1 | grep -F "Using Authenticator: jupyterhub.auth.DummyAuthenticator-" >/dev/null ||
  fail 'mounted config file was not loaded'
docker logs "$hub" 2>&1 | grep -F "Using Spawner: kubespawner.spawner.KubeSpawner-" >/dev/null ||
  fail 'hub is not using KubeSpawner'

code=$(status "$work/root.json" "$base/api/")
test "$code" = 200 || fail "GET /hub/api/ returned $code"
test "$(jq -r .version "$work/root.json")" = "$hub_version" ||
  fail "GET /hub/api/ did not report version $hub_version"
printf 'GET /hub/api/ -> 200 %s\n' "$(jq -c . "$work/root.json")"

code=$(status "$work/anon.json" "$base/api/users")
test "$code" = 403 || fail "unauthenticated GET /hub/api/users returned $code, wanted 403"
code=$(status "$work/wrong.json" -H "Authorization: token $(token)" "$base/api/users")
test "$code" = 403 || fail "wrong-token GET /hub/api/users returned $code, wanted 403"

code=$(status "$work/users.json" -H "Authorization: token $api_token" "$base/api/users")
test "$code" = 200 || fail "authenticated GET /hub/api/users returned $code"
jq -e 'map(select(.name == "admin" and .admin == true)) | length == 1' "$work/users.json" >/dev/null ||
  fail 'admin user missing from /hub/api/users'
printf 'GET /hub/api/users (token) -> 200 %s\n' "$(jq -c 'map({name, admin})' "$work/users.json")"

code=$(status "$work/created.json" -X POST -H "Authorization: token $api_token" "$base/api/users/smoke-user")
test "$code" = 201 || fail "POST /hub/api/users/smoke-user returned $code, wanted 201"

# The hub registered its default route with the external proxy, through pycurl.
docker logs "$proxy" 2>&1 | grep -E '^proxy-api POST /api/routes/ .*"target": ?"http://hub:8081"' \
  >"$work/route.txt" || fail 'hub did not register its route with the proxy API'
grep -F pycurl "$work/route.txt" >/dev/null || fail 'proxy API call did not use pycurl'

# SIGTERM through tini stops the hub cleanly.
docker stop --time 20 "$hub" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$hub")" = 0 || fail 'hub did not exit 0 on SIGTERM'
docker rm "$hub" >/dev/null

# The SQLite database on the volume survives a restart with the chart's
# --upgrade-db flag.
start_hub jupyterhub --config "$config" --upgrade-db
code=$(status "$work/users2.json" -H "Authorization: token $api_token" "$base/api/users")
test "$code" = 200 || fail "GET /hub/api/users after restart returned $code"
jq -e 'any(.name == "smoke-user")' "$work/users2.json" >/dev/null || fail 'user did not persist across restart'

printf 'SMOKE PASS image=%s release=%s jupyterhub=%s\n' "$image" "$expected_release" "$hub_version"

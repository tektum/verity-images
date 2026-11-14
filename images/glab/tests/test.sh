#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - glab=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
python_index='docker.io/library/python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e'
api="verity-glab-api-$$"
network="verity-glab-network-$$"
volume="verity-glab-home-$$"
host=gitlab.fixture.test
work=$(mktemp -d)

cleanup() {
  docker rm -f "$api" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned glab version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/glab"]' || fail 'unexpected entrypoint'

# Every glab container below runs with --network none or on an internal
# network that only reaches the local fixture, so nothing can contact
# gitlab.com or any other public host. A tmpfs HOME keeps runs independent.
offline() {
  docker run --rm --network none --read-only \
    --tmpfs /home/nonroot:uid=65532,gid=65532,mode=0755 "$image" "$@"
}

offline version >"$work/version" 2>&1 || fail "version failed: $(cat "$work/version")"
grep -E "^glab $version( |\$)" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

offline --help >"$work/help" 2>&1 || fail "help failed: $(cat "$work/help")"
for command in api auth config issue mr repo ci; do
  grep -E "^ +$command " "$work/help" >/dev/null ||
    fail "help does not list $command: $(cat "$work/help")"
done
# The image disables the release check, which would otherwise try gitlab.com.
if grep -F 'checking for glab updates' "$work/help" >/dev/null; then
  fail "help attempted an update check: $(cat "$work/help")"
fi

rc=0
offline --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/flag" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/flag")"

rc=0
offline definitely-not-a-command >"$work/command" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid command unexpectedly succeeded'
grep -F 'unknown command "definitely-not-a-command" for "glab"' "$work/command" >/dev/null ||
  fail "invalid command diagnostic is missing: $(cat "$work/command")"

rc=0
docker run --rm --network none --read-only \
  --tmpfs /home/nonroot:uid=65532,gid=65532,mode=0755 -e GITLAB_HOST="$host" \
  "$image" auth status >"$work/noauth" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'auth status without credentials unexpectedly succeeded'
grep -F "$host has not been authenticated with glab" "$work/noauth" >/dev/null ||
  fail "auth status diagnostic is missing: $(cat "$work/noauth")"

# The config round-trip uses a named volume over HOME, so the second container
# reads what the first wrote under the default ~/.config/glab-cli location.
docker volume create "$volume" >/dev/null
home() {
  docker run --rm --read-only -v "$volume:/home/nonroot" "$@"
}
home --network none "$image" config set --global editor verity-editor >"$work/set" 2>&1 ||
  fail "config set failed: $(cat "$work/set")"
home --network none "$image" config get editor >"$work/get" 2>&1 ||
  fail "config get failed: $(cat "$work/get")"
grep -Fx verity-editor "$work/get" >/dev/null ||
  fail "config get did not return the stored value: $(cat "$work/get")"

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")

# Pull a pinned helper index by its per-platform child digest. A classic Docker
# image store cannot bind an index digest to a second platform's image, so the
# index bytes are verified against the pin before a child is chosen, which keeps
# the pin authoritative.
resolve_helper() {
  helper_index=$1
  helper_raw=$(docker buildx imagetools inspect --raw "$helper_index") ||
    fail 'cannot inspect helper image index'
  [ "sha256:$(printf '%s' "$helper_raw" | sha256sum | cut -d' ' -f1)" = "${helper_index#*@}" ] ||
    fail 'helper image index digest mismatch'
  helper_digest=$(printf '%s' "$helper_raw" |
    jq -r --arg arch "$image_arch" '
      [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
      | if length == 1 then .[0] else empty end') ||
    fail 'cannot resolve helper image digest'
  case $helper_digest in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch helper image in $helper_index" ;;
  esac
  helper=${helper_index%%:*}@$helper_digest
  docker pull --quiet --platform "linux/$image_arch" "$helper" >/dev/null ||
    fail 'cannot pull helper image'
}
resolve_helper "$python_index"
python=$helper

# A minimal GitLab REST API fixture on an internal network. It serves a user,
# one project, and its issues over plain HTTP and records every request with
# its token headers so the test can assert what glab sent.
cat >"$work/api.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

USER = '{"id": 4242, "username": "verity-bot", "name": "Verity Bot", "state": "active"}'
PROJECT = (
    '{"id": 7, "name": "demo", "path_with_namespace": "verity/demo", '
    '"default_branch": "main", "web_url": "http://gitlab.fixture.test/verity/demo"}'
)
ISSUES = (
    '[{"id": 70001, "iid": 1, "project_id": 7, "title": "verity fixture issue", '
    '"state": "opened", "labels": [], "created_at": "2026-11-13T10:00:00Z", '
    '"updated_at": "2026-11-13T10:00:00Z", '
    '"web_url": "http://gitlab.fixture.test/verity/demo/-/issues/1", '
    '"references": {"full": "verity/demo#1"}}]'
)
ROUTES = {
    "/api/v4/user": USER,
    "/api/v4/version": '{"version": "18.5.0", "revision": "verity"}',
    "/api/v4/projects/verity%2Fdemo": PROJECT,
    "/api/v4/projects/verity%2Fdemo/issues": ISSUES,
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body):
        sys.stdout.write(
            "REQ %s %s private-token=%s authorization=%s\n"
            % (
                self.command,
                self.path,
                self.headers.get("PRIVATE-TOKEN", "-"),
                self.headers.get("Authorization", "-"),
            )
        )
        sys.stdout.flush()
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        body = ROUTES.get(self.path.split("?", 1)[0])
        if body is None:
            return self.reply(404, '{"message": "404 Not Found"}')
        return self.reply(200, body)

    def do_POST(self):
        # glab posts usage events to the configured instance; accept nothing.
        return self.reply(404, '{"message": "404 Not Found"}')


HTTPServer(("0.0.0.0", 80), Handler).serve_forever()
PY
chmod -R a+rX "$work"

docker network create --internal "$network" >/dev/null
docker run -d --name "$api" --network "$network" --network-alias "$host" --read-only \
  -v "$work/api.py:/api.py:ro" "$python" python -u /api.py >/dev/null
attempts=0
until docker exec "$api" python -c \
  'import urllib.request; urllib.request.urlopen("http://127.0.0.1/api/v4/version")' \
  >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || { docker logs "$api" >&2; fail 'API fixture did not become ready'; }
  sleep 1
done
requests() {
  docker logs "$api" 2>&1
}

# glab api with an environment token against the default host. GLAB_API_PROTOCOL
# selects plain HTTP, so no TLS fixture is needed.
fixture() {
  docker run --rm --network "$network" --read-only \
    --tmpfs /home/nonroot:uid=65532,gid=65532,mode=0755 -e GLAB_API_PROTOCOL=http "$@"
}
fixture -e GITLAB_HOST="$host" -e GITLAB_TOKEN=glpat-verity-env "$image" \
  api projects/verity%2Fdemo >"$work/api" 2>"$work/api.err" ||
  fail "glab api failed: $(cat "$work/api.err")"
grep -F '"path_with_namespace": "verity/demo"' "$work/api" >/dev/null ||
  fail "glab api did not print the fixture project: $(cat "$work/api") $(cat "$work/api.err")"
grep -F '"web_url": "http://gitlab.fixture.test/verity/demo"' "$work/api" >/dev/null ||
  fail "glab api output is incomplete: $(cat "$work/api")"
requests | grep -Fx 'REQ GET /api/v4/projects/verity%2Fdemo private-token=glpat-verity-env authorization=-' \
  >/dev/null || fail "glab api did not send the token to the project path: $(requests)"

# glab withholds an environment token from a host that is neither the default
# nor configured.
fixture -e GITLAB_TOKEN=glpat-verity-leak "$image" api --hostname "$host" user \
  >"$work/leak" 2>&1 || fail "glab api --hostname failed: $(cat "$work/leak")"
grep -F 'glab did not send the credential' "$work/leak" >/dev/null ||
  fail "glab api --hostname did not warn about the withheld token: $(cat "$work/leak")"
grep -F '"username": "verity-bot"' "$work/leak" >/dev/null ||
  fail "glab api --hostname did not print the fixture user: $(cat "$work/leak")"
if requests | grep -F glpat-verity-leak >/dev/null; then
  fail "glab sent an environment token to an unconfigured host: $(requests)"
fi

# auth login validates and stores the token in the volume-backed config, and
# later containers authenticate from that file alone.
net() {
  home --network "$network" "$@"
}
net "$image" auth login --hostname "$host" --token glpat-verity-login \
  --api-protocol http --git-protocol https >"$work/login" 2>&1 ||
  fail "auth login failed: $(cat "$work/login")"
grep -F 'Logged in as verity-bot' "$work/login" >/dev/null ||
  fail "auth login did not report the fixture user: $(cat "$work/login")"
net "$image" auth status >"$work/status" 2>&1 || fail "auth status failed: $(cat "$work/status")"
grep -F "Logged in to $host as verity-bot" "$work/status" >/dev/null ||
  fail "auth status did not report the stored login: $(cat "$work/status")"
grep -F "REST API Endpoint: http://$host/api/v4/" "$work/status" >/dev/null ||
  fail "auth status did not report the fixture endpoint: $(cat "$work/status")"
requests | grep -Fx 'REQ GET /api/v4/user private-token=glpat-verity-login authorization=-' \
  >/dev/null || fail "auth did not send the stored token to /api/v4/user: $(requests)"

# glab resolves the project from the git remote of the working directory,
# which needs the git dependency in the image.
home --network none --entrypoint /usr/bin/git "$image" init -q /home/nonroot/demo ||
  fail 'git init failed'
home --network none -w /home/nonroot/demo --entrypoint /usr/bin/git "$image" \
  remote add origin "https://$host/verity/demo.git" || fail 'git remote add failed'
net -w /home/nonroot/demo "$image" issue list >"$work/issues" 2>&1 ||
  fail "issue list failed: $(cat "$work/issues")"
grep -F 'Showing 1 open issue in verity/demo' "$work/issues" >/dev/null ||
  fail "issue list did not resolve the git remote project: $(cat "$work/issues")"
grep -E '^#1[[:space:]]+verity fixture issue' "$work/issues" >/dev/null ||
  fail "issue list did not print the fixture issue: $(cat "$work/issues")"
requests | grep -E '^REQ GET /api/v4/projects/verity%2Fdemo/issues\?.*state=opened.* private-token=glpat-verity-login ' \
  >/dev/null || fail "issue list did not request the project issues: $(requests)"

printf 'SMOKE PASS\n'

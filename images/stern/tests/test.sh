#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - stern=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
python_index='docker.io/library/python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e'
api="verity-stern-api-$$"
network="verity-stern-network-$$"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$api" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned stern version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/stern"]' || fail 'unexpected entrypoint'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "version: v$version" "$work/version" >/dev/null ||
  fail "version does not report v$version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/flag" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/flag")"

rc=0
docker run --rm --network none "$image" >"$work/noquery" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'missing query unexpectedly succeeded'
grep -F 'One of pod-query, --selector, --field-selector, --prompt or --stdin is required' \
  "$work/noquery" >/dev/null || fail "missing query diagnostic is missing: $(cat "$work/noquery")"

docker run --rm --network none "$image" --completion bash >"$work/completion" 2>&1 ||
  fail 'bash completion failed'
grep -F '# bash completion for stern' "$work/completion" >/dev/null ||
  fail 'bash completion output is missing its header'

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

# A minimal Kubernetes API fixture: one running pod "web-0" with container
# "app" whose log endpoint returns two timestamped lines. It records every
# request path so the test can assert what stern asked for.
cat >"$work/api.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

POD = {
    "kind": "Pod",
    "apiVersion": "v1",
    "metadata": {
        "name": "web-0",
        "namespace": "default",
        "uid": "6f1f1d8e-1f0c-4f55-9a43-2d1f0c7a9b10",
        "resourceVersion": "1",
        "labels": {"app": "web"},
    },
    "spec": {"containers": [{"name": "app"}]},
    "status": {
        "phase": "Running",
        "containerStatuses": [
            {
                "name": "app",
                "ready": True,
                "containerID": "containerd://verity",
                "state": {"running": {}},
            }
        ],
    },
}
LOG = (
    "2026-11-13T10:00:00.000000000Z hello from verity\n"
    "2026-11-13T10:00:01.000000000Z second line\n"
)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        sys.stdout.write("REQ %s\n" % self.path)
        sys.stdout.flush()

    def reply(self, code, body, ctype="application/json"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path
        if path.startswith("/api/v1/namespaces/default/pods/web-0/log?"):
            return self.reply(200, LOG, "text/plain")
        if path.startswith("/api/v1/namespaces/default/pods"):
            if "watch=true" in path:
                return self.reply(200, json.dumps({"type": "ADDED", "object": POD}) + "\n")
            items = {"kind": "PodList", "apiVersion": "v1", "metadata": {"resourceVersion": "1"}, "items": [POD]}
            return self.reply(200, json.dumps(items))
        status = {"kind": "Status", "apiVersion": "v1", "status": "Failure", "code": 404}
        return self.reply(404, json.dumps(status))


HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY
cat >"$work/kubeconfig" <<'YAML'
apiVersion: v1
kind: Config
clusters:
  - name: fixture
    cluster:
      server: http://api:8080
contexts:
  - name: fixture
    context:
      cluster: fixture
      namespace: default
current-context: fixture
YAML
chmod -R a+rX "$work"

docker network create --internal "$network" >/dev/null
docker run -d --name "$api" --network "$network" --network-alias api --read-only \
  -v "$work/api.py:/api.py:ro" "$python" python -u /api.py >/dev/null
attempts=0
until docker exec "$api" python -c \
  'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/api/v1/namespaces/default/pods")' \
  >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || { docker logs "$api" >&2; fail 'API fixture did not become ready'; }
  sleep 1
done

docker run --rm --network "$network" --read-only -v "$work/kubeconfig:/kubeconfig:ro" \
  "$image" --kubeconfig /kubeconfig --no-follow --color never --output raw web \
  >"$work/raw" 2>"$work/raw.err" || fail "stern failed: $(cat "$work/raw.err")"
printf 'hello from verity\nsecond line\n' | cmp -s - "$work/raw" ||
  fail "unexpected raw log output: $(cat "$work/raw") $(cat "$work/raw.err")"

docker run --rm --network "$network" --read-only -v "$work/kubeconfig:/kubeconfig:ro" \
  "$image" --kubeconfig /kubeconfig --no-follow --color never \
  --template '{{.Namespace}}/{{.PodName}}/{{.ContainerName}}: {{.Message}}{{"\n"}}' web \
  >"$work/template" 2>"$work/template.err" || fail "stern template failed: $(cat "$work/template.err")"
grep -Fx 'default/web-0/app: hello from verity' "$work/template" >/dev/null ||
  fail "template output is missing the first line: $(cat "$work/template")"
grep -Fx 'default/web-0/app: second line' "$work/template" >/dev/null ||
  fail "template output is missing the second line: $(cat "$work/template")"

# A pod query that matches nothing prints no log lines.
docker run --rm --network "$network" --read-only -v "$work/kubeconfig:/kubeconfig:ro" \
  "$image" --kubeconfig /kubeconfig --no-follow --color never --output raw nomatch \
  >"$work/nomatch" 2>"$work/nomatch.err" || fail "stern nomatch failed: $(cat "$work/nomatch.err")"
test ! -s "$work/nomatch" || fail "unmatched query printed logs: $(cat "$work/nomatch")"

docker logs "$api" >"$work/requests" 2>&1
grep -F 'REQ /api/v1/namespaces/default/pods/web-0/log?container=app' "$work/requests" >/dev/null ||
  fail "stern did not request the app container log: $(cat "$work/requests")"

printf 'SMOKE PASS\n'

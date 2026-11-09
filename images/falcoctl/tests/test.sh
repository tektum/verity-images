#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
work=$(mktemp -d)
user=$(id -u):$(id -g)
server_pid=

cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ] ||
  fail 'unexpected image config: User'
[ "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/falcoctl"]' ] ||
  fail 'unexpected image config: Entrypoint'
[ "$(docker run --rm --network none "$image" version)" = \
  "Client Version: $expected_version" ] || fail "version output does not report $expected_version"
docker run --rm --network none "$image" version --output json >"$work/version.json" ||
  fail 'falcoctl version --output json failed'
grep -F '"gitCommit"' "$work/version.json" >/dev/null || fail 'version JSON has no gitCommit'

if docker run --rm --network none "$image" --verity-unknown-flag >"$work/unknown.log" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'unknown flag: --verity-unknown-flag' "$work/unknown.log" >/dev/null || {
  cat "$work/unknown.log" >&2
  fail 'unknown flag error is not readable'
}

# Serve a local artifact index and drive index add, list and artifact search.
mkdir "$work/index" "$work/home"
cat >"$work/index/index.yaml" <<'YAML'
- name: verity-smoke-rules
  type: rulesfile
  registry: registry.invalid
  repository: verity/smoke-rules
  description: Verity smoke test rules
  home: https://example.invalid/
  keywords:
    - veritysmoke
  license: Apache-2.0
  maintainers:
    - email: smoke@example.invalid
      name: Verity
  sources:
    - https://example.invalid/rules.yaml
YAML
cat >"$work/serve.py" <<'PY'
import functools
import os
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

handler = functools.partial(SimpleHTTPRequestHandler, directory=sys.argv[2])
server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
with open(sys.argv[1] + ".tmp", "w") as out:
    out.write(f"{server.server_port}\n")
os.replace(sys.argv[1] + ".tmp", sys.argv[1])
server.serve_forever()
PY
python3 "$work/serve.py" "$work/port" "$work/index" 2>/dev/null &
server_pid=$!
attempts=0
until [ -s "$work/port" ]; do
  kill -0 "$server_pid" 2>/dev/null || fail 'index server failed to start'
  attempts=$((attempts + 1))
  [ "$attempts" -lt 100 ] || fail 'index server did not report its port'
  sleep 0.1
done
port=$(cat "$work/port")

# The host user owns the mounted state so the trap can remove it.
falcoctl() {
  docker run --rm --network host --user "$user" -e HOME=/work -v "$work/home:/work" "$image" \
    --config /work/falcoctl.yaml --log-format text "$@"
}

falcoctl index add verity "http://127.0.0.1:$port/index.yaml" >"$work/add.log" 2>&1 || {
  cat "$work/add.log" >&2
  fail 'falcoctl index add failed'
}
falcoctl index list >"$work/list.log" 2>&1 || fail 'falcoctl index list failed'
grep -F "http://127.0.0.1:$port/index.yaml" "$work/list.log" >/dev/null || {
  cat "$work/list.log" >&2
  fail 'added index is not listed'
}
falcoctl artifact search veritysmoke >"$work/search.log" 2>&1 || {
  cat "$work/search.log" >&2
  fail 'falcoctl artifact search failed'
}
grep -F 'verity-smoke-rules' "$work/search.log" | grep -F rulesfile >/dev/null || {
  cat "$work/search.log" >&2
  fail 'artifact search did not return the indexed artifact'
}

if falcoctl index add missing "http://127.0.0.1:$port/missing.yaml" >"$work/missing.log" 2>&1; then
  fail 'adding a missing index unexpectedly succeeded'
fi
grep -F 'missing.yaml' "$work/missing.log" >/dev/null || {
  cat "$work/missing.log" >&2
  fail 'missing index error is not readable'
}

printf 'SMOKE PASS image=%s\n' "$image"

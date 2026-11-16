#!/bin/sh
set -eu

# The PDP runs with --network none and a read-only root filesystem. Policies
# come from a host directory bind-mounted read-only at /policies, the upstream
# default policy location. HTTP requests come from a pinned curl container that
# joins the PDP network namespace, so nothing leaves the host.

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
commit=$(sed -n 's/^  source-commit: \([0-9a-f]\{40\}\)$/\1/p' "$recipe")
probe_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
label="verity-test=cerbos-$$"
pdp=verity-cerbos-pdp-$$
bad=verity-cerbos-bad-$$
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the recipe version'
[ -n "$commit" ] || fail 'could not read the recipe source commit'

inspect() {
  docker image inspect --format "$1" "$image"
}

[ "$(inspect '{{.Config.User}}')" = 65532 ] || fail 'unexpected OCI user'
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/cerbos"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"
[ "$(inspect '{{json .Config.Cmd}}')" = '["server"]' ] ||
  fail "unexpected command: $(inspect '{{json .Config.Cmd}}')"
[ "$(inspect '{{.Config.WorkingDir}}')" = / ] || fail 'unexpected working directory'
inspect '{{range .Config.Env}}{{println .}}{{end}}' | grep -Fx 'CERBOS_CONFIG=__default__' >/dev/null ||
  fail 'CERBOS_CONFIG=__default__ is not set'

# --version prints the stamped release, then build details. stdout only:
# docker prints a platform mismatch warning on stderr for emulated arm64 runs.
docker run --rm --label "$label" --network none "$image" --version >"$work/version.txt" ||
  fail 'version failed'
[ "$(sed -n 1p "$work/version.txt")" = "$version" ] ||
  fail "version does not report $version: $(cat "$work/version.txt")"
grep -Fx "Build commit: $commit" "$work/version.txt" >/dev/null ||
  fail "version does not report commit $commit: $(cat "$work/version.txt")"

# Policies: users may view documents and edit the ones they own; only admins
# may delete. The directory must be readable by UID 65532.
mkdir -p "$work/policies" "$work/broken"
cat >"$work/policies/document.yaml" <<'EOF'
apiVersion: api.cerbos.dev/v1
resourcePolicy:
  version: default
  resource: document
  rules:
    - actions: [view]
      effect: EFFECT_ALLOW
      roles: [user, admin]
    - actions: [edit]
      effect: EFFECT_ALLOW
      roles: [user]
      condition:
        match:
          expr: request.resource.attr.owner == request.principal.id
    - actions: [delete]
      effect: EFFECT_ALLOW
      roles: [admin]
EOF
cat >"$work/broken/document.yaml" <<'EOF'
apiVersion: api.cerbos.dev/v1
resourcePolicy:
  version: default
  resource: document
  rules:
    - actions: [view]
      effect: EFFECT_ALLOW
      roles: [user]
      condition:
        match:
          expr: request.resource.attr.owner ==
EOF
chmod 0755 "$work" "$work/policies" "$work/broken"
chmod 0644 "$work/policies/document.yaml" "$work/broken/document.yaml"

# The bundled compiler accepts the valid policy and rejects the broken one.
docker run --rm --label "$label" --network none \
  -v "$work/policies:/policies:ro" "$image" compile /policies >"$work/compile.log" 2>&1 ||
  fail "compile rejected the valid policy: $(cat "$work/compile.log")"
status=0
docker run --rm --label "$label" --network none \
  -v "$work/broken:/policies:ro" "$image" compile /policies >"$work/compile-bad.log" 2>&1 ||
  status=$?
[ "$status" -ne 0 ] || fail "compile accepted a broken policy: $(cat "$work/compile-bad.log")"
grep -F 'document.yaml:11:11 Invalid expression' "$work/compile-bad.log" >/dev/null ||
  fail "compile did not report the broken expression: $(cat "$work/compile-bad.log")"

# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the probe by its own per-platform child digest.
# The index bytes are verified against the pinned digest before a child is
# chosen, which keeps the pin authoritative.
image_arch=$(inspect '{{.Architecture}}')
probe_raw=$(docker buildx imagetools inspect --raw "$probe_index") ||
  fail 'cannot inspect probe image index'
[ "sha256:$(printf '%s' "$probe_raw" | sha256sum | cut -d' ' -f1)" = "${probe_index#*@}" ] ||
  fail 'probe image index digest mismatch'
probe_digest=$(printf '%s' "$probe_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve probe image digest'
case $probe_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch probe image in $probe_index" ;;
esac
probe=docker.io/curlimages/curl@$probe_digest
docker pull --quiet --platform "linux/$image_arch" "$probe" >/dev/null ||
  fail 'cannot pull probe image'

running() {
  [ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" = true ]
}

# curl_pdp ARGS...: run curl in the PDP network namespace.
curl_pdp() {
  docker run --rm --label "$label" --network "container:$pdp" "$probe" "$@"
}

# The default command is "server" with the default configuration: HTTP on
# 3592, gRPC on 3593, disk policies from /policies.
docker run -d --name "$pdp" --label "$label" --network none --read-only \
  -v "$work/policies:/policies:ro" "$image" >/dev/null ||
  fail 'cannot start the PDP'

i=0
until body=$(curl_pdp -fsS -m 5 http://127.0.0.1:3592/_cerbos/health 2>/dev/null); do
  running "$pdp" || { docker logs "$pdp" >&2; fail 'the PDP exited before becoming healthy'; }
  i=$((i + 1))
  [ "$i" -lt 60 ] || { docker logs "$pdp" >&2; fail 'the PDP never answered /_cerbos/health'; }
  sleep 1
done
[ "$(printf '%s' "$body" | jq -r .status)" = SERVING ] ||
  fail "unexpected health response: $body"

# The upstream Docker HEALTHCHECK command checks the gRPC health service.
docker exec "$pdp" /usr/bin/cerbos healthcheck >"$work/healthcheck.log" 2>&1 ||
  fail "cerbos healthcheck failed: $(cat "$work/healthcheck.log")"

# The default configuration loads the read-only mount, and the build leaves
# the upstream telemetry key empty.
for line in 'Initializing disk store from /policies' 'Found 1 executable policies' \
  'Watching directory for changes' 'Telemetry disabled'; do
  docker logs "$pdp" 2>&1 | grep -F "$line" >/dev/null ||
    fail "the PDP did not log '$line': $(docker logs "$pdp" 2>&1)"
done

# check PRINCIPAL ROLE OWNER: print the action effects for document doc-1.
check() {
  request=$(jq -cn --arg principal "$1" --arg role "$2" --arg owner "$3" '{
    requestId: "verity-smoke",
    principal: {id: $principal, roles: [$role]},
    resources: [{
      actions: ["view", "edit", "delete"],
      resource: {kind: "document", id: "doc-1", attr: {owner: $owner}}
    }]
  }')
  response=$(curl_pdp -fsS -m 10 -H 'Content-Type: application/json' \
    --data "$request" http://127.0.0.1:3592/api/check/resources) ||
    fail "/api/check/resources failed for $1: $(docker logs "$pdp" 2>&1)"
  printf '%s' "$response" | jq -er '
    select(.requestId == "verity-smoke")
    | .results
    | select(length == 1)
    | .[0]
    | select(.resource.id == "doc-1" and .resource.kind == "document")
    | .actions
    | "view=\(.view) edit=\(.edit) delete=\(.delete)"' ||
    fail "unexpected check response for $1: $response"
}

# expect PRINCIPAL ROLE OWNER EFFECTS
expect() {
  got=$(check "$1" "$2" "$3")
  [ "$got" = "$4" ] || fail "$1 ($2) on a document owned by $3: expected $4, got $got"
}

expect alice user alice 'view=EFFECT_ALLOW edit=EFFECT_ALLOW delete=EFFECT_DENY'
expect alice user bob 'view=EFFECT_ALLOW edit=EFFECT_DENY delete=EFFECT_DENY'
expect carol admin bob 'view=EFFECT_ALLOW edit=EFFECT_DENY delete=EFFECT_ALLOW'
expect mallory guest mallory 'view=EFFECT_DENY edit=EFFECT_DENY delete=EFFECT_DENY'

# A malformed request is rejected with a client error, not a decision.
code=$(curl_pdp -sS -m 10 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  --data '{"requestId":"verity-smoke","resources":[]}' \
  http://127.0.0.1:3592/api/check/resources) || fail 'invalid check request did not complete'
[ "$code" = 400 ] || fail "invalid check request returned HTTP $code, expected 400"

# SIGTERM from docker stop shuts the server down cleanly.
docker stop --time 20 "$pdp" >/dev/null || fail 'cannot stop the PDP'
exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$pdp")
[ "$exit_code" = 0 ] || { docker logs "$pdp" >&2; fail "the PDP exited $exit_code on SIGTERM"; }
docker logs "$pdp" 2>&1 | grep -F 'Shutdown complete' >/dev/null ||
  { docker logs "$pdp" >&2; fail 'the PDP did not log a graceful shutdown'; }

# A broken policy store keeps the server from starting.
docker run -d --name "$bad" --label "$label" --network none --read-only \
  -v "$work/broken:/policies:ro" "$image" >/dev/null ||
  fail 'cannot start the PDP with a broken store'
i=0
while running "$bad"; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || { docker logs "$bad" >&2; fail 'the PDP kept running with a broken policy'; }
  sleep 1
done
exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$bad")
[ "$exit_code" != 0 ] || fail 'the PDP exited 0 with a broken policy'
docker logs "$bad" 2>&1 | grep -F 'document.yaml:11:11: Invalid expression' >/dev/null ||
  fail "the PDP did not report the broken expression: $(docker logs "$bad" 2>&1)"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
label=verity.test=harbor-registryctl-$$
ctl="verity-harbor-registryctl-$$"
work=$(mktemp -d)
secret=registryctl-smoke-secret

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# OCI contract: upstream goharbor/harbor-registryctl runs as harbor (10000),
# reads /etc/registryctl/config.yml, and stores blobs under /var/lib/registry.
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 10000 ] ||
  fail 'image must run as UID 10000'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = \
  '["/home/harbor/harbor_registryctl","-c","/etc/registryctl/config.yml"]' ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = / ] ||
  fail 'unexpected working directory'

# Upstream prepare output for a filesystem-backed registry without internal TLS.
mkdir -p "$work/registryctl" "$work/registry"
cat >"$work/registryctl/config.yml" <<'EOF'
---
protocol: "http"
port: 8080
log_level: info
registry_config: "/etc/registry/config.yml"
EOF
cat >"$work/registry/config.yml" <<'EOF'
version: 0.1
log:
  level: info
storage:
  filesystem:
    rootdirectory: /storage
  delete:
    enabled: true
  maintenance:
    uploadpurging:
      enabled: false
http:
  addr: :5000
EOF
chmod -R a+rX "$work/registryctl" "$work/registry"

# One blob in the distribution filesystem layout.
blob_hex=$(printf 'verity harbor registryctl smoke blob\n' | sha256sum | cut -d' ' -f1)
blob_dir="$work/storage/docker/registry/v2/blobs/sha256/$(printf '%s' "$blob_hex" | cut -c1-2)/$blob_hex"
mkdir -p "$blob_dir"
printf 'verity harbor registryctl smoke blob\n' >"$blob_dir/data"
chmod -R a+rwX "$work/storage"

docker run -d --label "$label" --name "$ctl" --read-only \
  -e JOBSERVICE_SECRET="$secret" -e CORE_SECRET="$secret" \
  -v "$work/registryctl:/etc/registryctl:ro" -v "$work/registry:/etc/registry:ro" \
  -v "$work/storage:/storage" -p 127.0.0.1::8080 "$image" >/dev/null
port=$(docker port "$ctl" 8080/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$port" ] || fail 'registryctl port is not published'

attempts=0
until curl --fail --silent --max-time 5 "http://127.0.0.1:$port/api/health" >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || { docker logs "$ctl" >&2; fail 'registryctl did not answer /api/health'; }
  [ "$(docker inspect -f '{{.State.Running}}' "$ctl")" = true ] || {
    docker logs "$ctl" >&2
    fail 'registryctl exited'
  }
  sleep 1
done

# Negative: protected APIs reject requests without the job service secret.
code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
  -X DELETE "http://127.0.0.1:$port/api/registry/blob/sha256:$blob_hex")
[ "$code" = 401 ] || fail "unauthenticated blob delete returned $code, expected 401"
code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
  -H 'Authorization: Harbor-Secret wrong-secret' \
  -X DELETE "http://127.0.0.1:$port/api/registry/blob/sha256:$blob_hex")
[ "$code" = 401 ] || fail "blob delete with a wrong secret returned $code, expected 401"
[ -f "$blob_dir/data" ] || fail 'a rejected request deleted the blob'

# The authorized delete removes the blob through the storage driver.
code=$(curl --silent --output "$work/delete.out" --write-out '%{http_code}' --max-time 10 \
  -H "Authorization: Harbor-Secret $secret" \
  -X DELETE "http://127.0.0.1:$port/api/registry/blob/sha256:$blob_hex")
[ "$code" = 200 ] || {
  cat "$work/delete.out" >&2
  docker logs "$ctl" >&2
  fail "authorized blob delete returned $code, expected 200"
}
[ ! -e "$blob_dir/data" ] || fail 'authorized blob delete left the blob in storage'

# Graceful stop on SIGTERM. Upstream drains the server, logs the line below,
# then passes http.ErrServerClosed to log.Fatal, so a clean stop exits 1; a
# SIGKILL after the timeout would exit 137 without the line.
docker stop -t 20 "$ctl" >/dev/null
docker logs "$ctl" >"$work/ctl.log" 2>&1
code=$(docker inspect -f '{{.State.ExitCode}}' "$ctl")
if ! grep -F 'Registry controller is shut down properly' "$work/ctl.log" >/dev/null ||
  [ "$code" != 1 ]; then
  cat "$work/ctl.log" >&2
  fail "registryctl did not stop gracefully on SIGTERM (exit $code)"
fi

# Negative: a missing registry configuration fails startup.
if docker run --rm --label "$label" --read-only \
  -v "$work/registryctl:/etc/registryctl:ro" "$image" >"$work/bad.log" 2>&1; then
  fail 'registryctl started without a registry configuration'
fi
grep -Ei 'registry/config.yml|no such file' "$work/bad.log" >/dev/null || {
  cat "$work/bad.log" >&2
  fail 'missing registry configuration was not reported'
}

printf 'SMOKE PASS image=%s\n' "$image"

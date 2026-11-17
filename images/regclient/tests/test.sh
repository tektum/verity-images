#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# The registry helper comes from this repository and is pinned by index digest;
# it is resolved to its per-platform child below. The registry and every
# regclient run share an internal Docker network with no external route.
registry_index='ghcr.io/tektum/registry@sha256:38539bc58065aa1634bde5ec90bf58963cc070ca26ae2ef72e286c3b37455fd7'
label=verity.test=regclient-$$
network="verity-regclient-network-$$"
registry="verity-regclient-registry-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$registry" >&2 2>/dev/null || true
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

sha() {
  sha256sum "$1" | cut -d' ' -f1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# OCI contract: upstream release-scratch runs as appuser 1000:1000 with HOME
# /home/appuser and ENTRYPOINT /regctl; this image keeps /usr/bin/regctl as the
# entrypoint and /regctl, /regsync and /regbot as compatibility paths.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/regctl"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" \
  >"$work/env"
grep -Fx 'HOME=/home/appuser' "$work/env" >/dev/null || fail 'HOME is not /home/appuser'
grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' "$work/env" >/dev/null ||
  fail 'CA bundle environment is missing'

offline() {
  docker run --rm --network none --read-only --cap-drop ALL "$@"
}

for cmd in regctl regsync regbot; do
  tag=$(offline --entrypoint "/$cmd" "$image" version --format '{{.VCSTag}}') ||
    fail "/$cmd version failed"
  [ "$tag" = "v$expected_version" ] ||
    fail "/$cmd reports version '$tag', expected 'v$expected_version'"
done
tag=$(offline "$image" version --format '{{.VCSTag}}') || fail 'regctl version failed'
[ "$tag" = "v$expected_version" ] || fail "entrypoint reports version '$tag'"

if offline "$image" --definitely-invalid >"$work/invalid" 2>&1; then
  fail 'invalid flag unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Home layout: the image's own ~/.regctl is writable by the runtime user, so
# `regctl registry set` can persist its config without any mount.
docker run --rm --network none --cap-drop ALL "$image" \
  registry set example.invalid --tls disabled --skip-check >"$work/home.log" 2>&1 ||
  fail "regctl cannot write its config under /home/appuser: $(cat "$work/home.log")"

# Resolve the pinned index to its child for this image's platform, verifying the
# index bytes against the pin first so the pin stays authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
raw=$(docker buildx imagetools inspect --raw "$registry_index") ||
  fail "cannot inspect $registry_index"
[ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${registry_index#*@}" ] ||
  fail "index digest mismatch for $registry_index"
child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
  [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
  | if length == 1 then .[0] else empty end') || fail 'cannot resolve the registry child'
case $child in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch child in $registry_index" ;;
esac
registry_image="${registry_index%%@*}@$child"
docker pull --quiet --platform "linux/$image_arch" "$registry_image" >/dev/null ||
  fail "cannot pull $registry_image"

docker network create --internal --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$registry" --network "$network" \
  --network-alias registry -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  "$registry_image" >/dev/null

# Build a single-platform OCI layout by hand so the pushed bytes are known.
layout="$work/data/layout"
mkdir -p "$work/layer" "$layout/blobs/sha256" "$work/state"
printf 'verity regclient smoke\n' >"$work/layer/hello.txt"
tar -C "$work/layer" --owner=0 --group=0 --numeric-owner --mtime=@0 \
  -cf "$work/layer.tar" hello.txt
diff_id=$(sha "$work/layer.tar")
gzip -n -c "$work/layer.tar" >"$work/layer.tar.gz"
layer_digest=$(sha "$work/layer.tar.gz")
layer_size=$(wc -c <"$work/layer.tar.gz" | tr -d ' ')
cp "$work/layer.tar.gz" "$layout/blobs/sha256/$layer_digest"
printf '{"architecture":"%s","os":"linux","config":{},"rootfs":{"type":"layers","diff_ids":["sha256:%s"]}}' \
  "$image_arch" "$diff_id" >"$work/config.json"
config_digest=$(sha "$work/config.json")
config_size=$(wc -c <"$work/config.json" | tr -d ' ')
cp "$work/config.json" "$layout/blobs/sha256/$config_digest"
printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%s","size":%s},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":"sha256:%s","size":%s}]}' \
  "$config_digest" "$config_size" "$layer_digest" "$layer_size" >"$work/manifest.json"
manifest_digest="sha256:$(sha "$work/manifest.json")"
manifest_size=$(wc -c <"$work/manifest.json" | tr -d ' ')
cp "$work/manifest.json" "$layout/blobs/sha256/${manifest_digest#sha256:}"
printf '{"imageLayoutVersion":"1.0.0"}' >"$layout/oci-layout"
printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","size":%s,"annotations":{"org.opencontainers.image.ref.name":"v1"}}]}' \
  "$manifest_digest" "$manifest_size" >"$layout/index.json"
tar -C "$layout" -cf "$work/data/hello.tar" oci-layout index.json blobs
printf 'verity regclient artifact payload\n' >"$work/data/payload.txt"
cat >"$work/data/regsync.yml" <<'EOF'
version: 1
creds:
  - registry: registry:5000
    tls: disabled
sync:
  - source: registry:5000/smoke/hello
    target: registry:5000/mirror/hello
    type: repository
EOF
cat >"$work/data/regbot.yml" <<'EOF'
version: 1
creds:
  - registry: registry:5000
    tls: disabled
scripts:
  - name: copy-v1
    script: |
      image.copy("registry:5000/smoke/hello:v1", "registry:5000/bot/hello:v1")
      for _, t in pairs(tag.ls("registry:5000/bot/hello")) do
        log("regbot-tag " .. t)
      end
EOF
chmod -R a+rX "$work/data"
# ~/.regctl is a writable mount so `regctl registry set` persists between runs
# while the image root stays read-only. regctl writes config.json mode 0600 as
# UID 1000, so the test reads it back through regctl, never from the host.
chmod 0777 "$work/state"

rc() {
  docker run --rm --label "$label" --network "$network" --read-only --cap-drop ALL \
    -v "$work/state:/home/appuser/.regctl" -v "$work/data:/data:ro" "$image" "$@"
}

# Negative: with the default TLS setting regctl refuses the plain HTTP registry.
attempts=0
until rc tag ls registry:5000/smoke/hello >"$work/tls.log" 2>&1 ||
  grep -F 'HTTP response to HTTPS client' "$work/tls.log" >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail "registry did not become ready: $(cat "$work/tls.log")"
  sleep 1
done
grep -F 'HTTP response to HTTPS client' "$work/tls.log" >/dev/null ||
  fail "default TLS unexpectedly reached the plain HTTP registry: $(cat "$work/tls.log")"

rc registry set registry:5000 --tls disabled >"$work/set.log" 2>&1 ||
  fail "regctl registry set failed: $(cat "$work/set.log")"
rc registry config registry:5000 >"$work/hostcfg.json" 2>&1 ||
  fail "regctl registry config failed: $(cat "$work/hostcfg.json")"
jq -e '.tls == "disabled" and .hostname == "registry:5000"' "$work/hostcfg.json" >/dev/null ||
  fail "registry config was not persisted: $(cat "$work/hostcfg.json")"

rc image import registry:5000/smoke/hello:v1 /data/hello.tar >"$work/import.log" 2>&1 ||
  fail "regctl image import failed: $(cat "$work/import.log")"

rc tag ls registry:5000/smoke/hello >"$work/tags" || fail 'regctl tag ls failed'
[ "$(cat "$work/tags")" = v1 ] || fail "unexpected tags after import: $(cat "$work/tags")"

rc manifest get --format raw-body registry:5000/smoke/hello:v1 >"$work/remote-manifest.json" ||
  fail 'regctl manifest get failed'
cmp "$work/manifest.json" "$work/remote-manifest.json" ||
  fail 'remote manifest bytes differ from the imported layout'
remote_digest=$(rc image digest registry:5000/smoke/hello:v1) || fail 'regctl image digest failed'
[ "$remote_digest" = "$manifest_digest" ] ||
  fail "remote digest $remote_digest does not match $manifest_digest"

rc image copy registry:5000/smoke/hello:v1 registry:5000/smoke/hello:v2 \
  >"$work/copy.log" 2>&1 || fail "regctl image copy failed: $(cat "$work/copy.log")"
rc tag ls registry:5000/smoke/hello >"$work/tags" || fail 'regctl tag ls failed'
[ "$(sort "$work/tags" | tr '\n' ' ')" = 'v1 v2 ' ] ||
  fail "unexpected tags after copy: $(cat "$work/tags")"
[ "$(rc image digest registry:5000/smoke/hello:v2)" = "$manifest_digest" ] ||
  fail 'copied tag does not resolve to the imported digest'

rc blob get registry:5000/smoke/hello "sha256:$layer_digest" >"$work/layer.out" ||
  fail 'regctl blob get failed'
cmp "$work/layer.tar.gz" "$work/layer.out" || fail 'fetched layer blob differs'
rc blob get registry:5000/smoke/hello "sha256:$config_digest" >"$work/config.out" ||
  fail 'regctl blob get of the config failed'
[ "$(sha "$work/config.out")" = "$config_digest" ] || fail 'fetched config digest differs'

rc artifact put --artifact-type application/vnd.verity.smoke \
  --annotation org.opencontainers.image.title=verity-regclient-smoke \
  -f /data/payload.txt -m text/plain registry:5000/smoke/artifact:v1 \
  >"$work/put.log" 2>&1 || fail "regctl artifact put failed: $(cat "$work/put.log")"
rc manifest get --format raw-body registry:5000/smoke/artifact:v1 >"$work/artifact.json" ||
  fail 'regctl manifest get of the artifact failed'
jq -e '.artifactType == "application/vnd.verity.smoke"
  and .annotations["org.opencontainers.image.title"] == "verity-regclient-smoke"
  and ([.layers[].mediaType] == ["text/plain"])' "$work/artifact.json" >/dev/null ||
  fail "unexpected artifact manifest: $(cat "$work/artifact.json")"
rc artifact get registry:5000/smoke/artifact:v1 >"$work/payload.out" ||
  fail 'regctl artifact get failed'
cmp "$work/data/payload.txt" "$work/payload.out" || fail 'artifact payload differs'

# regsync once: mirror the whole repository and compare digests per tag.
docker run --rm --label "$label" --network "$network" --read-only --cap-drop ALL \
  -v "$work/data:/data:ro" --entrypoint /regsync "$image" once -c /data/regsync.yml \
  >"$work/regsync.log" 2>&1 || fail "regsync once failed: $(cat "$work/regsync.log")"
rc tag ls registry:5000/mirror/hello >"$work/mirror-tags" || fail 'mirror tag ls failed'
[ "$(sort "$work/mirror-tags" | tr '\n' ' ')" = 'v1 v2 ' ] ||
  fail "unexpected mirrored tags: $(cat "$work/mirror-tags")"
for t in v1 v2; do
  [ "$(rc image digest "registry:5000/mirror/hello:$t")" = "$manifest_digest" ] ||
    fail "mirrored $t digest differs from the source"
done

# regbot once: a Lua script copies an image and lists the target tags.
docker run --rm --label "$label" --network "$network" --read-only --cap-drop ALL \
  -v "$work/data:/data:ro" --entrypoint /regbot "$image" once -c /data/regbot.yml \
  >"$work/regbot.log" 2>&1 || fail "regbot once failed: $(cat "$work/regbot.log")"
grep -F 'regbot-tag v1' "$work/regbot.log" >/dev/null ||
  fail "regbot did not log the copied tag: $(cat "$work/regbot.log")"
[ "$(rc image digest registry:5000/bot/hello:v1)" = "$manifest_digest" ] ||
  fail 'regbot copy digest differs from the source'

# Delete: removing tag v2 keeps v1 and its digest; deleting the artifact
# manifest makes it unresolvable.
rc tag delete registry:5000/smoke/hello:v2 >"$work/tagdel.log" 2>&1 ||
  fail "regctl tag delete failed: $(cat "$work/tagdel.log")"
rc tag ls registry:5000/smoke/hello >"$work/tags" || fail 'regctl tag ls failed'
[ "$(cat "$work/tags")" = v1 ] || fail "unexpected tags after delete: $(cat "$work/tags")"
[ "$(rc image digest registry:5000/smoke/hello:v1)" = "$manifest_digest" ] ||
  fail 'tag delete changed the remaining tag'
artifact_digest=$(rc image digest registry:5000/smoke/artifact:v1) ||
  fail 'regctl image digest of the artifact failed'
rc manifest delete "registry:5000/smoke/artifact@$artifact_digest" >"$work/mdel.log" 2>&1 ||
  fail "regctl manifest delete failed: $(cat "$work/mdel.log")"
if rc manifest get "registry:5000/smoke/artifact@$artifact_digest" >"$work/gone" 2>&1; then
  fail 'deleted artifact manifest is still served'
fi
grep -iE 'not found|unknown' "$work/gone" >/dev/null ||
  fail "deleted manifest diagnostic is missing: $(cat "$work/gone")"

# Negative: a tag that was never pushed is reported as not found.
if rc manifest get registry:5000/smoke/hello:missing >"$work/missing" 2>&1; then
  fail 'manifest get of a missing tag unexpectedly succeeded'
fi
grep -iE 'not found|unknown' "$work/missing" >/dev/null ||
  fail "missing tag diagnostic is missing: $(cat "$work/missing")"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"

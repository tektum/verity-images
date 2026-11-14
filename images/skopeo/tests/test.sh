#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# The repository registry image is both the push target and, saved with
# `docker save`, the image skopeo copies. The pinned index is resolved per
# platform. The registry and skopeo share an internal Docker network with no
# route to any external registry, so every copy can only reach local fixtures.
registry_index='ghcr.io/tektum/registry@sha256:38539bc58065aa1634bde5ec90bf58963cc070ca26ae2ef72e286c3b37455fd7'
label=verity.test=skopeo-$$
network="verity-skopeo-network-$$"
registry="verity-skopeo-registry-$$"
probe="verity-skopeo-probe-$$"
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

recipe="$here/../melange.yaml"
expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "$recipe")
expected_commit=$(awk '$1 == "expected-commit:" { print $2; exit }' "$recipe")
[ -n "$expected_version" ] || fail 'could not read the recipe version'
printf '%s\n' "$expected_commit" | grep -Ex '[0-9a-f]{40}' >/dev/null ||
  fail 'could not read the recipe expected-commit'

# --- OCI configuration -------------------------------------------------------
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/skopeo"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" \
  >"$work/env"
grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' "$work/env" >/dev/null ||
  fail 'CA bundle environment is missing'
grep -Fx 'HOME=/home/nonroot' "$work/env" >/dev/null || fail 'HOME is not /home/nonroot'

# --- Shipped signature policy and registries.d (upstream `make install`) -----
# The image has no shell, so read the files out of a created container.
docker create --label "$label" --name "$probe" "$image" >/dev/null ||
  fail 'cannot create a probe container'
docker cp "$probe:/etc/containers/policy.json" "$work/policy.json" ||
  fail 'default policy /etc/containers/policy.json is missing'
docker cp "$probe:/etc/containers/registries.d/default.yaml" "$work/registries.yaml" ||
  fail 'default registries.d/default.yaml is missing'
docker cp "$probe:/etc/ssl/certs/ca-certificates.crt" "$work/ca.crt" ||
  fail 'CA bundle is missing'
docker rm -f "$probe" >/dev/null
[ "$(jq -c '.default' "$work/policy.json")" = '[{"type":"insecureAcceptAnything"}]' ] ||
  fail 'default policy is not the upstream insecureAcceptAnything default'
[ "$(jq -c '.transports["docker-daemon"][""]' "$work/policy.json")" = \
  '[{"type":"insecureAcceptAnything"}]' ] ||
  fail 'default policy is missing the upstream docker-daemon transport scope'
grep -Fx 'default-docker:' "$work/registries.yaml" >/dev/null ||
  fail 'registries.d/default.yaml is not the upstream default'
grep -F 'BEGIN CERTIFICATE' "$work/ca.crt" >/dev/null || fail 'CA bundle is empty'

# --- Version and CLI errors (no network) -------------------------------------
version=$(docker run --rm --network none --read-only "$image" --version) ||
  fail 'skopeo --version failed'
[ "$version" = "skopeo version $expected_version commit: $expected_commit" ] ||
  fail "skopeo --version is '$version', expected $expected_version at $expected_commit"

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'unknown flag diagnostic is missing'

# --- Local registry ----------------------------------------------------------
# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
pull_child() {
  raw=$(docker buildx imagetools inspect --raw "$1") || fail "cannot inspect $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] ||
    fail "index digest mismatch for $1"
  child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail "cannot resolve a child of $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $1" ;;
  esac
  docker pull --quiet --platform "linux/$image_arch" "${1%%@*}@$child" >/dev/null ||
    fail "cannot pull ${1%%@*}@$child"
  printf '%s' "${1%%@*}@$child"
}
registry_image=$(pull_child "$registry_index")

docker network create --internal --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$registry" --network "$network" \
  --network-alias registry -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  "$registry_image" >/dev/null

mkdir -p "$work/data"
docker save "$registry_image" -o "$work/data/source.tar" ||
  fail 'docker save of the pinned registry image failed'
cat >"$work/data/reject.json" <<'EOF'
{"default": [{"type": "reject"}]}
EOF
chmod -R a+rX "$work"

# Run as the invoking user so files skopeo writes under /work stay removable.
skopeo() {
  docker run --rm --label "$label" --network "$network" --read-only \
    --tmpfs /tmp --tmpfs /var/tmp --user "$(id -u):$(id -g)" \
    -v "$work/data:/work" "$image" "$@"
}

attempts=0
until skopeo list-tags --tls-verify=false docker://registry:5000/smoke/absent \
  >"$work/ready" 2>&1 || grep -Ei 'name unknown|not known to registry' "$work/ready" >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || { cat "$work/ready" >&2; fail 'registry did not become ready'; }
  sleep 1
done

repo=registry:5000/smoke/app

# docker-archive -> registry
skopeo copy --quiet --dest-tls-verify=false --digestfile /work/v1.digest \
  docker-archive:/work/source.tar "docker://$repo:v1" 2>"$work/copy-v1.log" || {
  cat "$work/copy-v1.log" >&2
  fail 'copy from docker-archive to the local registry failed'
}
pushed=$(cat "$work/data/v1.digest")
printf '%s\n' "$pushed" | grep -Ex 'sha256:[0-9a-f]{64}' >/dev/null ||
  fail "digestfile does not hold a digest: $pushed"

# inspect: digest, platform, raw manifest bytes
skopeo inspect --tls-verify=false "docker://$repo:v1" >"$work/inspect-v1.json" ||
  fail 'inspect of v1 failed'
[ "$(jq -r .Digest "$work/inspect-v1.json")" = "$pushed" ] ||
  fail 'inspect digest does not match the pushed digest'
[ "$(jq -r .Architecture "$work/inspect-v1.json")" = "$image_arch" ] ||
  fail "inspect architecture is not $image_arch"
[ "$(jq -r .Os "$work/inspect-v1.json")" = linux ] || fail 'inspect OS is not linux'
[ "$(jq -r .Name "$work/inspect-v1.json")" = "$repo" ] || fail 'inspect name is wrong'
skopeo inspect --raw --tls-verify=false "docker://$repo:v1" >"$work/raw-v1.json" ||
  fail 'raw inspect of v1 failed'
[ "sha256:$(sha256sum "$work/raw-v1.json" | cut -d' ' -f1)" = "$pushed" ] ||
  fail 'raw manifest bytes do not hash to the pushed digest'
source_layers=$(tar -xOf "$work/data/source.tar" manifest.json | jq '.[0].Layers | length')
[ "$(jq '.layers | length' "$work/raw-v1.json")" = "$source_layers" ] ||
  fail 'pushed manifest layer count differs from the docker-archive'
[ "$(jq '.LayersData | length' "$work/inspect-v1.json")" = "$source_layers" ] ||
  fail 'inspect layer count differs from the docker-archive'

# registry -> registry tag copy, list-tags
skopeo copy --quiet --src-tls-verify=false --dest-tls-verify=false \
  "docker://$repo:v1" "docker://$repo:v2" 2>"$work/copy-v2.log" || {
  cat "$work/copy-v2.log" >&2
  fail 'copy between tags failed'
}
skopeo list-tags --tls-verify=false "docker://$repo" >"$work/tags.json" ||
  fail 'list-tags failed'
[ "$(jq -c '.Tags | sort' "$work/tags.json")" = '["v1","v2"]' ] ||
  fail "list-tags returned $(jq -c .Tags "$work/tags.json"), expected v1 and v2"
[ "$(jq -r .Repository "$work/tags.json")" = "$repo" ] || fail 'list-tags repository is wrong'
[ "$(skopeo inspect --tls-verify=false --format '{{.Digest}}' "docker://$repo:v2")" = "$pushed" ] ||
  fail 'v2 does not resolve to the v1 digest'

# registry -> oci layout; every blob must hash to its name
skopeo copy --quiet --src-tls-verify=false "docker://$repo:v2" oci:/work/layout:v2 \
  2>"$work/copy-oci.log" || {
  cat "$work/copy-oci.log" >&2
  fail 'copy to an oci layout failed'
}
layout="$work/data/layout"
[ "$(jq -r .imageLayoutVersion "$layout/oci-layout")" = 1.0.0 ] || fail 'oci-layout marker is wrong'
oci_manifest=$(jq -r '.manifests[] | select(.annotations["org.opencontainers.image.ref.name"] == "v2") | .digest' \
  "$layout/index.json")
printf '%s\n' "$oci_manifest" | grep -Ex 'sha256:[0-9a-f]{64}' >/dev/null ||
  fail 'oci index has no manifest for ref v2'
blobs=0
for blob in "$layout"/blobs/sha256/*; do
  [ "$(sha256sum "$blob" | cut -d' ' -f1)" = "${blob##*/}" ] ||
    fail "oci blob ${blob##*/} does not match its digest"
  blobs=$((blobs + 1))
done
oci_manifest_file="$layout/blobs/sha256/${oci_manifest#sha256:}"
[ -s "$oci_manifest_file" ] || fail 'oci manifest blob is missing'
[ "$blobs" -eq "$((source_layers + 2))" ] ||
  fail "oci layout holds $blobs blobs, expected $source_layers layers plus config and manifest"
[ "$(jq -c '[.layers[].digest]' "$oci_manifest_file")" = "$(jq -c '[.layers[].digest]' "$work/raw-v1.json")" ] ||
  fail 'oci layout layers differ from the registry manifest layers'

# registry -> dir; manifest bytes are preserved verbatim
skopeo copy --quiet --src-tls-verify=false "docker://$repo:v1" dir:/work/dir \
  2>"$work/copy-dir.log" || {
  cat "$work/copy-dir.log" >&2
  fail 'copy to a dir destination failed'
}
[ "sha256:$(sha256sum "$work/data/dir/manifest.json" | cut -d' ' -f1)" = "$pushed" ] ||
  fail 'dir manifest does not hash to the pushed digest'

# missing tag
if skopeo inspect --tls-verify=false "docker://$repo:missing" >"$work/missing" 2>&1; then
  fail 'inspect of a missing tag unexpectedly succeeded'
fi
grep -Fi 'manifest unknown' "$work/missing" >/dev/null || {
  cat "$work/missing" >&2
  fail 'missing tag diagnostic is missing'
}

# signature policy rejection
if skopeo --policy /work/reject.json copy --src-tls-verify=false --dest-tls-verify=false \
  "docker://$repo:v1" "docker://$repo:rejected" >"$work/rejected" 2>&1; then
  fail 'copy under a reject policy unexpectedly succeeded'
fi
grep -F 'rejected by policy' "$work/rejected" >/dev/null || {
  cat "$work/rejected" >&2
  fail 'policy rejection diagnostic is missing'
}
skopeo list-tags --tls-verify=false "docker://$repo" >"$work/tags-after-reject.json" ||
  fail 'list-tags after the rejected copy failed'
if jq -e '.Tags | index("rejected")' "$work/tags-after-reject.json" >/dev/null; then
  fail 'rejected copy still created its tag'
fi

# delete (the registry runs with storage deletes enabled); v1 and v2 share the
# manifest, so deleting it by tag removes both.
skopeo delete --tls-verify=false "docker://$repo:v2" 2>"$work/delete.log" || {
  cat "$work/delete.log" >&2
  fail 'delete failed'
}
for tag in v1 v2; do
  if skopeo inspect --tls-verify=false "docker://$repo:$tag" >"$work/deleted" 2>&1; then
    fail "$tag still resolves after delete"
  fi
  grep -Fi 'manifest unknown' "$work/deleted" >/dev/null || {
    cat "$work/deleted" >&2
    fail "$tag lookup after delete did not report manifest unknown"
  }
done

printf 'SMOKE PASS image=%s version=%s arch=%s digest=%s\n' \
  "$image" "$expected_version" "$image_arch" "$pushed"

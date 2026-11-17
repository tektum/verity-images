#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml" | head -n 1)
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
# The repository registry image is the module push and pull target; the pinned index is resolved per platform.
registry_index='ghcr.io/tektum/registry@sha256:38539bc58065aa1634bde5ec90bf58963cc070ca26ae2ef72e286c3b37455fd7'
label=verity.test=timoni-$$
network="verity-timoni-network-$$"
registry="verity-timoni-registry-$$"
home="verity-timoni-home-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker volume rm "$home" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/timoni"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /work ] || fail 'unexpected working directory'
docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -qx 'HOME=/home/nonroot' || fail 'HOME is not /home/nonroot'

version=$(docker run --rm --network none "$image" version)
printf '%s\n' "$version" | grep -qx "client: ${expected_version}" || fail "unexpected Timoni version: $version"

cp -R "$(dirname "$0")/module" "$work/smoke"
chmod -R a+rwX "$work"
# Every command runs with the image's own HOME, user and working directory.
run() {
  docker run --rm --network none -v "$work:/work" "$image" "$@"
}

run mod vet ./smoke >"$work/vet.log" 2>&1 || { cat "$work/vet.log" >&2; fail 'module vet failed'; }

run build verity ./smoke --namespace smoke >"$work/build.yaml" 2>"$work/build.log" ||
  { cat "$work/build.log" >&2; fail 'module build failed'; }
grep -qx 'kind: Deployment' "$work/build.yaml" || fail 'rendered module is missing Deployment'
grep -qx '  namespace: smoke' "$work/build.yaml" || fail 'rendered module ignored namespace'
grep -qx '  replicas: 2' "$work/build.yaml" || fail 'rendered module ignored module values'

printf 'values: replicas: 3\n' >"$work/override.cue"
run build verity ./smoke -n smoke -f override.cue >"$work/override.yaml" 2>"$work/build.log" ||
  { cat "$work/build.log" >&2; fail 'module build with values failed'; }
grep -qx '  replicas: 3' "$work/override.yaml" || fail 'rendered module ignored supplied values'

printf 'values: replicas: "two"\n' >"$work/bad-values.cue"
if run build verity ./smoke -n smoke -f bad-values.cue >/dev/null 2>&1; then
  fail 'invalid values unexpectedly rendered'
fi
if run build verity ./missing -n smoke >/dev/null 2>&1; then
  fail 'missing module unexpectedly rendered'
fi

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
  --network-alias registry "$registry_image" >/dev/null

# A fresh volume over the image's HOME starts from its shipped ownership, so the cache write proves it is usable.
docker volume create --label "$label" "$home" >/dev/null
oci() {
  docker run --rm --label "$label" --network "$network" -v "$work:/work" -v "$home:/home/nonroot" "$image" "$@"
}

attempts=0
until oci mod push ./smoke oci://registry:5000/modules/smoke --version 1.0.0 --registry-insecure \
  >"$work/push.log" 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || { cat "$work/push.log" >&2; fail 'module push to the local registry failed'; }
  sleep 1
done

# Building from OCI writes the default artifact cache under the image's HOME.
oci build verity oci://registry:5000/modules/smoke --version 1.0.0 -n smoke --registry-insecure \
  >"$work/oci.yaml" 2>"$work/oci.log" || { cat "$work/oci.log" >&2; fail 'build from OCI module failed'; }
grep -qx '  replicas: 2' "$work/oci.yaml" || fail 'OCI module rendered unexpected content'
grep -qx '  namespace: smoke' "$work/oci.yaml" || fail 'OCI module ignored namespace'
inspect=$(docker create --label "$label" -v "$home:/home/nonroot" "$image")
docker cp "$inspect:/home/nonroot" - | tar -t >"$work/home.list" || fail 'cannot read the image HOME'
grep -Eq '^nonroot/\.timoni/cache/[0-9a-f]{64}\.tgz$' "$work/home.list" ||
  { cat "$work/home.list" >&2; fail 'module pull did not populate the default cache under HOME'; }

if oci build verity oci://registry:5000/modules/smoke --version 9.9.9 -n smoke --registry-insecure \
  >/dev/null 2>&1; then
  fail 'missing module version unexpectedly rendered'
fi

printf 'SMOKE PASS version=%s\n' "$expected_version"

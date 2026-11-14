#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# The registry helper comes from this repository and is pinned by index digest;
# it is resolved to its per-platform child below. The registry and every oras
# run share an internal Docker network with no route to any external registry.
registry_index='ghcr.io/tektum/registry@sha256:38539bc58065aa1634bde5ec90bf58963cc070ca26ae2ef72e286c3b37455fd7'
label=verity.test=oras-$$
network="verity-oras-network-$$"
registry="verity-oras-registry-$$"
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

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/oras"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

offline() {
  docker run --rm --network none --read-only --cap-drop ALL "$image" "$@"
}

offline version >"$work/version" || fail 'oras version failed'
grep -Ex "Version: +$expected_version" "$work/version" >/dev/null ||
  fail "oras version does not report $expected_version: $(cat "$work/version")"

if offline --definitely-invalid >"$work/invalid" 2>&1; then
  fail 'invalid flag unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

if offline pull >"$work/noref" 2>&1; then
  fail 'pull without a reference unexpectedly succeeded'
fi
grep -F 'requires exactly 1 argument' "$work/noref" >/dev/null ||
  fail 'missing reference diagnostic is missing'

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
  --network-alias registry "$registry_image" >/dev/null

mkdir -p "$work/src" "$work/dst"
printf 'verity oras smoke payload\n' >"$work/src/payload.txt"
printf '{"kind":"smoke","items":[1,2,3]}\n' >"$work/src/config.json"
chmod 0755 "$work/src"
chmod 0644 "$work/src/payload.txt" "$work/src/config.json"
chmod 0777 "$work/dst"

oras() {
  dir=$1
  shift
  docker run --rm --label "$label" --network "$network" --read-only --cap-drop ALL \
    --tmpfs /tmp:rw,mode=1777 -v "$work/$dir:/work" "$image" "$@"
}

attempts=0
until oras src repo ls --plain-http registry:5000 >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'registry did not become ready'
  sleep 1
done

ref=registry:5000/smoke/artifact:v1
oras src push --plain-http --artifact-type application/vnd.verity.smoke \
  --annotation org.opencontainers.image.title=verity-oras-smoke \
  "$ref" payload.txt:text/plain config.json:application/json \
  >"$work/push.log" 2>&1 || { cat "$work/push.log" >&2; fail 'oras push failed'; }
grep -F 'Pushed [registry] registry:5000/smoke/artifact:v1' "$work/push.log" >/dev/null ||
  fail "push summary is missing: $(cat "$work/push.log")"

oras src repo tags --plain-http registry:5000/smoke/artifact >"$work/tags" ||
  fail 'oras repo tags failed'
grep -Fx v1 "$work/tags" >/dev/null || fail "pushed tag is not listed: $(cat "$work/tags")"

oras src manifest fetch --plain-http "$ref" >"$work/manifest.json" ||
  fail 'oras manifest fetch failed'
jq -e '.artifactType == "application/vnd.verity.smoke"
  and .annotations["org.opencontainers.image.title"] == "verity-oras-smoke"
  and ([.layers[].annotations["org.opencontainers.image.title"]] | sort == ["config.json", "payload.txt"])
  and ([.layers[] | select(.annotations["org.opencontainers.image.title"] == "payload.txt")
    | .mediaType] == ["text/plain"])' \
  "$work/manifest.json" >/dev/null || fail "unexpected manifest: $(cat "$work/manifest.json")"

oras dst pull --plain-http "$ref" >"$work/pull.log" 2>&1 ||
  { cat "$work/pull.log" >&2; fail 'oras pull failed'; }
cmp "$work/src/payload.txt" "$work/dst/payload.txt" || fail 'pulled payload differs'
cmp "$work/src/config.json" "$work/dst/config.json" || fail 'pulled config differs'

# Negative: a tag that was never pushed is reported as not found.
if oras dst pull --plain-http registry:5000/smoke/artifact:missing \
  >"$work/missing" 2>&1; then
  fail 'pull of a missing tag unexpectedly succeeded'
fi
grep -F 'not found' "$work/missing" >/dev/null ||
  fail "missing tag diagnostic is missing: $(cat "$work/missing")"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"

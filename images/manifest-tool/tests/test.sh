#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Helper images come from this repository and are pinned by index digest; each
# is resolved to its per-platform child below. The registry, the seeding crane,
# and manifest-tool share an internal Docker network with no route to any
# external registry, so every push and inspect hits only the local registry.
registry_index='ghcr.io/tektum/registry@sha256:38539bc58065aa1634bde5ec90bf58963cc070ca26ae2ef72e286c3b37455fd7'
crane_index='ghcr.io/tektum/crane@sha256:9419e99a1727bb750e6777d64ef34ae3068da6e3b82fffe4516fa33b9f09c986'
label=verity.test=manifest-tool-$$
network="verity-manifest-tool-network-$$"
registry="verity-manifest-tool-registry-$$"
repo=registry:5000/smoke/app
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

recipe_value() {
  awk -v key="$1" '$1 == key ":" { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml"
}
expected_version=$(recipe_value version)
expected_commit=$(recipe_value source-commit)
[ -n "$expected_version" ] || fail 'could not read the recipe version'
[ -n "$expected_commit" ] || fail 'could not read the recipe source commit'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/manifest-tool"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

docker run --rm --network none --read-only "$image" --version >"$work/version" 2>&1 ||
  fail 'manifest-tool --version failed'
grep -Fx "/usr/bin/manifest-tool version $expected_version (commit: $expected_commit)" \
  "$work/version" >/dev/null ||
  fail "unexpected version stamp: $(cat "$work/version")"

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail "unknown flag diagnostic is missing: $(cat "$work/invalid")"

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
crane_image=$(pull_child "$crane_index")

docker network create --internal --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$registry" --network "$network" \
  --network-alias registry "$registry_image" >/dev/null

mkdir -p "$work/spec"
crane() {
  docker run --rm --label "$label" --network "$network" --read-only \
    -v "$work:/work:ro" "$crane_image" "$@"
}
manifest_tool() {
  docker run --rm --label "$label" --network "$network" --read-only \
    -v "$work/spec:/spec:ro" "$image" --plain-http "$@"
}

attempts=0
until crane catalog --insecure registry:5000 >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'registry did not become ready'
  sleep 1
done

# Seed one single-platform image per architecture with distinct content, so
# each child digest is unique and its config carries the platform.
for arch in amd64 arm64; do
  mkdir -p "$work/layer-$arch"
  printf 'verity manifest-tool smoke %s\n' "$arch" >"$work/layer-$arch/payload.txt"
  tar -C "$work/layer-$arch" -cf "$work/$arch.tar" payload.txt
done
chmod -R a+rX "$work"

seed() {
  crane append --insecure -f "/work/$1.tar" -t "$repo:$1-base" \
    >/dev/null 2>"$work/seed.log" || {
    cat "$work/seed.log" >&2
    fail "cannot append the $1 layer"
  }
  crane mutate --insecure --set-platform "linux/$1" -t "$repo:$1" "$repo:$1-base" \
    >/dev/null 2>"$work/seed.log" || {
    cat "$work/seed.log" >&2
    fail "cannot set the linux/$1 platform"
  }
  crane config --insecure "$repo:$1" >"$work/config-$1.json" ||
    fail "cannot read the $1 config"
  [ "$(jq -r '.os + "/" + .architecture' "$work/config-$1.json")" = "linux/$1" ] ||
    fail "seeded $1 image has the wrong platform"
  crane digest --insecure "$repo:$1" || fail "cannot resolve the $1 digest"
}
amd64_digest=$(seed amd64)
arm64_digest=$(seed arm64)
[ "$amd64_digest" != "$arm64_digest" ] || fail 'seeded images share a digest'

# verify_index TAG MEDIA_TYPE PUSH_LOG: the pushed digest, manifest-tool's own
# inspect, and crane's view of the registry must all describe one index whose
# children are exactly the two seeded digests with their platforms.
verify_index() {
  pushed=$(awk '$1 == "Digest:" { print $2 }' "$3")
  case $pushed in
    sha256:*) ;;
    *) fail "push of $1 printed no digest: $(cat "$3")" ;;
  esac

  manifest_tool inspect "$repo:$1" >"$work/inspect-$1" 2>&1 ||
    fail "manifest-tool inspect $1 failed: $(cat "$work/inspect-$1")"
  grep -F "(Type: $2)" "$work/inspect-$1" >/dev/null ||
    fail "manifest-tool inspect $1 does not report $2: $(cat "$work/inspect-$1")"
  [ "$(awk '$1 == "Digest:" { print $2 }' "$work/inspect-$1")" = "$pushed" ] ||
    fail "manifest-tool inspect $1 reports a digest other than the pushed $pushed"
  awk '
    $2 == "Digest:" { digest[$1] = $3 }
    $2 == "-" && $3 == "OS:" { os[$1] = $4 }
    $2 == "-" && $3 == "Arch:" { arch[$1] = $4 }
    END { for (i in digest) print digest[i], os[i] "/" arch[i] }
  ' "$work/inspect-$1" | sort >"$work/inspect-children-$1"
  printf '%s linux/amd64\n%s linux/arm64\n' "$amd64_digest" "$arm64_digest" |
    sort >"$work/expected-children"
  cmp -s "$work/expected-children" "$work/inspect-children-$1" ||
    fail "manifest-tool inspect $1 children differ: $(cat "$work/inspect-children-$1")"

  crane manifest --insecure "$repo:$1" >"$work/manifest-$1.json" ||
    fail "crane manifest $1 failed"
  [ "sha256:$(sha256sum "$work/manifest-$1.json" | cut -d' ' -f1)" = "$pushed" ] ||
    fail "registry bytes for $1 do not match the pushed digest $pushed"
  [ "$(jq -r .mediaType "$work/manifest-$1.json")" = "$2" ] ||
    fail "registry manifest for $1 is not $2"
  jq -r '.manifests[] | .digest + " " + .platform.os + "/" + .platform.architecture' \
    "$work/manifest-$1.json" | sort >"$work/crane-children-$1"
  cmp -s "$work/expected-children" "$work/crane-children-$1" ||
    fail "crane manifest $1 children differ: $(cat "$work/crane-children-$1")"
}

# from-args builds a Docker manifest list from a template.
manifest_tool push from-args --platforms linux/amd64,linux/arm64 \
  --template "$repo:ARCH" --target "$repo:multi" >"$work/push-multi" 2>&1 ||
  fail "push from-args failed: $(cat "$work/push-multi")"
verify_index multi application/vnd.docker.distribution.manifest.list.v2+json "$work/push-multi"

# from-spec builds an OCI index from a read-only YAML spec.
cat >"$work/spec/index.yaml" <<EOF
image: $repo:spec
manifests:
  - image: $repo:amd64
    platform:
      architecture: amd64
      os: linux
  - image: $repo:arm64
    platform:
      architecture: arm64
      os: linux
EOF
chmod a+r "$work/spec/index.yaml"
manifest_tool push --type oci from-spec /spec/index.yaml >"$work/push-spec" 2>&1 ||
  fail "push from-spec failed: $(cat "$work/push-spec")"
verify_index spec application/vnd.oci.image.index.v1+json "$work/push-spec"

# A template entry whose per-arch image does not exist fails the whole push and
# leaves no index behind.
if manifest_tool push from-args --platforms linux/amd64,linux/s390x \
  --template "$repo:ARCH" --target "$repo:partial" >"$work/missing" 2>&1; then
  fail 'push with a missing per-arch image unexpectedly succeeded'
fi
grep -F 'pushing image failed: inspect of image' "$work/missing" |
  grep -F "failed with error: $repo:s390x: not found" >/dev/null ||
  fail "missing per-arch image diagnostic is missing: $(cat "$work/missing")"
if crane manifest --insecure "$repo:partial" >/dev/null 2>&1; then
  fail 'a failed push still published an index'
fi

printf 'image: [unterminated\n' >"$work/spec/invalid.yaml"
chmod a+r "$work/spec/invalid.yaml"
if manifest_tool push from-spec /spec/invalid.yaml >"$work/invalid-spec" 2>&1; then
  fail 'push of an invalid spec unexpectedly succeeded'
fi
grep -F 'cannot unmarshal YAML file' "$work/invalid-spec" | grep -F '/spec/invalid.yaml' |
  grep -F 'yaml: line 1' >/dev/null ||
  fail "invalid spec diagnostic is missing: $(cat "$work/invalid-spec")"

printf 'SMOKE PASS image=%s\n' "$image"

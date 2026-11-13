#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Helper images come from this repository and are pinned by index digest; each
# is resolved to its per-platform child below. The registry, signer, pusher, and
# ratify all run on an internal Docker network with no route to any external
# registry, so verification can only succeed against the local fixtures.
registry_index='ghcr.io/tektum/registry@sha256:38539bc58065aa1634bde5ec90bf58963cc070ca26ae2ef72e286c3b37455fd7'
cosign_index='ghcr.io/tektum/cosign@sha256:ad309c0b29977b7c7fcccced5ec56390f141b0d58f06090025ccb3fff66daa29'
crane_index='ghcr.io/tektum/crane@sha256:9419e99a1727bb750e6777d64ef34ae3068da6e3b82fffe4516fa33b9f09c986'
label=verity.test=ratify-$$
network="verity-ratify-network-$$"
registry="verity-ratify-registry-$$"
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
  '["/usr/bin/ratify"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

docker run --rm --network none --read-only "$image" version >"$work/version" ||
  fail 'ratify version failed'
grep -Ex "Version: +$expected_version" "$work/version" >/dev/null ||
  fail "ratify version does not report $expected_version: $(cat "$work/version")"

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

if docker run --rm --network none --read-only "$image" verify \
  >"$work/nosubject" 2>&1; then
  fail 'verify without a subject unexpectedly succeeded'
fi
grep -F 'subject parameter is required' "$work/nosubject" >/dev/null ||
  fail 'missing subject diagnostic is missing'

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
cosign_image=$(pull_child "$cosign_index")
crane_image=$(pull_child "$crane_index")

docker network create --internal --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$registry" --network "$network" \
  --network-alias registry "$registry_image" >/dev/null

user=$(id -u):$(id -g)
crane() {
  docker run --rm --label "$label" --network "$network" --read-only \
    -v "$work:/work:ro" "$crane_image" "$@"
}
cosign() {
  docker run --rm --label "$label" --network "$network" --read-only \
    --user "$user" -e HOME=/work/keys -e COSIGN_PASSWORD= \
    -v "$work/keys:/work/keys" -w /work/keys "$cosign_image" "$@"
}
ratify() {
  docker run --rm --label "$label" --network "$network" --read-only \
    --tmpfs /tmp:rw,mode=1777 -v "$work/ratify:/config:ro" "$image" "$@"
}

attempts=0
until crane catalog --insecure registry:5000 >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail 'registry did not become ready'
  sleep 1
done

# Distinct subjects: signed by the trusted key, signed only by an untrusted key,
# and left unsigned.
mkdir -p "$work/keys" "$work/ratify"
for name in trusted untrusted unsigned; do
  mkdir -p "$work/layer-$name"
  printf 'verity ratify smoke %s\n' "$name" >"$work/layer-$name/payload.txt"
  tar -C "$work/layer-$name" -cf "$work/$name.tar" payload.txt
done
chmod -R a+rX "$work"

push() {
  crane append --insecure -f "/work/$1.tar" -t "registry:5000/smoke/app:$1" \
    >/dev/null 2>"$work/push.log" || {
    cat "$work/push.log" >&2
    fail "cannot push the $1 subject"
  }
  crane digest --insecure "registry:5000/smoke/app:$1" ||
    fail "cannot resolve the $1 subject digest"
}
trusted_digest=$(push trusted)
untrusted_digest=$(push untrusted)
unsigned_digest=$(push unsigned)

cosign generate-key-pair --output-key-prefix trusted >/dev/null 2>&1 ||
  fail 'cannot generate the trusted key pair'
cosign generate-key-pair --output-key-prefix untrusted >/dev/null 2>&1 ||
  fail 'cannot generate the untrusted key pair'

sign() {
  cosign sign --yes --key "$1.key" --allow-http-registry --allow-insecure-registry \
    --use-signing-config=false --new-bundle-format=false --tlog-upload=false \
    "registry:5000/smoke/app@$2" >"$work/sign.log" 2>&1 || {
    cat "$work/sign.log" >&2
    fail "cannot sign $2 with the $1 key"
  }
}
sign trusted "$trusted_digest"
sign untrusted "$untrusted_digest"

cp "$work/keys/trusted.pub" "$work/ratify/trusted.pub"
cat >"$work/ratify/config.json" <<'JSON'
{
  "store": {
    "version": "1.0.0",
    "plugins": [
      {
        "name": "oras",
        "useHttp": true,
        "cosignEnabled": true,
        "localCachePath": "/tmp/ratify-cache"
      }
    ]
  },
  "policy": {
    "version": "1.0.0",
    "plugin": {
      "name": "configPolicy",
      "artifactVerificationPolicies": {
        "application/vnd.dev.cosign.artifact.sig.v1+json": "all"
      }
    }
  },
  "verifier": {
    "version": "1.0.0",
    "plugins": [
      {
        "name": "cosign",
        "artifactTypes": "application/vnd.dev.cosign.artifact.sig.v1+json",
        "trustPolicies": [
          {
            "name": "trusted-key",
            "version": "1.0.0",
            "scopes": ["*"],
            "keys": [{"file": "/config/trusted.pub"}],
            "tLogVerify": false
          }
        ]
      }
    ]
  }
}
JSON
chmod -R a+rX "$work/ratify"

# verify NAME DIGEST: run ratify and print its overall verdict as true or false.
verify() {
  ratify verify --config /config/config.json --subject "registry:5000/smoke/app@$2" \
    >"$work/$1.json" 2>"$work/$1.err" || {
    cat "$work/$1.err" >&2
    fail "ratify verify errored for the $1 subject"
  }
  # Ratify omits a false top-level isSuccess, so absence means rejection.
  jq -r '.isSuccess == true' "$work/$1.json" 2>/dev/null || {
    cat "$work/$1.json" "$work/$1.err" >&2
    fail "ratify output for the $1 subject is not JSON"
  }
}

verdict=$(verify trusted "$trusted_digest")
[ "$verdict" = true ] || {
  cat "$work/trusted.json" >&2
  fail 'signature from the trusted key was not accepted'
}
jq -e '[.verifierReports[] | select(.verifierName == "cosign" and .isSuccess == true)
  | .extensions.signatures[].verifications[]
  | select(.isSuccess == true and .keyInformation.name == "/config/trusted.pub")] | length > 0' \
  "$work/trusted.json" >/dev/null || {
  cat "$work/trusted.json" >&2
  fail 'trusted report lacks a cosign verification by the trusted key'
}

verdict=$(verify untrusted "$untrusted_digest")
[ "$verdict" = false ] || {
  cat "$work/untrusted.json" >&2
  fail 'signature from an untrusted key was accepted'
}
jq -e '[.verifierReports[] | select(.verifierName == "cosign") | .extensions.signatures[].verifications[]
  | select(.isSuccess == false and (.error | test("invalid signature")))] | length > 0' \
  "$work/untrusted.json" >/dev/null || {
  cat "$work/untrusted.json" >&2
  fail 'untrusted signature was not rejected by the cosign key check'
}

verdict=$(verify unsigned "$unsigned_digest")
[ "$verdict" = false ] || {
  cat "$work/unsigned.json" >&2
  fail 'unsigned subject was accepted'
}
jq -e '[.verifierReports[]? | select(.isSuccess == true)] | length == 0' \
  "$work/unsigned.json" >/dev/null || {
  cat "$work/unsigned.json" >&2
  fail 'unsigned subject reported a successful verifier'
}

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"

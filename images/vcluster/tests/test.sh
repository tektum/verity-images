#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
label=verity.test=vcluster-$$
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# run OUT [DOCKER ARGS...] -- [ARGS...]: run the image offline and read-only,
# write combined output to OUT, and return the container exit status.
run() {
  out=$1
  shift
  docker run --rm --label "$label" --network none --read-only "$@" >"$out" 2>&1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/vcluster","start"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" \
  >"$work/env"
grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' "$work/env" >/dev/null ||
  fail 'CA bundle environment is missing'

# Version contract: the SyncerVersion stamp and the Go main module version.
run "$work/version" --entrypoint /usr/bin/vcluster "$image" version ||
  fail 'vcluster version failed'
[ "$(cat "$work/version")" = "$expected_version" ] ||
  fail "vcluster version printed $(cat "$work/version"), want $expected_version"

created=$(docker create --label "$label" "$image")
docker cp "$created:/usr/bin/vcluster" "$work/vcluster"
docker rm "$created" >/dev/null
go version -m "$work/vcluster" >"$work/buildinfo"
awk '$1 == "mod" && $2 == "github.com/loft-sh/vcluster" { print $3 }' "$work/buildinfo" |
  grep -Ex "v$expected_version(\+dirty)?" >/dev/null ||
  fail "binary is not stamped with vcluster v$expected_version"
awk '$1 == "path" { print $2 }' "$work/buildinfo" |
  grep -Fx github.com/loft-sh/vcluster/cmd/vcluster >/dev/null ||
  fail 'binary is not the vcluster syncer command'

# The syncer command tree, not the vclusterctl CLI.
run "$work/help" --entrypoint /usr/bin/vcluster "$image" --help ||
  fail 'vcluster --help failed'
for cmd in start certs snapshot restore node version; do
  grep -Eq "^  $cmd " "$work/help" || fail "help does not list the $cmd command"
done
grep -F 'vcluster root command' "$work/help" >/dev/null || fail 'unexpected help banner'
run "$work/start-help" "$image" --help || fail 'start --help failed'
grep -F '/var/lib/vcluster/config.yaml' "$work/start-help" >/dev/null ||
  fail 'start does not default to the in-cluster config path'

printf 'controlPlane:\n  distro:\n    k8s:\n      enabled: true\n' >"$work/valid.yaml"
printf 'notAKey: 1\n' >"$work/invalid.yaml"
chmod 0644 "$work/valid.yaml" "$work/invalid.yaml"
incluster="-e POD_NAME=demo-0 -e POD_NAMESPACE=demo -e VCLUSTER_NAME=demo"

# A valid config is parsed and start-up fails closed on the missing host cluster.
# shellcheck disable=SC2086
if run "$work/no-cluster" $incluster -v "$work/valid.yaml:/etc/vc/config.yaml:ro" \
  "$image" --config /etc/vc/config.yaml; then
  fail 'vcluster started without a host cluster'
fi
grep -F "\"version\": \"$expected_version\"" "$work/no-cluster" >/dev/null ||
  fail 'start-up does not log the stamped version'
grep -F 'unable to load in-cluster configuration, KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined' \
  "$work/no-cluster" >/dev/null || fail 'missing host cluster diagnostic is absent'

# Negative: an unknown config key is rejected before any cluster access.
# shellcheck disable=SC2086
if run "$work/bad-config" $incluster -v "$work/invalid.yaml:/etc/vc/config.yaml:ro" \
  "$image" --config /etc/vc/config.yaml; then
  fail 'vcluster accepted an invalid config'
fi
grep -F 'json: unknown field \"notAKey\"' "$work/bad-config" >/dev/null ||
  fail 'invalid config diagnostic is absent'
if grep -F 'in-cluster' "$work/bad-config" >/dev/null; then
  fail 'invalid config reached host cluster setup'
fi

# Negative: a missing config file fails closed.
# shellcheck disable=SC2086
if run "$work/no-config" $incluster "$image"; then
  fail 'vcluster started without a config'
fi
grep -F 'open /var/lib/vcluster/config.yaml: no such file or directory' "$work/no-config" \
  >/dev/null || fail 'missing config diagnostic is absent'

# Negative: in-cluster mode requires the vCluster name.
if run "$work/no-name" -e POD_NAME=demo-0 -e POD_NAMESPACE=demo "$image"; then
  fail 'vcluster started without VCLUSTER_NAME'
fi
grep -F '"error": "empty vCluster name"' "$work/no-name" >/dev/null ||
  fail 'missing vCluster name diagnostic is absent'

# Negative: unknown subcommands are rejected.
if run "$work/bogus" --entrypoint /usr/bin/vcluster "$image" definitely-invalid; then
  fail 'vcluster accepted an unknown command'
fi
grep -F 'unknown command \"definitely-invalid\" for \"vcluster\"' "$work/bogus" >/dev/null ||
  fail 'unknown command diagnostic is absent'

echo "vcluster $expected_version smoke test passed"

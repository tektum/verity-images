#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
prefix="verity-spire-controller-manager-test-$$"
static="$prefix-static"
extract="$prefix-extract"
module=github.com/spiffe/spire-controller-manager
work=$(mktemp -d)

cleanup() {
  docker rm -f "$static" "$extract" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || fail 'package version not found in melange.yaml'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'OCI user is not 1000'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/spire-controller-manager"]' || fail 'unexpected entrypoint'
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in
  null | '[]') ;;
  *) fail 'unexpected default command' ;;
esac
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'

# The binary has no version flag; its stamped Go build info is what scanners read.
docker create --name "$extract" "$image" >/dev/null || fail 'could not create a container'
docker cp -L "$extract:/spire-controller-manager" "$work/binary" >/dev/null ||
  fail 'could not copy the binary out of the image'
tab=$(printf '\t')
version_re=$(printf '%s' "$expected_version" | sed 's/\./\\./g')
grep -a -x -E "mod${tab}github\.com/spiffe/spire-controller-manager${tab}v${version_re}(\+dirty)?${tab}" \
  "$work/binary" >/dev/null || fail "binary is not stamped as $module v$expected_version"

docker run --rm --network none --read-only "$image" -h >"$work/help" 2>&1 ||
  fail '-h did not exit 0'
for flag in -config -spire-api-socket -expand-env -zap-log-level; do
  grep -F -e "  $flag" "$work/help" >/dev/null || fail "help is missing $flag"
done

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'unknown flag diagnostic is missing'

if docker run --rm --network none --read-only "$image" >"$work/no-config" 2>&1; then
  fail 'controller started without a trust domain'
fi
grep -F '"error": "trust domain is required configuration"' \
  "$work/no-config" >/dev/null || fail 'missing trust domain diagnostic is missing'

if docker run --rm --network none --read-only "$image" -config /etc/spire/missing.yaml \
  >"$work/missing" 2>&1; then
  fail 'controller started with a missing configuration file'
fi
grep -F 'unable to load the config file: could not read file at /etc/spire/missing.yaml' \
  "$work/missing" >/dev/null || fail 'missing configuration file diagnostic is missing'

mkdir "$work/manifests"
cat >"$work/config.yaml" <<'EOF'
apiVersion: spire.spiffe.io/v1alpha1
kind: ControllerManagerConfig
metrics:
  bindAddress: "0"
health:
  healthProbeBindAddress: 127.0.0.1:8083
clusterName: smoke
clusterDomain: cluster.local
trustDomain: example.org
logLevel: info
spireServerSocketPath: /tmp/spire-server/private/api.sock
EOF
cat >"$work/manifests/entry.yaml" <<'EOF'
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterStaticEntry
metadata:
  name: smoke-workload
spec:
  spiffeID: spiffe://example.org/smoke/workload
  parentID: spiffe://example.org/smoke/node
  selectors: ["unix:uid:1000"]
EOF
cp "$work/config.yaml" "$work/static.yaml"
printf 'staticManifestPath: /etc/spire/manifests\n' >>"$work/static.yaml"
cp "$work/static.yaml" "$work/static-leader.yaml"
printf 'leaderElection:\n  leaderElect: true\n' >>"$work/static-leader.yaml"
chmod 755 "$work/manifests"
chmod 644 "$work/config.yaml" "$work/static.yaml" "$work/static-leader.yaml" \
  "$work/manifests/entry.yaml"

if docker run --rm --network none --read-only \
  -v "$work/static-leader.yaml:/etc/spire/config.yaml:ro" \
  -v "$work/manifests:/etc/spire/manifests:ro" "$image" -config /etc/spire/config.yaml \
  >"$work/static-leader" 2>&1; then
  fail 'leader election with static manifests was accepted'
fi
grep -F 'the Leader election is not possible with static manifests' "$work/static-leader" \
  >/dev/null || fail 'static manifest leader election diagnostic is missing'

# Kubernetes mode outside a cluster loads the configuration, then fails cleanly.
if docker run --rm --network none --read-only --tmpfs /tmp:rw,mode=1777 \
  -v "$work/config.yaml:/etc/spire/config.yaml:ro" "$image" -config /etc/spire/config.yaml \
  >"$work/kubernetes" 2>&1; then
  fail 'controller started without a Kubernetes API'
fi
grep -F '"trust domain": "example.org"' "$work/kubernetes" >/dev/null ||
  fail 'configuration file was not loaded'
grep -F 'failed to get in cluster configuration' "$work/kubernetes" >/dev/null ||
  fail 'missing in-cluster configuration diagnostic is missing'
grep -F 'KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined' \
  "$work/kubernetes" >/dev/null || fail 'in-cluster configuration error is not the upstream one'

# Static mode needs no Kubernetes API and waits for the SPIRE server socket.
docker run -d --name "$static" --network none --read-only \
  -v "$work/static.yaml:/etc/spire/config.yaml:ro" \
  -v "$work/manifests:/etc/spire/manifests:ro" "$image" -config /etc/spire/config.yaml \
  >/dev/null || fail 'could not start static mode'
i=0
until docker logs "$static" 2>&1 | grep -F 'Dialing SPIRE Server socket' >/dev/null; do
  i=$((i + 1))
  if [ "$i" -ge 90 ]; then
    docker logs "$static" >&2 || true
    fail 'static mode did not dial the SPIRE server socket'
  fi
  sleep 1
done
sleep 5
test "$(docker inspect --format '{{.State.Status}}' "$static")" = running || {
  docker logs "$static" >&2 || true
  fail 'static mode exited instead of waiting for the SPIRE server'
}

printf 'SMOKE PASS image=%s\n' "$image"

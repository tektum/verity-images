#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# flanneld needs NET_ADMIN to program a node, so the image runs as root; every check below runs
# unprivileged with all capabilities dropped.
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 0 ] \
  || [ -z "$(docker image inspect -f '{{.Config.User}}' "$image")" ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/opt/bin/flanneld"]' ] \
  || fail 'unexpected OCI entrypoint'
case $(docker image inspect -f '{{json .Config.Cmd}}' "$image") in
  null|'[]') ;;
  *) fail 'unexpected OCI command' ;;
esac

run() {
  docker run --rm --network none --read-only --tmpfs /tmp --cap-drop ALL \
    --security-opt no-new-privileges --cpus 2 --memory 512m --pids-limit 128 "$@"
}

version_output=$(run "$image" --version 2>&1) || fail 'flanneld --version failed'
printf '%s\n' "$version_output" | grep -Ex 'v0\.28\.[0-9]+' >/dev/null \
  || { printf '%s\n' "$version_output" >&2; fail 'flanneld version does not match the 0.28 stream'; }

# Negative: without a Kubernetes API the kube subnet manager must fail loudly.
status=0
output=$(run "$image" --kube-subnet-mgr 2>&1) || status=$?
[ "$status" -ne 0 ] || fail 'flanneld --kube-subnet-mgr without a cluster unexpectedly succeeded'
printf '%s\n' "$output" | grep -F 'Failed to create SubnetManager' >/dev/null \
  || { printf '%s\n' "$output" >&2; fail 'missing-cluster diagnostic missing'; }

# The CNI plugin binary ships in the image as a real file at the path the chart copies from.
cni_output=$(printf '{"cniVersion":"1.0.0"}' \
  | docker run --rm -i --network none --read-only --cap-drop ALL -e CNI_COMMAND=VERSION \
      --entrypoint /flannel "$image" 2>&1) || fail 'flannel CNI plugin VERSION failed'
printf '%s\n' "$cni_output" | grep -F '"supportedVersions"' >/dev/null || fail 'flannel CNI plugin VERSION output unexpected'

# The chart init containers copy the plugin and the CNI config with cp.
run --entrypoint cp "$image" -f /flannel /tmp/flannel >/dev/null 2>&1 \
  || fail 'cannot copy /flannel with cp'
[ "$(docker run --rm --network none --entrypoint sh "$image" -c '[ -f /flannel ] && [ ! -L /flannel ] && echo real')" = real ] \
  || fail '/flannel is not a regular file'

# Tools flanneld shells out to are present (not executed: nft failed under qemu-user on the
# non-native architecture, where this test also runs).
for tool in ip iptables nft wg; do
  run --entrypoint sh "$image" -c "command -v $tool" >/dev/null 2>&1 || fail "$tool is not installed in the image"
done

printf 'SMOKE PASS image=%s\n' "$image"

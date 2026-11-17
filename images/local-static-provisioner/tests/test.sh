#!/bin/sh
set -eu

# Out-of-cluster behavior against a pinned Verity etcd and kube-apiserver on a
# per-test bridge network. The provisioner must:
#   - keep the upstream entrypoint, root user, /local-provisioner path and
#     /scripts cleaners, with the tools those cleaners call;
#   - fail fast on unknown flags, a missing or invalid provisioner config, a
#     missing MY_NODE_NAME, no usable kubeconfig, and an unknown node;
#   - discover bind-mounted volumes under its mount directory and create local
#     PersistentVolumes with the host path, node affinity, storage class
#     policy, copied node labels and (setPVOwnerRef) a Node owner reference,
#     skipping non-mount points;
#   - clean a released volume's contents, delete its PV, rediscover it, and
#     report all of that on its metrics endpoint;
#   - exit on SIGTERM.

image=${1:?usage: test.sh IMAGE}

etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
curl_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'

id=$$
label="verity-test=local-static-provisioner-$id"
network="verity-lsp-$id"
etcd="verity-lsp-etcd-$id"
api="verity-lsp-api-$id"
lsp="verity-lsp-$id"
node=smoke-node
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$lsp" "$api"; do
    printf -- '--- %s\n' "$c" >&2
    docker logs "$c" 2>&1 | tail -n 30 >&2 || true
  done
  exit 1
}

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 0 ] ||
  fail 'unexpected OCI user'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/local-volume-provisioner"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ] ||
  fail 'unexpected working directory'

# out NAME ARGS...: run under a 60s bound; record status and output. A timeout
# is a failure: every case here must exit on its own.
out() {
  name=$1
  shift
  status=0
  timeout 60 docker run --rm --label "$label" --read-only --cap-drop=ALL "$@" \
    >"$work/$name.out" 2>&1 || status=$?
  [ "$status" != 124 ] || fail "$name: timed out"
}

expect_fail() {
  name=$1
  message=$2
  shift 2
  out "$name" "$@"
  [ "$status" != 0 ] || fail "$name: unexpectedly succeeded"
  grep -qF -- "$message" "$work/$name.out" ||
    fail "$name: missing '$message': $(grep -vE '^[[:space:]]|^goroutine' "$work/$name.out" | head -n 8)"
}

mkdir -p "$work/cfg/valid" "$work/cfg/nohostdir" "$work/cfg/badmode" "$work/kube" "$work/pki" \
  "$work/disks/vol1" "$work/disks/vol2" "$work/disks/plain" "$work/src/vol1" "$work/src/vol2" \
  "$work/fs"

# Upstream image contract: /local-provisioner, the cleanup scripts and every
# tool they invoke. Run the tool checks through bash, which the scripts use.
# shellcheck disable=SC2016
out layout --network none --entrypoint /bin/bash "$image" -c '
  set -e
  [ "$(readlink -f /local-provisioner)" = /usr/bin/local-volume-provisioner ]
  for s in blkdiscard dd_zero fsclean quick_reset shred; do [ -x "/scripts/$s.sh" ]; done
  [ -f /scripts/common.sh ]
  for t in blkdiscard dd find ionice mkfs mkfs.ext2 shred wipefs xargs; do
    command -v "$t" >/dev/null || { echo "missing $t"; exit 1; }
  done
  echo layout-ok'
[ "$status" = 0 ] || fail "image layout: $(cat "$work/layout.out")"

# quick_reset.sh runs mkfs then wipefs. Exercise that pair on a scratch image
# file (the script itself insists on a block device, checked below).
# shellcheck disable=SC2016
out mkfs --network none --tmpfs /tmp --entrypoint /bin/bash "$image" -c '
  set -e
  dd if=/dev/zero of=/tmp/disk.img bs=1M count=8 2>/dev/null
  mkfs -F /tmp/disk.img >/dev/null 2>&1
  [[ $(wipefs /tmp/disk.img) == *ext2* ]]
  [[ $(wipefs -a /tmp/disk.img) == *"bytes were erased"* ]]
  [ -z "$(wipefs /tmp/disk.img)" ]
  echo mkfs-ok'
[ "$status" = 0 ] || fail "mkfs/wipefs: $(cat "$work/mkfs.out")"
expect_fail quick-reset-not-block '/tmp is not a block device.' --network none \
  -e LOCAL_PV_BLKDEVICE=/tmp --entrypoint /scripts/quick_reset.sh "$image"

# fsclean.sh, the job cleaner command, empties a volume but keeps its root.
mkdir -p "$work/fs/sub/deeper"
touch "$work/fs/.hidden" "$work/fs/file" "$work/fs/sub/deeper/file"
chmod -R a+rwX "$work/fs"
out fsclean --network none -v "$work/fs:/vol" -e LOCAL_PV_FILESYSTEM=/vol \
  --entrypoint /scripts/fsclean.sh "$image"
[ "$status" = 0 ] || fail "fsclean.sh exited $status: $(cat "$work/fsclean.out")"
[ -d "$work/fs" ] && [ -z "$(ls -A "$work/fs")" ] || fail 'fsclean.sh did not empty the volume'

cat >"$work/cfg/valid/storageClassMap" <<'EOF'
local-storage:
  hostDir: /srv/disks
  mountDir: /mnt/disks
  volumeMode: Filesystem
EOF
printf -- '- topology.kubernetes.io/zone\n' >"$work/cfg/valid/nodeLabelsForPV"
printf 'true\n' >"$work/cfg/valid/setPVOwnerRef"
printf 'local-storage:\n  mountDir: /mnt/disks\n' >"$work/cfg/nohostdir/storageClassMap"
printf 'local-storage:\n  hostDir: /srv/disks\n  mountDir: /mnt/disks\n  volumeMode: Tape\n' \
  >"$work/cfg/badmode/storageClassMap"
chmod -R a+rX "$work/cfg"

expect_fail unknown-flag 'flag provided but not defined: -no-such-flag' --network none \
  "$image" --no-such-flag
expect_fail no-config "Error parsing Provisioner's configuration" --network none "$image"
expect_fail no-hostdir 'Storage Class local-storage is misconfigured, missing HostDir or MountDir parameter' \
  --network none -v "$work/cfg/nohostdir:/etc/provisioner/config:ro" "$image"
expect_fail bad-volume-mode 'unsupported volume mode Tape' \
  --network none -v "$work/cfg/badmode:/etc/provisioner/config:ro" "$image"
expect_fail no-node-name 'MY_NODE_NAME environment variable not set' \
  --network none -v "$work/cfg/valid:/etc/provisioner/config:ro" "$image"
expect_fail no-kubeconfig 'Error creating InCluster config' --network none \
  -v "$work/cfg/valid:/etc/provisioner/config:ro" -e MY_NODE_NAME=$node "$image"
expect_fail missing-kubeconfig 'Error creating config from KUBECONFIG specified file: /kube/missing' \
  --network none -v "$work/cfg/valid:/etc/provisioner/config:ro" -e MY_NODE_NAME=$node \
  -e KUBECONFIG=/kube/missing "$image"

# image_arch, pull_child: resolve each pinned helper index to the candidate's
# platform child, verifying the index bytes against the pin. A classic Docker
# store cannot bind one index digest to a second platform's image.
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
etcd_image=$(pull_child "$etcd_index") || exit 1
api_image=$(pull_child "$api_index") || exit 1
curl_image=$(pull_child "$curl_index") || exit 1

openssl genrsa -out "$work/pki/sa.key" 2048 2>/dev/null || fail 'could not generate the service account key'
token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
printf '%s,verity-admin,verity-admin,system:masters\n' "$token" >"$work/pki/tokens.csv"
cat >"$work/kube/config" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: smoke
    cluster:
      server: https://$api:6443
      insecure-skip-tls-verify: true
users:
  - name: admin
    user:
      token: $token
contexts:
  - name: smoke
    context:
      cluster: smoke
      user: admin
current-context: smoke
EOF
chmod -R a+rX "$work/kube" "$work/pki"

docker network create --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$etcd" --network "$network" \
  --tmpfs /var/lib/etcd:uid=65532,gid=65532 "$etcd_image" --data-dir=/var/lib/etcd/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls="http://$etcd:2379" >/dev/null ||
  fail 'etcd did not start'
docker run -d --label "$label" --name "$api" --network "$network" --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/pki:/pki:ro" "$api_image" \
  --etcd-servers="http://$etcd:2379" --secure-port=6443 --cert-dir=/tmp \
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC \
  --service-account-issuer=https://kubernetes.default.svc \
  --service-account-key-file=/pki/sa.key --service-account-signing-key-file=/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/16 >/dev/null || fail 'kube-apiserver did not start'

# kube METHOD PATH [CONTENT_TYPE BODY]: call the API server; print the body.
kube() {
  if [ "$#" -gt 2 ]; then
    docker run --rm --label "$label" --network "$network" "$curl_image" -sk --fail-with-body \
      --max-time 10 -X "$1" -H "Authorization: Bearer $token" -H "Content-Type: $3" \
      --data "$4" "https://$api:6443$2"
  else
    docker run --rm --label "$label" --network "$network" "$curl_image" -sk --fail-with-body \
      --max-time 10 -X "$1" -H "Authorization: Bearer $token" "https://$api:6443$2"
  fi
}

i=0
until kube GET /readyz >/dev/null 2>&1; do
  [ "$(docker inspect -f '{{.State.Running}}' "$api" 2>/dev/null)" = true ] ||
    fail 'kube-apiserver exited before it was ready'
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

expect_fail unknown-node 'Could not get node information' --network "$network" \
  -v "$work/cfg/valid:/etc/provisioner/config:ro" -v "$work/kube:/kube:ro" \
  -e MY_NODE_NAME=$node -e KUBECONFIG=/kube/config "$image"

kube POST /api/v1/nodes application/json "{\"apiVersion\":\"v1\",\"kind\":\"Node\",
  \"metadata\":{\"name\":\"$node\",\"labels\":{\"kubernetes.io/hostname\":\"$node\",
  \"topology.kubernetes.io/zone\":\"smoke-zone\"}}}" >"$work/node.json" ||
  fail "could not create the node: $(cat "$work/node.json")"
node_uid=$(jq -r .metadata.uid "$work/node.json")
kube POST /apis/storage.k8s.io/v1/storageclasses application/json '{"apiVersion":"storage.k8s.io/v1",
  "kind":"StorageClass","metadata":{"name":"local-storage"},"provisioner":"kubernetes.io/no-provisioner",
  "reclaimPolicy":"Delete","volumeBindingMode":"WaitForFirstConsumer"}' >"$work/sc.json" ||
  fail "could not create the storage class: $(cat "$work/sc.json")"

# vol1 and vol2 are bind mounts below the discovery directory; plain is not.
# Upstream sets logtostderr with klog's non-legacy threshold, so info logs need
# --stderrthreshold=INFO.
mkdir -p "$work/src/vol1/nested/dir"
touch "$work/src/vol1/data" "$work/src/vol1/.hidden" "$work/src/vol1/nested/dir/file" "$work/src/vol2/untouched"
chmod -R a+rwX "$work/src"
docker run -d --label "$label" --name "$lsp" --network "$network" --read-only --cap-drop=ALL \
  --tmpfs /tmp -v "$work/cfg/valid:/etc/provisioner/config:ro" -v "$work/kube:/kube:ro" \
  -v "$work/disks:/mnt/disks:ro" -v "$work/src/vol1:/mnt/disks/vol1" -v "$work/src/vol2:/mnt/disks/vol2" \
  -e MY_NODE_NAME=$node -e MY_NAMESPACE=default -e KUBECONFIG=/kube/config "$image" \
  --discovery-period=2s --stderrthreshold=INFO >/dev/null || fail 'provisioner did not start'

running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$lsp" 2>/dev/null)" = true ] ||
    fail "provisioner exited $(docker inspect -f '{{.State.ExitCode}}' "$lsp" 2>/dev/null)"
}

# pvs: list this test's local PVs, keyed by path, as "path name uid".
pvs() {
  kube GET /api/v1/persistentvolumes >"$work/pvs.json" || fail 'could not list PVs'
  jq -r '.items[] | select(.spec.local != null) | "\(.spec.local.path) \(.metadata.name) \(.metadata.uid)"' \
    "$work/pvs.json" | sort
}

i=0
until [ "$(pvs | wc -l)" -eq 2 ]; do
  running
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail "expected 2 local PVs, found: $(pvs)"
  sleep 2
done
[ "$(pvs | awk '{ print $1 }' | tr '\n' ' ')" = '/srv/disks/vol1 /srv/disks/vol2 ' ] ||
  fail "unexpected PV paths: $(pvs)"

jq -e --arg node "$node" --arg uid "$node_uid" '
  [.items[] | select(.spec.local != null)] | length == 2 and all(
    .spec.storageClassName == "local-storage" and
    .spec.persistentVolumeReclaimPolicy == "Delete" and
    .spec.volumeMode == "Filesystem" and
    .spec.accessModes == ["ReadWriteOnce"] and
    (.spec.capacity.storage | test("^[1-9]")) and
    .spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0] ==
      {key: "kubernetes.io/hostname", operator: "In", values: [$node]} and
    .metadata.labels["topology.kubernetes.io/zone"] == "smoke-zone" and
    (.metadata.annotations["pv.kubernetes.io/provisioned-by"] | startswith("local-volume-provisioner-" + $node)) and
    .metadata.ownerReferences[0].kind == "Node" and .metadata.ownerReferences[0].uid == $uid)' \
  "$work/pvs.json" >/dev/null || fail "unexpected PV contents: $(jq -c '.items' "$work/pvs.json")"

docker logs "$lsp" 2>&1 | grep -qF 'path "/mnt/disks/plain" is not a valid mount point' ||
  fail 'provisioner did not reject the non-mount-point directory'

metric() {
  docker run --rm --label "$label" --network "$network" "$curl_image" -sf --max-time 10 \
    "http://$lsp:8080/metrics" || fail 'metrics endpoint did not answer'
}
metric >"$work/metrics.txt"
grep -qE '^local_volume_provisioner_persistentvolume_discovery_total\{.*mode="Filesystem".*\} 2$' \
  "$work/metrics.txt" || fail "discovery_total is not 2: $(grep discovery_total "$work/metrics.txt")"
grep -qx 'local_volume_provisioner_apiserver_requests_total{method="create"} 2' "$work/metrics.txt" ||
  fail "apiserver create requests are not 2: $(grep apiserver_requests_total "$work/metrics.txt")"

# Release vol1 (as the PV controller would after its claim is deleted). The
# provisioner must wipe its contents, then delete the PV. The API server's
# pv-protection admission added a finalizer that kube-controller-manager would
# drop; drop it here, after which the provisioner must rediscover the volume.
vol1_name=$(pvs | awk '$1 == "/srv/disks/vol1" { print $2 }')
vol1_uid=$(pvs | awk '$1 == "/srv/disks/vol1" { print $3 }')
vol2_uid=$(pvs | awk '$1 == "/srv/disks/vol2" { print $3 }')
kube PATCH "/api/v1/persistentvolumes/$vol1_name/status" application/merge-patch+json \
  '{"status":{"phase":"Released"}}' >"$work/release.json" ||
  fail "could not release $vol1_name: $(cat "$work/release.json")"

i=0
until kube GET "/api/v1/persistentvolumes/$vol1_name" >"$work/vol1.json" &&
  jq -e '.metadata.deletionTimestamp != null' "$work/vol1.json" >/dev/null; do
  running
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail "released PV was not deleted: $(jq -c '{metadata, status}' "$work/vol1.json")"
  sleep 2
done
[ -z "$(ls -A "$work/src/vol1")" ] || fail "released volume was not cleaned: $(ls -A "$work/src/vol1")"
[ -d "$work/src/vol1" ] || fail 'cleanup removed the volume root'
kube PATCH "/api/v1/persistentvolumes/$vol1_name" application/merge-patch+json \
  '{"metadata":{"finalizers":null}}' >"$work/finalize.json" ||
  fail "could not drop the finalizer: $(cat "$work/finalize.json")"

i=0
while :; do
  running
  new_uid=$(pvs | awk '$1 == "/srv/disks/vol1" { print $3 }')
  [ -n "$new_uid" ] && [ "$new_uid" != "$vol1_uid" ] && break
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail "cleaned volume was not rediscovered: $(pvs)"
  sleep 2
done
[ -f "$work/src/vol2/untouched" ] || fail 'cleanup touched an unrelated volume'
[ "$(pvs | awk '$1 == "/srv/disks/vol2" { print $3 }')" = "$vol2_uid" ] ||
  fail 'unrelated PV was replaced'
[ "$(pvs | awk '$1 == "/srv/disks/vol1" { print $2 }')" = "$vol1_name" ] ||
  fail 'rediscovered PV changed its deterministic name'
docker logs "$lsp" 2>&1 | grep -qF "Deleting pv $vol1_name after successful cleanup" ||
  fail "provisioner did not log the cleanup-then-delete path: $(docker logs "$lsp" 2>&1 | grep -iE 'delet|clean' | head -n 8)"
metric >"$work/metrics.txt"
grep -qE '^local_volume_provisioner_persistentvolume_delete_total\{mode="Filesystem",type="process"\} 1$' \
  "$work/metrics.txt" || fail "delete_total is not 1: $(grep delete_total "$work/metrics.txt")"
grep -qx 'local_volume_provisioner_apiserver_requests_total{method="delete"} 1' "$work/metrics.txt" ||
  fail "apiserver delete requests are not 1: $(grep apiserver_requests_total "$work/metrics.txt")"
grep -qx 'local_volume_provisioner_apiserver_requests_total{method="create"} 3' "$work/metrics.txt" ||
  fail "apiserver create requests are not 3: $(grep apiserver_requests_total "$work/metrics.txt")"

# No signal handler: the Go runtime must still exit promptly on SIGTERM.
docker stop -t 20 "$lsp" >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' "$lsp")
[ "$code" = 143 ] || fail "provisioner exited $code on SIGTERM, expected 143"

printf 'SMOKE PASS\n'

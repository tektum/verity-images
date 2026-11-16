#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37,
# kube-controller-manager 1.37 (PV binder and protection controllers) and
# kubectl 1.35, pinned by digest.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kcm_index=ghcr.io/tektum/kube-controller-manager@sha256:47da4fa151dff2e2992f2fc09d2be3c98612e51396f09087fcf57f7aa868d428
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332

provisioner_name=k8s-sigs.io/nfs-subdir-external-provisioner
nfs_server=nfs.verity.test
nfs_path=/exports/k8s

id=$$
network="verity-nfs-$id"
etcd="verity-nfs-etcd-$id"
api="verity-nfs-api-$id"
kcm="verity-nfs-kcm-$id"
prov="verity-nfs-prov-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$prov" "$kcm" "$api"; do
    printf -- '--- %s\n' "$c" >&2
    docker logs "$c" 2>&1 | tail -n 30 >&2 || true
  done
  exit 1
}

cleanup() {
  docker rm -f "$prov" "$kcm" "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  # The export and the volume data are root-owned; the etcd peer image carries rm.
  if [ -n "$etcd_image" ]; then
    docker run --rm --network none --user 0 --entrypoint /bin/rm -v "$work:/work" \
      "$etcd_image" -rf /work/export >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
etcd_image=
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# Root like the upstream image, so it can manage a root-owned export.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 0 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/nfs-subdir-external-provisioner"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'

run() {
  docker run --rm --network none --read-only --tmpfs /tmp --cap-drop=ALL "$@"
}

# expect_fatal MESSAGE ENV...: the provisioner refuses to start with MESSAGE.
expect_fatal() {
  message=$1
  shift
  status=0
  run "$@" "$image" >"$work/fatal" 2>&1 || status=$?
  test "$status" -ne 0 || fail "provisioner unexpectedly started without: $message"
  grep -F -e "$message" "$work/fatal" >/dev/null ||
    fail "diagnostic '$message' is missing: $(cat "$work/fatal")"
}
expect_fatal 'NFS_SERVER not set'
expect_fatal 'NFS_PATH not set' -e NFS_SERVER="$nfs_server"
expect_fatal 'environment variable PROVISIONER_NAME is not set' \
  -e NFS_SERVER="$nfs_server" -e NFS_PATH="$nfs_path"
# Without KUBECONFIG it needs an in-cluster service account.
expect_fatal 'Failed to create config' \
  -e NFS_SERVER="$nfs_server" -e NFS_PATH="$nfs_path" -e PROVISIONER_NAME="$provisioner_name"

# The upstream image installs the binary at /nfs-subdir-external-provisioner.
status=0
run --entrypoint /nfs-subdir-external-provisioner "$image" >"$work/compat" 2>&1 || status=$?
if [ "$status" -eq 0 ] || ! grep -F 'NFS_SERVER not set' "$work/compat" >/dev/null; then
  fail "compatibility path /nfs-subdir-external-provisioner does not run: $(cat "$work/compat")"
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
etcd_image=$(pull_child "$etcd_index")
api_image=$(pull_child "$api_index")
kcm_image=$(pull_child "$kcm_index")
kubectl_image=$(pull_child "$kubectl_index")

# Control plane: etcd and kube-apiserver with a static admin token.
mkdir -p "$work/pki" "$work/kube" "$work/export"
# Stands in for the NFS export the provisioner mounts at /persistentvolumes:
# root-owned 0755 as on a typical no_root_squash export.
docker run --rm --network none --user 0 --entrypoint /bin/sh -v "$work:/work" "$etcd_image" \
  -c 'chown 0:0 /work/export && chmod 0755 /work/export' || fail 'could not prepare the export'
openssl genrsa -out "$work/pki/sa.key" 2048 2>/dev/null || fail 'could not generate the service account key'
token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
printf '%s,verity-admin,verity-admin,system:masters\n' "$token" >"$work/pki/tokens.csv"
chmod 0644 "$work/pki/sa.key" "$work/pki/tokens.csv"
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
chmod 0644 "$work/kube/config"

docker network create "$network" >/dev/null
docker run -d --name "$etcd" --network "$network" --tmpfs /var/lib/etcd:uid=65532,gid=65532 \
  "$etcd_image" --data-dir=/var/lib/etcd/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls="http://$etcd:2379" >/dev/null
docker run -d --name "$api" --network "$network" --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/pki:/pki:ro" "$api_image" \
  --etcd-servers="http://$etcd:2379" --secure-port=6443 --cert-dir=/tmp \
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC \
  --service-account-issuer=https://kubernetes.default.svc \
  --service-account-key-file=/pki/sa.key --service-account-signing-key-file=/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/16 >/dev/null

kubectl() {
  docker run --rm -i --network "$network" -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config \
    "$kubectl_image" "$@"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

# The PV controller binds claims to the provisioned volumes, marks released
# volumes, and drops the protection finalizers once objects are unused.
docker run -d --name "$kcm" --network "$network" --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/kube:/kube:ro" "$kcm_image" \
  --kubeconfig=/kube/config --authentication-kubeconfig=/kube/config \
  --authorization-kubeconfig=/kube/config --cert-dir=/tmp --leader-elect=false \
  --controllers=persistentvolume-binder-controller,persistentvolume-protection-controller,persistentvolumeclaim-protection-controller \
  >/dev/null

kubectl apply -f - >"$work/apply" 2>&1 <<EOF || fail "could not create storage classes: $(cat "$work/apply")"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-archive
provisioner: $provisioner_name
reclaimPolicy: Delete
volumeBindingMode: Immediate
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-delete
provisioner: $provisioner_name
reclaimPolicy: Delete
parameters:
  archiveOnDelete: "false"
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-retain
provisioner: $provisioner_name
reclaimPolicy: Delete
parameters:
  onDelete: retain
  pathPattern: \${.PVC.namespace}/\${.PVC.annotations.nfs.io/storage-path}
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: other-provisioner
provisioner: example.com/not-nfs
EOF

# Only the capabilities a root process needs to manage files owned by others.
docker run -d --name "$prov" --network "$network" --read-only --tmpfs /tmp \
  --cap-drop=ALL --cap-add=CHOWN --cap-add=DAC_OVERRIDE --cap-add=FOWNER \
  -v "$work/kube:/kube:ro" -v "$work/export:/persistentvolumes" \
  -e KUBECONFIG=/kube/config -e NFS_SERVER="$nfs_server" -e NFS_PATH="$nfs_path" \
  -e PROVISIONER_NAME="$provisioner_name" \
  "$image" >/dev/null

# claim NAME CLASS [ANNOTATION]: create a 1Gi claim in the default namespace.
claim() {
  kubectl apply -f - >"$work/claim" 2>&1 <<EOF || fail "could not create claim $1: $(cat "$work/claim")"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $1
  namespace: default
  annotations:
    nfs.io/storage-path: ${3:-unused}
spec:
  storageClassName: $2
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 1Gi
EOF
}

# bound NAME: wait until the claim is Bound and print its volume name.
bound() {
  i=0
  until phase=$(kubectl get pvc "$1" -n default -o 'jsonpath={.status.phase}' 2>/dev/null) &&
    [ "$phase" = Bound ]; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || fail "claim $1 did not bind (phase '${phase:-}')"
    sleep 2
  done
  kubectl get pvc "$1" -n default -o 'jsonpath={.spec.volumeName}'
}

# check_pv PV CLAIM SUBDIR: the PV points at SUBDIR of the NFS export.
check_pv() {
  kubectl get pv "$1" -o \
    'jsonpath={.spec.nfs.server}|{.spec.nfs.path}|{.spec.claimRef.name}|{.status.phase}|{.metadata.annotations.pv\.kubernetes\.io/provisioned-by}|{.spec.persistentVolumeReclaimPolicy}' \
    >"$work/pv" || fail "cannot read PV $1"
  expected="$nfs_server|$nfs_path/$3|$2|Bound|$provisioner_name|Delete"
  test "$(cat "$work/pv")" = "$expected" ||
    fail "PV $1 is '$(cat "$work/pv")', expected '$expected'"
  test -d "$work/export/$3" || fail "volume directory $3 was not created on the export"
  test "$(stat -c %a "$work/export/$3")" = 777 ||
    fail "volume directory $3 has mode $(stat -c %a "$work/export/$3")"
  test "$(stat -c %u "$work/export/$3")" = 0 || fail "volume directory $3 is not root-owned"
  # A pod running as another UID writes into the world-writable volume.
  docker run --rm --network none --user 2000:2000 --entrypoint /bin/sh -v "$work/export:/export" \
    "$etcd_image" -c "mkdir /export/$3/sub && printf 'payload %s\\n' '$2' >/export/$3/sub/data" ||
    fail "volume directory $3 is not writable by a pod"
}

claim data-archive nfs-archive
claim data-delete nfs-delete
claim data-retain nfs-retain team-a/data
claim data-other other-provisioner

pv_archive=$(bound data-archive)
dir_archive="default-data-archive-$pv_archive"
check_pv "$pv_archive" data-archive "$dir_archive"
pv_delete=$(bound data-delete)
dir_delete="default-data-delete-$pv_delete"
check_pv "$pv_delete" data-delete "$dir_delete"
pv_retain=$(bound data-retain)
dir_retain=default/team-a/data
check_pv "$pv_retain" data-retain "$dir_retain"

# A claim for another provisioner is left alone.
test "$(kubectl get pvc data-other -n default -o 'jsonpath={.status.phase}')" = Pending ||
  fail 'claim for another provisioner left Pending'
test "$(find "$work/export" -mindepth 1 -maxdepth 1 | wc -l)" = 3 ||
  fail "unexpected export entries: $(ls "$work/export")"

# gone PV: wait until the released volume object is deleted.
gone() {
  i=0
  until ! kubectl get pv "$1" >/dev/null 2>"$work/pv-err" &&
    grep -F NotFound "$work/pv-err" >/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || fail "released PV $1 was not deleted"
    sleep 2
  done
}

kubectl delete pvc data-archive data-delete data-retain -n default >/dev/null ||
  fail 'could not delete the claims'
gone "$pv_archive"
gone "$pv_delete"
gone "$pv_retain"

# Default class: the directory is renamed to archived-<dir> with its data.
test ! -e "$work/export/$dir_archive" || fail "archived volume $dir_archive is still in place"
test "$(cat "$work/export/archived-$dir_archive/sub/data")" = 'payload data-archive' ||
  fail "archived-$dir_archive does not hold the volume data"
# archiveOnDelete=false removes the directory.
test ! -e "$work/export/$dir_delete" || fail "volume $dir_delete was not removed"
test ! -e "$work/export/archived-$dir_delete" || fail "volume $dir_delete was archived"
# onDelete=retain keeps the directory untouched.
test "$(cat "$work/export/$dir_retain/sub/data")" = 'payload data-retain' ||
  fail "retained volume $dir_retain lost its data"

# The provisioner keeps running and stops on SIGTERM.
test "$(docker inspect --format '{{.State.Running}}' "$prov")" = true ||
  fail 'provisioner exited during the test'
docker stop -t 30 "$prov" >/dev/null
test "$(docker inspect --format '{{.State.OOMKilled}} {{.State.ExitCode}}' "$prov")" != 'false 137' ||
  fail 'provisioner ignored SIGTERM'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35, pinned by digest.
etcd_image=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_image=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_image=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332

id=$$
network="verity-localpv-$id"
etcd="verity-localpv-etcd-$id"
api="verity-localpv-api-$id"
prov="verity-localpv-prov-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$prov" "$api"; do
    printf -- '--- %s\n' "$c" >&2
    docker logs "$c" 2>&1 | tail -n 30 >&2 || true
  done
  exit 1
}

cleanup() {
  docker rm -f "$prov" "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  # The provisioner creates volume directories as UID 65532.
  docker run --rm --network none --user 0 --entrypoint /bin/rm -v "$work:/work" "$image" \
    -rf /work/host >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/provisioner-localpv"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

# klog writes log files to /tmp, so a read-only root needs a writable /tmp.
run() {
  docker run --rm --network none --read-only --tmpfs /tmp --cap-drop=ALL "$@"
}

# CLI surface.
run "$image" --help >"$work/help" 2>&1 || fail "help failed: $(cat "$work/help")"
for flag in --node-deployment --allow-insecure-pvc-basepath-override --analytics-lease-duration; do
  grep -F -e "$flag" "$work/help" >/dev/null || fail "help is missing $flag"
done
status=0
run "$image" --definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Upstream images install the binary under /usr/local/bin; that path still runs.
run --entrypoint /usr/local/bin/provisioner-localpv "$image" --help >/dev/null 2>&1 ||
  fail 'compatibility path /usr/local/bin/provisioner-localpv does not run'

# Node mode runs its volume and quota scripts with these tools from the image.
# shellcheck disable=SC2016 # the script expands inside the container
run --entrypoint /bin/sh "$image" -c '
  for tool in sh mkdir rm stat awk tail head touch flock xfs_quota xfs_io repquota setquota chattr lsattr; do
    command -v "$tool" >/dev/null || { echo "missing $tool"; exit 1; }
  done
  # The scripts use [[ ]] and stat -f on the volume directory.
  FS=$(stat -f -c %T /tmp)
  [[ "$FS" == "tmpfs" ]] || { echo "stat -f reported $FS"; exit 1; }
  xfs_quota -V && xfs_io -V && setquota --version && lsattr -V
' >"$work/tools" 2>&1 || fail "node-mode tools: $(cat "$work/tools")"

# Outside a cluster the provisioner refuses to start with a clear diagnostic.
status=0
run "$image" >"$work/nocluster" 2>&1 || status=$?
test "$status" -ne 0 || fail 'provisioner outside a cluster unexpectedly succeeded'
grep -F 'KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined' "$work/nocluster" >/dev/null ||
  fail "in-cluster diagnostic is missing: $(cat "$work/nocluster")"

# Control plane: etcd and kube-apiserver with a static admin token.
mkdir -p "$work/pki" "$work/kube" "$work/host"
chmod 0777 "$work/host"
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

kubectl apply -f - >"$work/apply" 2>&1 <<'EOF' || fail "could not create fixtures: $(cat "$work/apply")"
apiVersion: v1
kind: Namespace
metadata:
  name: openebs
---
apiVersion: v1
kind: Node
metadata:
  name: node1
  labels:
    kubernetes.io/hostname: node1
---
apiVersion: v1
kind: Node
metadata:
  name: node2
  labels:
    kubernetes.io/hostname: node2
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-hostpath
  annotations:
    openebs.io/cas-type: local
    cas.openebs.io/config: |
      - name: StorageType
        value: hostpath
      - name: BasePath
        value: /var/openebs/local
provisioner: openebs.io/local
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF

# The scheduler and the PV controller are absent, so the test sets the
# annotations they would set on a claim bound for a pod on a node.
claim() {
  kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $1
  namespace: default
  annotations:
    volume.kubernetes.io/selected-node: $2
    volume.kubernetes.io/storage-provisioner: openebs.io/local
spec:
  storageClassName: openebs-hostpath
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF
}

# Node mode as the upstream chart runs it: a DaemonSet pod per node with the
# host base path under /host. The default UID owns the bind-mounted base path.
docker run -d --name "$prov" --network "$network" --read-only --tmpfs /tmp --cap-drop=ALL -p 127.0.0.1::8081 \
  -v "$work/kube:/kube:ro" -v "$work/host:/host/var/openebs/local" \
  -e OPENEBS_IO_KUBE_CONFIG=/kube/config -e OPENEBS_NAMESPACE=openebs \
  -e NODE_NAME=node1 -e OPENEBS_IO_ENABLE_ANALYTICS=false \
  "$image" --node-deployment >/dev/null

probe=$(docker port "$prov" 8081/tcp | head -n 1)
[ -n "$probe" ] || fail 'health probe port is not published'
i=0
until curl -fsS "http://$probe/readyz" >"$work/readyz" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'provisioner did not become ready'
  sleep 2
done
curl -fsS "http://$probe/healthz" >"$work/healthz" || fail 'healthz failed'

claim data-node1 node1 >/dev/null || fail 'could not create the node1 claim'
claim data-node2 node2 >/dev/null || fail 'could not create the node2 claim'
uid=$(kubectl get pvc data-node1 -n default -o 'jsonpath={.metadata.uid}')
pv="pvc-$uid"

i=0
until kubectl get pv "$pv" -o 'jsonpath={.spec.local.path}' >"$work/path" 2>/dev/null &&
  [ -s "$work/path" ]; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "PV $pv was not provisioned"
  sleep 2
done
test "$(cat "$work/path")" = "/var/openebs/local/$pv" ||
  fail "unexpected PV path $(cat "$work/path")"
kubectl get pv "$pv" -o 'jsonpath={.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}' \
  >"$work/node"
test "$(cat "$work/node")" = node1 || fail "unexpected PV node affinity $(cat "$work/node")"
test "$(kubectl get pv "$pv" -o 'jsonpath={.metadata.annotations.pv\.kubernetes\.io/provisioned-by}')" = \
  openebs.io/local || fail 'PV is not marked as provisioned by openebs.io/local'
test -d "$work/host/$pv" || fail "volume directory $pv was not created on the node"

# A claim scheduled to another node is left to that node's provisioner.
uid2=$(kubectl get pvc data-node2 -n default -o 'jsonpath={.metadata.uid}')
sleep 5
if kubectl get pv "pvc-$uid2" >/dev/null 2>&1; then
  fail 'node1 provisioner provisioned a claim scheduled to node2'
fi
test ! -e "$work/host/pvc-$uid2" || fail 'node1 provisioner created a directory for node2'

# Deleting the claim releases the volume; the provisioner removes the
# directory with its cleanup script and deletes the PV.
printf 'payload\n' >"$work/host/$pv/data" 2>/dev/null ||
  docker exec "$prov" sh -c "printf 'payload\n' >/host/var/openebs/local/$pv/data"
kubectl delete pvc data-node1 -n default --wait=false >/dev/null
kubectl patch pv "$pv" --subresource=status --type=merge \
  -p '{"status":{"phase":"Released"}}' >/dev/null || fail 'could not release the PV'
# Without kube-controller-manager the pv-protection finalizer stays, so a
# deletion timestamp is the observable delete.
i=0
until deleted=$(kubectl get pv "$pv" -o 'jsonpath={.metadata.deletionTimestamp}' 2>"$work/pv-err");
  [ -n "$deleted" ] || grep -F NotFound "$work/pv-err" >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "released PV $pv was not deleted"
  sleep 2
done
test ! -e "$work/host/$pv" || fail "volume directory $pv was not removed"

docker logs "$prov" 2>&1 | grep -F 'Successfully deleted volume' >/dev/null ||
  fail 'volume deletion log line is missing'

# The provisioner keeps running and stops cleanly on SIGTERM.
test "$(docker inspect --format '{{.State.Running}}' "$prov")" = true ||
  fail 'provisioner exited during the test'
docker stop -t 30 "$prov" >/dev/null
rc=$(docker inspect --format '{{.State.ExitCode}}' "$prov")
test "$rc" = 0 || fail "provisioner exit code $rc after SIGTERM"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"

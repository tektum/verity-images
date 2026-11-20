#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35, pinned by digest. DNS client: the catalog coredns image ships
# Wolfi bind-tools (dig).
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332
client_image='ghcr.io/tektum/coredns@sha256:efa6111f5e1daabd2c273812638c4ea6a3dbfc2466c76ec31d915e0d94541b1e'

id=$$
network="verity-k8sgw-$id"
etcd="verity-k8sgw-etcd-$id"
api="verity-k8sgw-api-$id"
gateway="verity-k8sgw-gw-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$gateway" 2>&1 | tail -n 20 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f "$gateway" "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# OCI contract: the upstream /coredns entrypoint, the Helm chart's Corefile
# path as the default argument, and a non-root user.
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/coredns"]' ||
  fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["-conf","/etc/coredns/Corefile"]' || fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'

# Like the upstream chart: read-only root, every capability dropped.
run() {
  docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges "$@"
}

# CoreDNS with the k8s_gateway plugin, in the upstream version format.
run --network none "$image" -version >"$work/version" 2>&1 ||
  fail "-version failed: $(cat "$work/version")"
grep -E "^CoreDNS-[0-9]+\.[0-9]+\.[0-9]+\+k8s_gateway-$expected_version$" "$work/version" >/dev/null ||
  fail "unexpected version output: $(cat "$work/version")"
grep -E "^linux/(amd64|arm64), go1\.[0-9.]+, v$expected_version$" "$work/version" >/dev/null ||
  fail "version is missing the v$expected_version commit stamp: $(cat "$work/version")"
run --network none "$image" -plugins >"$work/plugins" 2>&1 || fail '-plugins failed'
grep -Ex '(  dns\.)?k8s_gateway' "$work/plugins" >/dev/null || fail 'k8s_gateway plugin is not registered'

mkdir -p "$work/conf" "$work/kube" "$work/pki"
cat >"$work/conf/Corefile" <<'EOF'
.:1053 {
    errors
    log
    health :8080
    ready :8181
    k8s_gateway example.test {
        resources Service
        ttl 10
        kubeconfig /kube/config smoke
    }
}
EOF
cat >"$work/conf/invalid" <<'EOF'
.:1053 {
    k8s_gateway example.test {
        definitely-not-a-property
    }
}
EOF
cat >"$work/conf/incluster" <<'EOF'
.:1053 {
    k8s_gateway example.test
}
EOF

# Negative cases fail fast with a diagnostic instead of serving: no Corefile
# at the default path, an unknown plugin property, and no cluster at all.
rejects() { # expected-message docker-run-args...
  want=$1
  shift
  status=0
  timeout 30 docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges \
    --network none -v "$work/conf:/etc/coredns:ro" "$@" >"$work/rejected" 2>&1 || status=$?
  test "$status" -ne 0 || fail "unexpectedly started: $*"
  test "$status" -ne 124 || fail "did not fail fast: $*"
  grep -F -e "$want" "$work/rejected" >/dev/null ||
    fail "diagnostic '$want' is missing: $(cat "$work/rejected")"
}
chmod 0644 "$work/conf/Corefile" "$work/conf/invalid" "$work/conf/incluster"
rejects 'open /etc/coredns/missing: no such file or directory' "$image" -conf /etc/coredns/missing
rejects "Unknown property 'definitely-not-a-property'" "$image" -conf /etc/coredns/invalid
rejects 'unable to load in-cluster configuration' "$image" -conf /etc/coredns/incluster

# The default argument expects the chart's mounted Corefile.
status=0
run --network none "$image" >"$work/default" 2>&1 || status=$?
test "$status" -ne 0 || fail 'started without a mounted Corefile'
grep -F 'open /etc/coredns/Corefile: no such file or directory' "$work/default" >/dev/null ||
  fail "missing default Corefile diagnostic: $(cat "$work/default")"

# Control plane: etcd and kube-apiserver with a static admin token.
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
chmod 0644 "$work/pki/sa.key" "$work/pki/tokens.csv" "$work/kube/config"

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
# The publish job runs this test per architecture against one daemon, so an
# index digest must never be passed straight to docker run.
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
kubectl_image=$(pull_child "$kubectl_index")

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

# A LoadBalancer Service with an assigned address, as a cloud controller would
# publish it, before the gateway starts.
kubectl create namespace demo >/dev/null || fail 'could not create namespace demo'
kubectl apply -f - >/dev/null <<'EOF' || fail 'could not create service web'
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: demo
spec:
  type: LoadBalancer
  selector:
    app: web
  ports:
    - port: 80
EOF
set_lb() { # ip
  kubectl -n demo patch service web --subresource=status --type=merge \
    -p "{\"status\":{\"loadBalancer\":{\"ingress\":[{\"ip\":\"$1\"}]}}}" >/dev/null ||
    fail "could not set the load balancer address $1"
}
set_lb 192.0.2.10

# The gateway runs out of cluster with the kubeconfig, as UID 65532 on a
# read-only root with every capability dropped, and health on 8080.
docker run -d --name "$gateway" --network "$network" --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges -p 127.0.0.1::8080 \
  -v "$work/conf:/etc/coredns:ro" -v "$work/kube:/kube:ro" "$image" >/dev/null ||
  fail 'gateway did not start'

client_platform="linux/$(docker version --format '{{.Server.Arch}}')"
dig_gw() {
  docker run --rm --platform "$client_platform" --network "container:$gateway" --cap-drop=ALL \
    --entrypoint dig "$client_image" -p 1053 @127.0.0.1 +time=2 +tries=1 "$@"
}
expect_a() { # name want
  i=0
  until [ "$(dig_gw "$1" A +short 2>/dev/null || true)" = "$2" ]; do
    i=$((i + 1))
    [ "$i" -lt 30 ] || fail "$1 did not resolve to $2"
    sleep 1
  done
}

expect_a web.demo.example.test 192.0.2.10

health_port=$(docker port "$gateway" 8080/tcp | head -n 1 | sed 's/.*://')
[ -n "$health_port" ] || fail 'health port is not published'
test "$(curl -fsS "http://127.0.0.1:$health_port/health")" = OK || fail '/health did not return OK'

# Unknown names in the zone are NXDOMAIN, and the zone apex has an SOA.
dig_gw missing.demo.example.test A >"$work/missing" || fail 'query for a missing name failed'
grep -F 'status: NXDOMAIN' "$work/missing" >/dev/null ||
  fail "missing name was not NXDOMAIN: $(cat "$work/missing")"
dig_gw example.test SOA +short >"$work/soa" || fail 'SOA query failed'
grep -E '^dns1\.kube-system\.example\.test\. hostmaster\.dns1\.kube-system\.example\.test\. ' \
  "$work/soa" >/dev/null || fail "unexpected apex SOA: $(cat "$work/soa")"

# The informer follows changes: a new load balancer address is served.
set_lb 192.0.2.20
expect_a web.demo.example.test 192.0.2.20

docker stop "$gateway" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$gateway")" = 0 ||
  fail 'gateway did not exit cleanly on SIGTERM'
printf 'SMOKE PASS image=%s\n' "$image"

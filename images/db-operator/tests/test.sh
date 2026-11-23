#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35; the managed database server: Verity PostgreSQL 18. All pinned
# by digest.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332
postgres_index=ghcr.io/tektum/postgres-18-trixie@sha256:344fb505d9ffee93562e867666a4a3294cc3ada80f06e29ae2199b6cfc49b50a

id=$$
network="verity-dbop-$id"
etcd="verity-dbop-etcd-$id"
api="verity-dbop-api-$id"
postgres="verity-dbop-pg-$id"
operator="verity-dbop-op-$id"
crds="verity-dbop-crds-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$operator" 2>&1 | tail -n 30 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f "$operator" "$crds" "$postgres" "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# OCI contract: upstream's entrypoint, no default command, UID 1001.
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/local/bin/db-operator"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1001 ||
  fail 'unexpected OCI user'

# Like the upstream chart: read-only root, every capability dropped, non-root.
run() {
  docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges "$@"
}

run --network none "$image" --help >"$work/help" 2>&1 || fail "--help failed: $(cat "$work/help")"
for word in controller webhook; do
  grep -E "^ +$word" "$work/help" >/dev/null || fail "help is missing the $word command"
done
# The chart runs `db-operator controller` through PATH.
run --network none --entrypoint db-operator "$image" --help >/dev/null 2>&1 ||
  fail 'db-operator is not on PATH'

# Unknown command.
status=0
run --network none "$image" definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'unknown command unexpectedly succeeded'
grep -F 'unexpected argument definitely-invalid' "$work/invalid" >/dev/null ||
  fail "unknown command diagnostic is missing: $(cat "$work/invalid")"

# No cluster: the controller fails fast instead of waiting.
status=0
timeout 30 docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --network none "$image" controller >"$work/nocluster" 2>&1 || status=$?
test "$status" -ne 0 || fail 'controller started without a cluster'
test "$status" -ne 124 || fail 'controller did not fail fast without a cluster'
grep -F 'unable to get kubeconfig' "$work/nocluster" >/dev/null ||
  fail "no-cluster diagnostic is missing: $(cat "$work/nocluster")"

# CRDs shipped with the binary.
docker create --name "$crds" "$image" >/dev/null
docker cp "$crds:/usr/share/db-operator/crd" "$work/crd" >/dev/null 2>&1 || fail 'CRDs are missing'
docker rm "$crds" >/dev/null
for kind in databases dbinstances dbusers; do
  grep -Fx "  name: $kind.kinda.rocks" "$work/crd/kinda.rocks_$kind.yaml" >/dev/null ||
    fail "CRD $kind.kinda.rocks is missing"
done

# Control plane: etcd and kube-apiserver with a static admin token.
mkdir -p "$work/pki" "$work/kube" "$work/config" "$work/manifests"
openssl genrsa -out "$work/pki/sa.key" 2048 2>/dev/null || fail 'could not generate the service account key'
token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
pg_password=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
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
printf 'serverVersionTTL: 1h\n' >"$work/config/config.yaml"
printf 'serverVersionTTL: [not-a-duration\n' >"$work/config/broken.yaml"
cp "$work/crd/"*.yaml "$work/manifests/"
cat >"$work/manifests/resources.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: apps
---
apiVersion: v1
kind: Secret
metadata:
  name: pg-admin
  namespace: apps
stringData:
  user: postgres
  password: $pg_password
---
apiVersion: kinda.rocks/v1
kind: DbInstance
metadata:
  name: pg
spec:
  engine: postgres
  auth:
    username:
      valueFrom:
        secret:
          name: pg-admin
          namespace: apps
          key: user
    password:
      valueFrom:
        secret:
          name: pg-admin
          namespace: apps
          key: password
  endpoint:
    host:
      value: postgres
    port:
      value: "5432"
EOF
cat >"$work/manifests/database.yaml" <<'EOF'
apiVersion: kinda.rocks/v1beta1
kind: Database
metadata:
  name: shop
  namespace: apps
spec:
  instance: pg
  postgres: {}
  secretName: shop-credentials
  deletionProtected: false
  backup:
    enable: false
    cron: ""
EOF
chmod 0644 "$work/pki/sa.key" "$work/pki/tokens.csv" "$work/kube/config" "$work/config/"*.yaml \
  "$work/manifests/"*.yaml

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
postgres_image=$(pull_child "$postgres_index")

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
docker run -d --name "$postgres" --network "$network" --network-alias postgres \
  -e POSTGRES_PASSWORD="$pg_password" "$postgres_image" >/dev/null

kubectl() {
  docker run --rm -i --network "$network" -v "$work/kube:/kube:ro" \
    -v "$work/manifests:/manifests:ro" -e KUBECONFIG=/kube/config "$kubectl_image" "$@"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done
i=0
until docker exec "$postgres" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'postgres did not become ready'
  sleep 1
done

for kind in databases dbinstances dbusers; do
  kubectl apply --server-side -f "/manifests/kinda.rocks_$kind.yaml" >/dev/null ||
    fail "could not install CRD $kind.kinda.rocks"
done
kubectl wait --for=condition=Established --timeout=60s \
  crd/databases.kinda.rocks crd/dbinstances.kinda.rocks crd/dbusers.kinda.rocks >/dev/null ||
  fail 'CRDs were not established'
kubectl apply -f /manifests/resources.yaml >/dev/null || fail 'could not create the DbInstance'

# operator ARGS...: the controller out of cluster, as the chart runs it.
operator() {
  docker run "$@" --network "$network" --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges -v "$work/kube:/kube:ro" -v "$work/config:/run/config:ro" \
    -e KUBECONFIG=/kube/config -e DBO_RECONCILE_INTERVAL=5s --entrypoint db-operator "$image" controller
}

# A broken config file fails before any reconcile.
status=0
timeout 60 docker run --rm --network "$network" --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges -v "$work/kube:/kube:ro" -v "$work/config:/run/config:ro" \
  -e KUBECONFIG=/kube/config -e DBO_CONFIG=/run/config/broken.yaml \
  --entrypoint db-operator "$image" controller >"$work/broken" 2>&1 || status=$?
test "$status" -ne 0 || fail 'controller started with a broken config'
test "$status" -ne 124 || fail 'controller did not fail fast with a broken config'
grep -F 'An error occurred when reading the config' "$work/broken" >/dev/null ||
  fail "broken config diagnostic is missing: $(cat "$work/broken")"

operator -d --name "$operator" -p 127.0.0.1::8081 -e DBO_CONFIG=/run/config/config.yaml >/dev/null ||
  fail 'controller did not start'

# Health probes on 8081.
probe_port=$(docker port "$operator" 8081/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$probe_port" ] || fail 'probe port is not published'
probe() {
  [ "$(curl -fsS --max-time 5 "http://127.0.0.1:$probe_port/$1" 2>/dev/null)" = ok ]
}
i=0
until probe healthz && probe readyz; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'health probes did not become ok'
  sleep 1
done

# The DbInstance connects to PostgreSQL.
i=0
until [ "$(kubectl get dbinstance pg \
  -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null)" = True ]; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "DbInstance did not connect: $(kubectl get dbinstance pg -o yaml 2>&1)"
  sleep 2
done
test "$(kubectl get dbinstance pg -o jsonpath='{.status.operatorVersion}')" = "$expected_version" ||
  fail 'DbInstance status.operatorVersion does not carry the release version'

# A Database is reconciled into a real database, role, and credentials Secret.
kubectl apply -f /manifests/database.yaml >/dev/null || fail 'could not create the Database'
i=0
until [ "$(kubectl -n apps get database shop -o jsonpath='{.status.status}' 2>/dev/null)" = true ]; do
  i=$((i + 1))
  [ "$i" -lt 90 ] || fail "Database was not reconciled: $(kubectl -n apps get database shop -o yaml 2>&1)"
  sleep 2
done
test "$(kubectl -n apps get database shop -o jsonpath='{.status.operatorVersion}')" = "$expected_version" ||
  fail 'status.operatorVersion does not carry the release version'

secret() { # key
  kubectl -n apps get secret shop-credentials -o "jsonpath={.data.$1}" | base64 -d
}
db_name=$(secret POSTGRES_DB) || fail 'credentials Secret is missing POSTGRES_DB'
db_user=$(secret POSTGRES_USER) || fail 'credentials Secret is missing POSTGRES_USER'
db_password=$(secret POSTGRES_PASSWORD) || fail 'credentials Secret is missing POSTGRES_PASSWORD'
test "$db_name" = apps-shop || fail "unexpected database name $db_name"
[ -n "$db_user" ] && [ -n "$db_password" ] || fail 'generated credentials are empty'

# The generated role logs in to the generated database and can write to it.
docker exec -e PGPASSWORD="$db_password" "$postgres" psql -h 127.0.0.1 -U "$db_user" -d "$db_name" \
  -v ON_ERROR_STOP=1 -tA -c 'create table smoke (id int); insert into smoke values (42); select id from smoke' \
  >"$work/psql" 2>&1 || fail "generated credentials do not work: $(cat "$work/psql")"
test "$(tail -n 1 "$work/psql")" = 42 || fail "unexpected query result: $(cat "$work/psql")"

# Deleting the Database drops it from PostgreSQL.
kubectl -n apps delete database shop --timeout=120s >/dev/null || fail 'could not delete the Database'
i=0
while [ "$(docker exec "$postgres" psql -U postgres -tA \
  -c "select count(*) from pg_database where datname = 'apps-shop'")" != 0 ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'database apps-shop was not dropped'
  sleep 1
done

docker stop "$operator" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$operator")" = 0 ||
  fail 'controller did not exit cleanly on SIGTERM'
printf 'SMOKE PASS image=%s\n' "$image"

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane and upstream: Verity etcd 3.7,
# kube-apiserver 1.37, kubectl and nginx, pinned by index digest.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332
nginx_index=ghcr.io/tektum/nginx@sha256:1f15c75985329f5ff751ded753e4f80eea80e1e0a18bd7728e2e9bf3bd4bfc15

id=$$
network="verity-krp-$id"
etcd="verity-krp-etcd-$id"
api="verity-krp-api-$id"
upstream="verity-krp-upstream-$id"
proxy="verity-krp-proxy-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$proxy" 2>&1 | tail -n 20 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f "$proxy" "$upstream" "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml")
[ -n "$version" ] || fail 'could not read the recipe version'

# OCI contract of the upstream image: UID 65532 and the binary as entrypoint.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/local/bin/kube-rbac-proxy"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'

run() {
  docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges "$@"
}

# Version stamps from the upstream Makefile ldflags.
run --network none "$image" --version >"$work/version" 2>&1 ||
  fail "version failed: $(cat "$work/version")"
grep -Fx "kube-rbac-proxy v$version" "$work/version" >/dev/null ||
  fail "unexpected version output: $(cat "$work/version")"

run --network none "$image" --help >"$work/help" 2>&1 || fail "help failed: $(cat "$work/help")"
for flag in --secure-listen-address --upstream --auth-header-fields-enabled --ignore-paths --kubeconfig; do
  grep -F -e "$flag" "$work/help" >/dev/null || fail "help is missing $flag"
done

# Negative cases: unknown flag and conflicting path filters.
status=0
run --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'unknown flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail "unknown flag diagnostic is missing: $(cat "$work/invalid")"
status=0
run --network none "$image" --secure-listen-address=:8443 --upstream=http://127.0.0.1:1/ \
  --allow-paths=/a --ignore-paths=/b >"$work/conflict" 2>&1 || status=$?
test "$status" -ne 0 || fail 'conflicting path filters unexpectedly succeeded'
grep -F 'cannot use --allow-paths and --ignore-paths together' "$work/conflict" >/dev/null ||
  fail "path filter diagnostic is missing: $(cat "$work/conflict")"

# Control plane with static tokens: an admin, the proxy's own identity, a
# reader allowed to GET /metrics and a user without any grant.
mkdir -p "$work/pki" "$work/kube" "$work/proxy" "$work/nginx"
openssl genrsa -out "$work/pki/sa.key" 2048 2>/dev/null || fail 'could not generate the service account key'
tok() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
admin_token=$(tok)
proxy_token=$(tok)
reader_token=$(tok)
stranger_token=$(tok)
{
  printf '%s,verity-admin,verity-admin,system:masters\n' "$admin_token"
  printf '%s,verity-proxy,verity-proxy\n' "$proxy_token"
  printf '%s,verity-reader,verity-reader\n' "$reader_token"
  printf '%s,verity-stranger,verity-stranger\n' "$stranger_token"
} >"$work/pki/tokens.csv"
kubeconfig() { # token
  cat <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: smoke
    cluster:
      server: https://$api:6443
      insecure-skip-tls-verify: true
users:
  - name: user
    user:
      token: $1
contexts:
  - name: smoke
    context:
      cluster: smoke
      user: user
current-context: smoke
EOF
}
kubeconfig "$admin_token" >"$work/kube/config"
kubeconfig "$proxy_token" >"$work/proxy/config"

# The upstream echoes the request path and the identity header the proxy adds.
cat >"$work/nginx/nginx.conf" <<'EOF'
worker_processes 1;
error_log stderr;
pid /tmp/nginx.pid;
events {}
http {
  access_log off;
  client_body_temp_path /tmp/body;
  proxy_temp_path /tmp/proxy;
  fastcgi_temp_path /tmp/fastcgi;
  uwsgi_temp_path /tmp/uwsgi;
  scgi_temp_path /tmp/scgi;
  server {
    listen 8080;
    location / {
      default_type text/plain;
      return 200 "verity-upstream path=$uri user=$http_x_remote_user\n";
    }
  }
}
EOF
chmod 0644 "$work/pki/sa.key" "$work/pki/tokens.csv" "$work/kube/config" "$work/proxy/config" \
  "$work/nginx/nginx.conf"

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
kubectl_image=$(pull_child "$kubectl_index")
nginx_image=$(pull_child "$nginx_index")

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
docker run -d --name "$upstream" --network "$network" --network-alias upstream \
  -v "$work/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" "$nginx_image" >/dev/null

kubectl() {
  docker run --rm -i --network "$network" -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config \
    "$kubectl_image" "$@"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "kube-apiserver did not become ready: $(docker logs "$api" 2>&1 | tail -n 20)"
  sleep 2
done

# The proxy may create TokenReviews and SubjectAccessReviews; the reader may
# GET the non-resource URL /metrics and nothing else.
kubectl apply -f - >"$work/apply" 2>&1 <<'EOF' || fail "RBAC setup failed: $(cat "$work/apply")"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: verity-proxy-auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: verity-proxy
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: verity-metrics-reader
rules:
  - nonResourceURLs: [/metrics]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: verity-metrics-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: verity-metrics-reader
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: verity-reader
EOF

# The proxy runs out of cluster on a read-only root filesystem with a
# self-signed serving certificate, delegating authn and authz to the API server.
docker run -d --name "$proxy" --network "$network" --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges -p 127.0.0.1::8443 -v "$work/proxy:/kube:ro" "$image" \
  --kubeconfig=/kube/config --secure-listen-address=0.0.0.0:8443 \
  --upstream=http://upstream:8080/ --auth-header-fields-enabled --ignore-paths=/public \
  --v=2 >/dev/null
port=$(docker port "$proxy" 8443/tcp | sed -n 's/^127\.0\.0\.1:\([0-9]*\)$/\1/p' | sed -n 1p)
[ -n "$port" ] || fail 'proxy port is not published'

# request PATH [TOKEN]: print the HTTP status, keeping the body in $work/body.
request() {
  if [ -n "${2:-}" ]; then
    curl -sk -o "$work/body" -w '%{http_code}' -H "Authorization: Bearer $2" \
      "https://127.0.0.1:$port$1" || true
  else
    curl -sk -o "$work/body" -w '%{http_code}' "https://127.0.0.1:$port$1" || true
  fi
}

i=0
until [ "$(request /metrics)" = 401 ]; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-rbac-proxy did not become ready'
  sleep 1
done

expect() { # description expected-status path [token]
  got=$(request "$3" "${4:-}")
  test "$got" = "$2" || fail "$1: expected HTTP $2, got $got: $(cat "$work/body")"
}

# Allowed token: TokenReview authenticates and SubjectAccessReview allows, so
# the upstream answers and sees the authenticated user.
expect 'authorized reader' 200 /metrics "$reader_token"
grep -Fx 'verity-upstream path=/metrics user=verity-reader' "$work/body" >/dev/null ||
  fail "unexpected upstream content: $(cat "$work/body")"

# No token and an unknown token are rejected before reaching the upstream.
expect 'unauthenticated request' 401 /metrics
grep -F verity-upstream "$work/body" >/dev/null && fail 'unauthenticated request reached the upstream'
expect 'unknown token' 401 /metrics "$(tok)"

# Authenticated but unauthorized users get 403, including the reader on a path
# its role does not grant.
expect 'unauthorized user' 403 /metrics "$stranger_token"
grep -F verity-upstream "$work/body" >/dev/null && fail 'unauthorized request reached the upstream'
expect 'reader on an ungranted path' 403 /debug "$reader_token"

# --ignore-paths bypasses authentication and authorization.
expect 'ignored path' 200 /public
grep -Fx 'verity-upstream path=/public user=' "$work/body" >/dev/null ||
  fail "unexpected ignored path content: $(cat "$work/body")"

# Without --tls-cert-file the proxy serves a generated self-signed certificate.
docker logs "$proxy" >"$work/proxy.log" 2>&1
grep -F 'Generating self signed cert' "$work/proxy.log" >/dev/null ||
  fail "proxy did not use a self-signed certificate: $(tail -n 20 "$work/proxy.log")"

# SIGTERM shuts the proxy down cleanly.
docker stop -t 10 "$proxy" >/dev/null
test "$(docker inspect -f '{{.State.ExitCode}}' "$proxy")" = 0 ||
  fail "proxy exited $(docker inspect -f '{{.State.ExitCode}}' "$proxy") after SIGTERM"

echo 'SMOKE PASS'

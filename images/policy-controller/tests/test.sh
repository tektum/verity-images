#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
recipe_value() {
  awk -v key="$1" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml"
}
version=$(recipe_value version:)
commit=$(recipe_value source-commit:)

# Test peers, pinned by index digest and never part of the image: a real
# control plane (Verity etcd 3.7, kube-apiserver 1.37, kubectl 1.35). Every
# container runs without a network or on an --internal Docker network, and TUF
# is disabled or pointed at a closed local port, so nothing here can reach the
# Sigstore public-good instance (TUF CDN, Fulcio, Rekor).
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332

id=$$
label="verity-test=policy-controller-$id"
network="verity-pc-$id"
etcd="verity-pc-etcd-$id"
api="verity-pc-api-$id"
webhook="verity-pc-webhook-$id"
ns=cosign-system
work=$(mktemp -d)
# Bind-mount sources exist before the first run so Docker never creates them.
mkdir -p "$work/pki" "$work/kube" "$work/wkube"

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for name in "$webhook" "$api"; do
    docker logs "$name" >/dev/null 2>&1 || continue
    printf -- '--- logs: %s\n' "$name" >&2
    docker logs "$name" 2>&1 | tail -n 30 >&2 || true
  done
  exit 1
}

[ -n "$version" ] || fail 'could not read the recipe version'
[ -n "$commit" ] || fail 'could not read the recipe source commit'

# OCI contract of the upstream ko image: USER 65532, ENTRYPOINT /ko-app/webhook,
# no CMD, /ko-app on PATH.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/ko-app/webhook"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
envs=$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image")
printf '%s\n' "$envs" | grep -E '^PATH=(.*:)?/ko-app(:.*)?$' >/dev/null ||
  fail 'PATH does not include /ko-app'
printf '%s\n' "$envs" | grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

# Build contract from the embedded Go build information: the webhook command
# of the pinned module and commit, built without cgo.
probe="verity-pc-probe-$id"
docker create --name "$probe" --label "$label" "$image" >/dev/null || fail 'cannot create a probe container'
docker cp -L "$probe:/ko-app/webhook" "$work/bin" >/dev/null 2>&1 || fail 'cannot copy /ko-app/webhook'
docker rm "$probe" >/dev/null
tab=$(printf '\t')
grep -aE "path${tab}github\\.com/sigstore/policy-controller/cmd/webhook\$" "$work/bin" >/dev/null ||
  fail 'binary is not the policy-controller webhook command'
grep -aE "^mod${tab}github.com/sigstore/policy-controller${tab}v${version}(\\+dirty)?${tab}" \
  "$work/bin" >/dev/null || fail "binary does not embed module version v$version"
for setting in "vcs.revision=$commit" CGO_ENABLED=0 -trimpath=true; do
  grep -aFx "build${tab}${setting}" "$work/bin" >/dev/null || fail "build setting $setting is missing"
done

hardened() {
  docker run --rm --label "$label" --read-only --cap-drop=ALL --security-opt=no-new-privileges "$@"
}
offline() {
  hardened --network none --tmpfs /home/nonroot:uid=65532,gid=65532 "$@"
}

# --help prints the webhook flags and exits 0 before any TUF or cluster access.
offline "$image" --help >"$work/help" 2>&1 || fail "--help failed: $(cat "$work/help")"
for flag in disable-tuf tuf-mirror tuf-root secure-port webhook-name policy-resync-period; do
  grep -E "^  -$flag( |\$)" "$work/help" >/dev/null || fail "--help does not list -$flag"
done
grep -F '(default "https://tuf-repo-cdn.sigstore.dev")' "$work/help" >/dev/null ||
  fail '--help does not show the upstream TUF mirror default'

# Negative: unknown flags and malformed flag values are usage errors (exit 2).
status=0
offline "$image" --definitely-invalid >"$work/badflag" 2>&1 || status=$?
test "$status" -eq 2 || fail "unknown flag exited $status, want 2"
grep -F 'flag provided but not defined: -definitely-invalid' "$work/badflag" >/dev/null ||
  fail 'unknown flag diagnostic is absent'
status=0
offline "$image" --disable-tuf --secure-port=https >"$work/badport" 2>&1 || status=$?
test "$status" -eq 2 || fail "malformed --secure-port exited $status, want 2"
grep -F 'invalid value "https" for flag -secure-port' "$work/badport" >/dev/null ||
  fail 'malformed --secure-port diagnostic is absent'

# Negative: without a Kubernetes client configuration the webhook logs its
# release-utils version stamp and exits non-zero. The upstream path and the
# PATH-relative name reach the same binary.
for entry in /ko-app/webhook /usr/bin/policy-controller webhook; do
  status=0
  offline --entrypoint "$entry" "$image" --disable-tuf >"$work/noconfig" 2>&1 || status=$?
  test "$status" -ne 0 || fail "$entry started without a Kubernetes configuration"
  grep -F 'Error building kubeconfig: failed to create client config: invalid configuration: no configuration has been provided' \
    "$work/noconfig" >/dev/null || fail "$entry: missing kubeconfig diagnostic: $(cat "$work/noconfig")"
done
# release-utils reports the Go main module version, which carries +dirty when
# the build remediated a dependency; the tree state must agree with it.
grep -E "\"gitVersion\": \"v$version(\\+dirty)?\"" "$work/noconfig" >/dev/null ||
  fail "version stamp does not report v$version"
if grep -F '+dirty"' "$work/noconfig" >/dev/null; then tree=dirty; else tree=clean; fi
for field in "\"gitCommit\": \"$commit\"" "\"gitTreeState\": \"$tree\"" \
  '"buildDate": "20' '"compiler": "gc"' '"platform": "linux/'; do
  grep -F "$field" "$work/noconfig" >/dev/null || fail "version stamp lacks $field"
done
if grep -F 'Initializing TUF' "$work/noconfig" >/dev/null; then
  fail '--disable-tuf still initialized TUF'
fi

# Negative: a named kubeconfig that does not exist is reported, not ignored.
status=0
offline -e KUBECONFIG=/nonexistent/config "$image" --disable-tuf >"$work/missingkube" 2>&1 || status=$?
test "$status" -ne 0 || fail 'webhook started with a missing kubeconfig'
grep -F 'stat /nonexistent/config: no such file or directory' "$work/missingkube" >/dev/null ||
  fail 'missing kubeconfig diagnostic is absent'

# Negative: TUF fails closed. An unreadable alternate root aborts start-up, and
# a mirror on a closed loopback port (no network at all) aborts with the fetch
# error; neither falls back to the public-good mirror.
status=0
offline "$image" --tuf-root /nonexistent/root.json >"$work/tufroot" 2>&1 || status=$?
test "$status" -ne 0 || fail 'webhook started with a missing TUF root'
grep -F 'Failed to read alternate TUF root file /nonexistent/root.json' "$work/tufroot" >/dev/null ||
  fail 'missing TUF root diagnostic is absent'
status=0
offline "$image" --tuf-mirror http://127.0.0.1:1 >"$work/tufmirror" 2>&1 || status=$?
test "$status" -ne 0 || fail 'webhook started with an unreachable TUF mirror'
grep -F 'Initializing TUF root from  => http://127.0.0.1:1' "$work/tufmirror" >/dev/null ||
  fail 'TUF did not use the configured mirror'
grep -F 'Failed to initialize TUF client' "$work/tufmirror" >/dev/null ||
  fail 'TUF mirror failure diagnostic is absent'
grep -F 'http://127.0.0.1:1/' "$work/tufmirror" | grep -F 'connection refused' >/dev/null ||
  fail 'TUF mirror failure does not name the local mirror'
if grep -F 'tuf-repo-cdn.sigstore.dev' "$work/tufmirror" >/dev/null; then
  fail 'TUF fell back to the public-good mirror'
fi

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
pull_child() {
  ref=${1%%@*}
  ref=${ref%:*}
  raw=$(docker buildx imagetools inspect --raw "$ref@${1#*@}") || fail "cannot inspect $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] ||
    fail "index digest mismatch for $1"
  child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail "cannot resolve a child of $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $1" ;;
  esac
  docker pull --quiet --platform "linux/$image_arch" "$ref@$child" >/dev/null ||
    fail "cannot pull $ref@$child"
  printf '%s' "$ref@$child"
}
etcd_image=$(pull_child "$etcd_index")
api_image=$(pull_child "$api_index")
kubectl_image=$(pull_child "$kubectl_index")

rand() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

# Control plane with static tokens: an admin and the webhook's own identity.
openssl genrsa -out "$work/pki/sa.key" 2048 2>/dev/null || fail 'cannot create the service account key'
admin_token=$(rand)
webhook_token=$(rand)
printf '%s,verity-admin,verity-admin,system:masters\n%s,verity-webhook,verity-webhook\n' \
  "$admin_token" "$webhook_token" >"$work/pki/tokens.csv"
kubeconfig() { # token
  printf 'apiVersion: v1\nkind: Config\nclusters:\n  - name: smoke\n    cluster:\n'
  printf '      server: https://%s:6443\n      insecure-skip-tls-verify: true\n' "$api"
  printf 'users:\n  - name: user\n    user:\n      token: %s\n' "$1"
  printf 'contexts:\n  - name: smoke\n    context:\n      cluster: smoke\n      user: user\n'
  printf 'current-context: smoke\n'
}
kubeconfig "$admin_token" >"$work/kube/config"
kubeconfig "$webhook_token" >"$work/wkube/config"
chmod 0644 "$work/pki/sa.key" "$work/pki/tokens.csv" "$work/kube/config" "$work/wkube/config"

docker network create --label "$label" --internal "$network" >/dev/null
docker run -d --name "$etcd" --label "$label" --network "$network" \
  --tmpfs /var/lib/etcd:uid=65532,gid=65532 "$etcd_image" --data-dir=/var/lib/etcd/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls="http://$etcd:2379" >/dev/null
# An internal network has no default route, so kube-apiserver cannot pick an
# advertise address. Aggregator routing makes it resolve the webhook Service
# through its Endpoints, as no kube-proxy serves ClusterIPs here.
docker run -d --name "$api" --label "$label" --network "$network" \
  --tmpfs /tmp:uid=65532,gid=65532 -v "$work/pki:/pki:ro" "$api_image" \
  --advertise-address=127.0.0.1 --endpoint-reconciler-type=none \
  --enable-aggregator-routing=true \
  --etcd-servers="http://$etcd:2379" --secure-port=6443 --cert-dir=/tmp \
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC \
  --service-account-issuer=https://kubernetes.default.svc \
  --service-account-key-file=/pki/sa.key --service-account-signing-key-file=/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/16 >/dev/null

kubectl() {
  docker run --rm -i --label "$label" --network "$network" -v "$work/kube:/kube:ro" \
    -e KUBECONFIG=/kube/config "$kubectl_image" "$@"
}
i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -le 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

# The upstream install objects the webhook reconciles (config/ in the release),
# reduced to what start-up needs: namespace, empty serving Secret, its
# configuration ConfigMaps, schema-less CRDs and the four webhook
# configurations without CA bundles or rules. The webhook identity is bound to
# cluster-admin instead of the upstream ClusterRole.
cat >"$work/install.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: $ns}
---
apiVersion: v1
kind: Secret
metadata: {name: webhook-certs, namespace: $ns}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: config-policy-controller, namespace: $ns}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: config-image-policies, namespace: $ns}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: config-sigstore-keys, namespace: $ns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: verity-policy-controller}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin}
subjects: [{apiGroup: rbac.authorization.k8s.io, kind: User, name: verity-webhook}]
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: clusterimagepolicies.policy.sigstore.dev}
spec:
  conversion:
    strategy: Webhook
    webhook:
      conversionReviewVersions: ["v1beta1", "v1alpha1"]
      clientConfig: {service: {name: webhook, namespace: $ns}}
  group: policy.sigstore.dev
  names: {kind: ClusterImagePolicy, plural: clusterimagepolicies, singular: clusterimagepolicy}
  scope: Cluster
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources: {status: {}}
      schema: {openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}}
    - name: v1beta1
      served: true
      storage: false
      subresources: {status: {}}
      schema: {openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: trustroots.policy.sigstore.dev}
spec:
  group: policy.sigstore.dev
  names: {kind: TrustRoot, plural: trustroots, singular: trustroot}
  scope: Cluster
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources: {status: {}}
      schema: {openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}}
EOF
for kind in Validating Mutating; do
  for name in policy.sigstore.dev "$(test $kind = Validating && echo validating || echo defaulting).clusterimagepolicy.sigstore.dev"; do
    selector='{matchExpressions: [{key: policy.sigstore.dev/include, operator: In, values: ["true"]}]}'
    case $name in *clusterimagepolicy*) selector='{}' ;; esac
    cat >>"$work/install.yaml" <<EOF
---
apiVersion: admissionregistration.k8s.io/v1
kind: ${kind}WebhookConfiguration
metadata: {name: $name}
webhooks:
  - name: $name
    namespaceSelector: $selector
    admissionReviewVersions: [v1]
    clientConfig: {service: {name: webhook, namespace: $ns}}
    failurePolicy: Fail
    sideEffects: None
    timeoutSeconds: 25
EOF
  done
done
kubectl apply -f - <"$work/install.yaml" >/dev/null || fail 'cannot apply the install objects'

# The webhook itself: hardened, read-only, TUF disabled, on the internal network.
docker run -d --name "$webhook" --label "$label" --network "$network" \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /home/nonroot:uid=65532,gid=65532 -v "$work/wkube:/kube:ro" \
  -e KUBECONFIG=/kube/config -e "SYSTEM_NAMESPACE=$ns" -e CONFIG_LOGGING_NAME=config-logging \
  -e METRICS_DOMAIN=sigstore.dev/policy -e WEBHOOK_NAME=webhook \
  "$image" --disable-tuf >/dev/null || fail 'cannot start the webhook'
webhook_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" "$webhook")
[ -n "$webhook_ip" ] || fail 'webhook has no address'
cat >"$work/service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata: {name: webhook, namespace: $ns}
spec:
  ports: [{name: https-webhook, port: 443, targetPort: 8443}]
---
apiVersion: v1
kind: Endpoints
metadata: {name: webhook, namespace: $ns}
subsets:
  - addresses: [{ip: $webhook_ip}]
    ports: [{name: https-webhook, port: 8443}]
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: webhook-verity
  namespace: $ns
  labels: {kubernetes.io/service-name: webhook}
addressType: IPv4
endpoints: [{addresses: [$webhook_ip], conditions: {ready: true}}]
ports: [{name: https-webhook, port: 8443, protocol: TCP}]
EOF
kubectl apply -f - <"$work/service.yaml" >/dev/null 2>&1 || fail 'cannot apply the webhook Service'

# Registration: the certificate controller fills webhook-certs, and the webhook
# reconcilers inject that CA, their rules and paths into every configuration
# and switch the ClusterImagePolicy CRD to webhook conversion.
jsonpath() { # RESOURCE JSONPATH; RESOURCE may carry "-n NAMESPACE"
  # shellcheck disable=SC2086
  kubectl get $1 -o "jsonpath=$2" 2>/dev/null || true
}
wait_for() { # DESCRIPTION RESOURCE JSONPATH
  i=0
  until [ -n "$(jsonpath "$2" "$3")" ]; do
    i=$((i + 1))
    [ "$i" -le 60 ] || fail "$1"
    sleep 2
  done
}
wait_for 'webhook-certs was not populated' "secret/webhook-certs -n $ns" '{.data.ca-cert\.pem}'
ca=$(jsonpath "secret/webhook-certs -n $ns" '{.data.ca-cert\.pem}')
for key in server-cert.pem server-key.pem; do
  [ -n "$(jsonpath "secret/webhook-certs -n $ns" "{.data.${key%.pem}\\.pem}")" ] ||
    fail "webhook-certs lacks $key"
done
for config in validatingwebhookconfiguration/policy.sigstore.dev \
  mutatingwebhookconfiguration/policy.sigstore.dev \
  validatingwebhookconfiguration/validating.clusterimagepolicy.sigstore.dev \
  mutatingwebhookconfiguration/defaulting.clusterimagepolicy.sigstore.dev; do
  wait_for "$config was not registered" "$config" '{.webhooks[0].rules[0].resources[0]}'
  [ "$(jsonpath "$config" '{.webhooks[0].clientConfig.caBundle}')" = "$ca" ] ||
    fail "$config does not carry the webhook CA"
done
jsonpath validatingwebhookconfiguration/policy.sigstore.dev '{.webhooks[0].rules[*].resources}' |
  grep -F pods >/dev/null || fail 'the policy webhook does not intercept pods'
[ "$(jsonpath validatingwebhookconfiguration/policy.sigstore.dev '{.webhooks[0].clientConfig.service.path}')" = /validations ] ||
  fail 'the policy webhook has an unexpected service path'
crd=crd/clusterimagepolicies.policy.sigstore.dev
wait_for 'CRD conversion was not registered' "$crd" '{.spec.conversion.webhook.clientConfig.caBundle}'
[ "$(jsonpath "$crd" '{.spec.conversion.strategy}')" = Webhook ] || fail 'CRD conversion is not Webhook'
[ "$(jsonpath "$crd" '{.spec.conversion.webhook.clientConfig.service.path}')" = /resource-conversion ] ||
  fail 'CRD conversion has an unexpected service path'

# Admission through the API server. Images are digest references to a
# nonexistent registry, so neither tag resolution nor signature lookup is
# needed; namespace "enforced" opts in, "ignored" does not.
kubectl create namespace enforced >/dev/null || fail 'cannot create namespace enforced'
kubectl label namespace enforced policy.sigstore.dev/include=true >/dev/null ||
  fail 'cannot label namespace enforced'
kubectl create namespace ignored >/dev/null || fail 'cannot create namespace ignored'
for n in enforced ignored; do
  kubectl -n "$n" create serviceaccount default >/dev/null || fail "cannot create $n/default"
done
digest=sha256:$(printf 'verity' | sha256sum | cut -d' ' -f1)
pod() { # NAMESPACE IMAGE OUT: server-side dry-run Pod creation
  kubectl -n "$1" run "p$(rand | cut -c1-8)" --restart=Never --image="$2" \
    --dry-run=server -o name >"$3" 2>&1
}
expect_denied() { # DESCRIPTION NAMESPACE IMAGE MESSAGE
  i=0
  while :; do
    if pod "$2" "$3" "$work/pod"; then
      out=''
    else
      out=$(cat "$work/pod")
    fi
    case $out in *"$4"*) break ;; esac
    i=$((i + 1))
    [ "$i" -le 30 ] || fail "$1: $(cat "$work/pod")"
    sleep 2
  done
  grep -F 'admission webhook "policy.sigstore.dev" denied the request' "$work/pod" >/dev/null ||
    fail "$1 was not denied by policy.sigstore.dev: $(cat "$work/pod")"
}
expect_admitted() { # DESCRIPTION NAMESPACE IMAGE
  i=0
  until pod "$2" "$3" "$work/pod"; do
    i=$((i + 1))
    [ "$i" -le 30 ] || fail "$1: $(cat "$work/pod")"
    sleep 2
  done
}

# Default no-match-policy is deny; opted-out namespaces are not intercepted.
expect_denied 'an unmatched image was admitted' enforced "registry.example/app@$digest" \
  'no matching policies'
expect_admitted 'an opted-out namespace was intercepted' ignored "registry.example/app@$digest"

# A ClusterImagePolicy is defaulted and validated by the policy webhooks;
# an unsupported static action is rejected. A server-side dry run never stores
# the policy, so retrying until the API server routes to the webhook is safe.
cat >"$work/bad-cip.yaml" <<EOF
apiVersion: policy.sigstore.dev/v1alpha1
kind: ClusterImagePolicy
metadata: {name: verity-invalid}
spec:
  images: [{glob: "registry.example/**"}]
  authorities: [{static: {action: maybe}}]
EOF
i=0
until ! kubectl apply --dry-run=server -f - <"$work/bad-cip.yaml" >"$work/bad-cip" 2>&1 &&
  grep -F 'admission webhook "validating.clusterimagepolicy.sigstore.dev" denied the request' \
    "$work/bad-cip" >/dev/null; do
  i=$((i + 1))
  [ "$i" -le 30 ] || fail "invalid policy not denied by the policy webhook: $(cat "$work/bad-cip")"
  sleep 2
done
grep -F 'invalid value: maybe: spec.authorities[0].static.action' "$work/bad-cip" >/dev/null ||
  fail "invalid policy diagnostic is absent: $(cat "$work/bad-cip")"
if kubectl get clusterimagepolicy verity-invalid >/dev/null 2>&1; then
  fail 'the invalid ClusterImagePolicy was stored'
fi

# Static authorities are evaluated without any remote lookup.
cat >"$work/cips.yaml" <<EOF
apiVersion: policy.sigstore.dev/v1alpha1
kind: ClusterImagePolicy
metadata: {name: verity-pass}
spec:
  images: [{glob: "registry.example/allowed/**"}]
  authorities: [{static: {action: pass}}]
---
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata: {name: verity-fail}
spec:
  images: [{glob: "registry.example/denied/**"}]
  authorities: [{static: {action: fail, message: verity-static-deny}}]
EOF
kubectl apply -f - <"$work/cips.yaml" >/dev/null || fail 'cannot create the ClusterImagePolicies'
expect_admitted 'a static pass policy did not admit its image' enforced \
  "registry.example/allowed/app@$digest"
expect_denied 'a static fail policy admitted its image' enforced \
  "registry.example/denied/app@$digest" 'disallowed by static policy: verity-static-deny'
expect_denied 'an unmatched image was admitted next to policies' enforced \
  "registry.example/other/app@$digest" 'no matching policies'
# The v1beta1 policy is stored as v1alpha1 and served back through conversion.
[ "$(jsonpath clusterimagepolicy.v1beta1.policy.sigstore.dev/verity-fail '{.spec.authorities[0].static.message}')" = \
  verity-static-deny ] || fail 'v1beta1 ClusterImagePolicy did not round-trip'
kubectl get configmap config-image-policies -n "$ns" -o yaml >"$work/compiled" ||
  fail 'cannot read config-image-policies'
for name in verity-pass verity-fail; do
  grep -E "^  $name: " "$work/compiled" >/dev/null || fail "policy $name was not compiled"
done

# Configuration: no-match-policy warn admits with a warning, and an unknown
# value falls back to deny instead of opening the gate.
kubectl -n "$ns" patch configmap config-policy-controller --type merge \
  -p '{"data":{"no-match-policy":"warn"}}' >/dev/null || fail 'cannot set no-match-policy warn'
i=0
until pod enforced "registry.example/other/app@$digest" "$work/pod" &&
  grep -F 'no matching policies' "$work/pod" >/dev/null; do
  i=$((i + 1))
  [ "$i" -le 30 ] || fail "no-match-policy warn did not take effect: $(cat "$work/pod")"
  sleep 2
done
grep -F 'Warning:' "$work/pod" >/dev/null || fail 'no-match-policy warn did not warn'
kubectl -n "$ns" patch configmap config-policy-controller --type merge \
  -p '{"data":{"no-match-policy":"open"}}' >/dev/null || fail 'cannot set no-match-policy open'
expect_denied 'an unknown no-match-policy did not fail closed' enforced \
  "registry.example/other/app@$digest" 'no matching policies'

# The webhook stayed up, never touched TUF and never named a public-good host.
[ "$(docker inspect -f '{{.State.Running}}' "$webhook")" = true ] || fail 'the webhook exited'
docker logs "$webhook" >"$work/webhook.log" 2>&1
for needle in 'Initializing TUF' tuf-repo-cdn.sigstore.dev fulcio.sigstore.dev rekor.sigstore.dev; do
  if grep -F "$needle" "$work/webhook.log" >/dev/null; then
    fail "webhook log mentions $needle"
  fi
done
grep -F "\"gitVersion\": \"v$version" "$work/webhook.log" >/dev/null ||
  fail 'webhook did not log its version at start-up'

echo "policy-controller $version smoke test passed"

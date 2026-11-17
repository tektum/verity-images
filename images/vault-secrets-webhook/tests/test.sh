#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
recipe_value() {
  awk -v key="$1" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml"
}
version=$(recipe_value version:)
commit=$(recipe_value source-commit:)

# Test peers, pinned by index digest and never part of the image: a HashiCorp
# Vault dev server, a real control plane (Verity etcd 3.7, kube-apiserver 1.37,
# kubectl 1.35) for the webhook's Kubernetes API lookups and for admission
# through the API server, and Verity curl for raw AdmissionReview requests.
vault_index=docker.io/hashicorp/vault:2.2.2@sha256:dfa48c2fa2b0099ccb47681ec5c4804bf5aec9d6879ecfee07ad4b92a5427ad6
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332
curl_index=ghcr.io/tektum/curl:8@sha256:25109b1e9627f52ce9a73b698da4de90a86f983e3fd9eebc933263cf7c3e466d

# Upstream default for the injected init container; the image keeps it.
vault_env_image=ghcr.io/bank-vaults/vault-env:latest

id=$$
label="verity-test=vault-secrets-webhook-$id"
network="verity-vswh-$id"
vault="verity-vswh-vault-$id"
etcd="verity-vswh-etcd-$id"
api="verity-vswh-api-$id"
webhook="verity-vswh-webhook-$id"
work=$(mktemp -d)
# Bind-mount sources exist before the first run so Docker never creates them.
mkdir -p "$work/pki" "$work/kube" "$work/wkube" "$work/tls" "$work/req"

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for name in "$webhook" "$api" "$vault"; do
    docker logs "$name" >/dev/null 2>&1 || continue
    printf -- '--- logs: %s\n' "$name" >&2
    docker logs "$name" 2>&1 | tail -n 25 >&2 || true
  done
  exit 1
}

[ -n "$version" ] || fail 'could not read the recipe version'
[ -n "$commit" ] || fail 'could not read the recipe source commit'

# OCI contract: upstream USER 65534, no WORKDIR, ENTRYPOINT resolved via PATH.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65534 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/vault-secrets-webhook"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'
envs=$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image")
printf '%s\n' "$envs" | grep -E '^PATH=(.*:)?/usr/local/bin(:.*)?$' >/dev/null ||
  fail 'PATH does not include /usr/local/bin'
printf '%s\n' "$envs" | grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

# Build contract from the embedded Go build information: the pinned upstream
# module and commit, CGO off, -trimpath, and the shared vault-sdk release.
probe="verity-vswh-probe-$id"
docker create --name "$probe" --label "$label" "$image" >/dev/null || fail 'cannot create a probe container'
docker cp "$probe:/usr/bin/vault-secrets-webhook" "$work/bin" >/dev/null 2>&1 ||
  fail 'cannot copy /usr/bin/vault-secrets-webhook'
docker rm "$probe" >/dev/null
tab=$(printf '\t')
grep -aE "^mod${tab}github.com/bank-vaults/vault-secrets-webhook${tab}v${version}(\\+dirty)?${tab}" \
  "$work/bin" >/dev/null || fail "binary does not embed module version v$version"
grep -aE "^dep${tab}github.com/bank-vaults/vault-sdk${tab}v0\\.12\\.[0-9]+${tab}" "$work/bin" >/dev/null ||
  fail 'binary does not embed vault-sdk v0.12'
for setting in "vcs.revision=$commit" CGO_ENABLED=0 -trimpath=true; do
  grep -aFx "build${tab}${setting}" "$work/bin" >/dev/null || fail "build setting $setting is missing"
done

hardened() {
  docker run --rm --label "$label" --read-only --cap-drop=ALL --security-opt=no-new-privileges "$@"
}

# Negative: without a Kubernetes client configuration it refuses to start.
# The upstream path /usr/local/bin and the PATH-relative upstream entrypoint
# reach the same binary.
for entry in /usr/bin/vault-secrets-webhook /usr/local/bin/vault-secrets-webhook vault-secrets-webhook; do
  status=0
  hardened --network none --entrypoint "$entry" "$image" >"$work/noconfig" 2>&1 || status=$?
  test "$status" -ne 0 || fail "$entry started without a Kubernetes configuration"
  grep -F 'error creating k8s client' "$work/noconfig" >/dev/null ||
    fail "$entry: missing k8s client diagnostic: $(cat "$work/noconfig")"
done

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
vault_image=$(pull_child "$vault_index")
etcd_image=$(pull_child "$etcd_index")
api_image=$(pull_child "$api_index")
kubectl_image=$(pull_child "$kubectl_index")
curl_image=$(pull_child "$curl_index")

rand() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

# Throwaway serving certificate for the webhook, signed by a throwaway CA.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj '/CN=verity-vswh-test-ca' -keyout "$work/tls/ca.key" -out "$work/tls/ca.crt" \
  >/dev/null 2>&1 || fail 'cannot create the test CA'
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$webhook" \
  -keyout "$work/tls/tls.key" -out "$work/tls/tls.csr" >/dev/null 2>&1 ||
  fail 'cannot create the serving key'
printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$webhook" >"$work/tls/ext"
openssl x509 -req -days 1 -in "$work/tls/tls.csr" -CA "$work/tls/ca.crt" -CAkey "$work/tls/ca.key" \
  -CAcreateserial -extfile "$work/tls/ext" -out "$work/tls/tls.crt" >/dev/null 2>&1 ||
  fail 'cannot sign the serving certificate'
rm -f "$work/tls/ca.key" "$work/tls/tls.csr"
chmod 0644 "$work/tls/tls.key" "$work/tls/tls.crt" "$work/tls/ca.crt"

# Control plane with static tokens: an admin and the webhook's own identity,
# which RBAC lets read Secrets and ConfigMaps in namespace apps only.
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

vault_root=$(rand)
docker network create --label "$label" --internal "$network" >/dev/null
docker run -d --name "$vault" --label "$label" --network "$network" -e SKIP_SETCAP=true \
  -e "VAULT_DEV_ROOT_TOKEN_ID=$vault_root" -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 \
  "$vault_image" >/dev/null
docker run -d --name "$etcd" --label "$label" --network "$network" \
  --tmpfs /var/lib/etcd:uid=65532,gid=65532 "$etcd_image" --data-dir=/var/lib/etcd/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls="http://$etcd:2379" >/dev/null
# An internal network has no default route, so kube-apiserver cannot pick an
# advertise address; it calls the webhook by its container name.
docker run -d --name "$api" --label "$label" --network "$network" \
  --tmpfs /tmp:uid=65532,gid=65532 -v "$work/pki:/pki:ro" "$api_image" \
  --advertise-address=127.0.0.1 --endpoint-reconciler-type=none \
  --etcd-servers="http://$etcd:2379" --secure-port=6443 --cert-dir=/tmp \
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC \
  --service-account-issuer=https://kubernetes.default.svc \
  --service-account-key-file=/pki/sa.key --service-account-signing-key-file=/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/16 >/dev/null

vault() {
  docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 -e "VAULT_TOKEN=$vault_root" "$vault" vault "$@"
}
kubectl() {
  docker run --rm -i --label "$label" --network "$network" -v "$work/kube:/kube:ro" \
    -e KUBECONFIG=/kube/config "$kubectl_image" "$@"
}
i=0
until vault status >/dev/null 2>&1 && kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -le 60 ] || fail 'Vault or kube-apiserver did not become ready'
  sleep 2
done

# Vault: the KV v2 secret, a second secret the webhook may not read, and a
# token whose policy reads only secret/data/app.
secret_value="pw-$(rand)"
vault kv put secret/app password="$secret_value" >/dev/null || fail 'cannot write secret/app'
vault kv put secret/denied password=never >/dev/null || fail 'cannot write secret/denied'
printf 'path "secret/data/app" {\n  capabilities = ["read"]\n}\n' |
  vault policy write app-read - >/dev/null || fail 'cannot write the app-read policy'
app_token=$(vault token create -policy=app-read -ttl=1h -field=token) || fail 'cannot create the app token'
[ -n "$app_token" ] || fail 'empty app token'

ref='vault:secret/data/app#password'
for ns in apps restricted; do
  kubectl create namespace "$ns" >/dev/null || fail "cannot create namespace $ns"
  kubectl label namespace "$ns" verity-vault-injection=enabled >/dev/null || fail "cannot label $ns"
  kubectl -n "$ns" create serviceaccount default >/dev/null || fail "cannot create $ns/default"
  # The value is the Vault reference itself; Pods consume it through valueFrom.
  kubectl -n "$ns" create secret generic app-refs --from-literal="password=$ref" >/dev/null ||
    fail "cannot create $ns/app-refs"
done
kubectl -n apps create role vswh-read --verb=get --resource=secrets,configmaps >/dev/null ||
  fail 'cannot create the webhook role'
kubectl -n apps create rolebinding vswh-read --role=vswh-read --user=verity-webhook >/dev/null ||
  fail 'cannot bind the webhook role'

# The webhook as the Helm chart runs it: TLS from /var/serving-cert, :8443,
# hardened and read-only. Token auth comes from VAULT_TOKEN as upstream reads it.
docker run -d --name "$webhook" --label "$label" --network "$network" --read-only \
  --cap-drop=ALL --security-opt=no-new-privileges \
  -v "$work/tls:/var/serving-cert:ro" -v "$work/wkube:/kube:ro" -e KUBECONFIG=/kube/config \
  -e KUBERNETES_NAMESPACE=vswh -e TLS_CERT_FILE=/var/serving-cert/tls.crt \
  -e TLS_PRIVATE_KEY_FILE=/var/serving-cert/tls.key -e LISTEN_ADDRESS=:8443 \
  -e "VAULT_ADDR=http://$vault:8200" -e "VAULT_TOKEN=$app_token" "$image" >/dev/null

curl() {
  docker run --rm -i --label "$label" --network "$network" -v "$work/tls/ca.crt:/ca.crt:ro" \
    "$curl_image" -sS --max-time 30 "$@"
}
i=0
until curl --cacert /ca.crt -o /dev/null "https://$webhook:8443/healthz" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -le 30 ] || fail 'webhook did not serve /healthz over TLS'
  sleep 1
done
docker logs "$webhook" 2>&1 | grep -F 'Listening on https://:8443' >/dev/null ||
  fail 'webhook did not log its TLS listener'
code=$(curl --cacert /ca.crt -o /dev/null -w '%{http_code}' "https://$webhook:8443/healthz") ||
  fail 'healthz request failed'
test "$code" = 200 || fail "healthz returned $code"
# Negative: the serving certificate is the generated one, not some default.
curl -o /dev/null "https://$webhook:8443/healthz" >"$work/untrusted" 2>&1 &&
  fail 'TLS succeeded without trusting the test CA'
grep -Fi 'certificate' "$work/untrusted" >/dev/null || fail "unexpected TLS error: $(cat "$work/untrusted")"
# Negative: plaintext HTTP is refused on the TLS port.
curl "http://$webhook:8443/healthz" >"$work/plain" 2>&1 || true
grep -F 'Client sent an HTTP request to an HTTPS server' "$work/plain" >/dev/null ||
  fail "plaintext HTTP was not refused: $(cat "$work/plain")"

# review KIND RESOURCE NAMESPACE OBJECT_JSON: POST an admission.k8s.io/v1
# AdmissionReview to the webhook path for RESOURCE; prints the response.
review() {
  uid=$(rand)
  jq -n --arg uid "$uid" --arg kind "$1" --arg res "$2" --arg ns "$3" --argjson obj "$4" '{
    apiVersion: "admission.k8s.io/v1", kind: "AdmissionReview",
    request: {
      uid: $uid, kind: {group: "", version: "v1", kind: $kind},
      resource: {group: "", version: "v1", resource: $res},
      namespace: $ns, name: $obj.metadata.name, operation: "CREATE",
      userInfo: {username: "verity-test"}, object: $obj, dryRun: false
    }
  }' >"$work/req/$uid.json" || fail 'cannot build an AdmissionReview'
  curl --cacert /ca.crt -H 'Content-Type: application/json' --data-binary @- \
    "https://$webhook:8443/$2" <"$work/req/$uid.json" >"$work/resp" ||
    fail "AdmissionReview POST to /$2 failed: $(cat "$work/resp")"
  jq -e --arg uid "$uid" '.kind == "AdmissionReview" and .response.uid == $uid' "$work/resp" >/dev/null ||
    fail "malformed AdmissionReview response: $(cat "$work/resp")"
  cat "$work/resp"
}
patch_of() { jq -c '.response.patch // "" | if . == "" then [] else @base64d | fromjson end'; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# Secret: a plain reference, an inline reference and an untouched value.
# shellcheck disable=SC2016 # a literal upstream inline reference
dsn='postgres://app:${vault:secret/data/app#password}@db:5432/app'
secret=$(jq -n --arg p "$(b64 "$ref")" --arg d "$(b64 "$dsn")" --arg k "$(b64 keep-me)" \
  '{apiVersion: "v1", kind: "Secret", type: "Opaque", metadata: {name: "app", namespace: "apps"},
    data: {password: $p, dsn: $d, plain: $k}}')
review Secret secrets apps "$secret" >"$work/secret.json"
jq -e '.response.allowed == true and .response.patchType == "JSONPatch"' "$work/secret.json" >/dev/null ||
  fail "Secret was not admitted with a JSON patch: $(cat "$work/secret.json")"
patch_of <"$work/secret.json" >"$work/secret.patch"
got=$(jq -r '.[] | select(.path == "/data/password" and (.op == "replace" or .op == "add")) | .value | @base64d' \
  "$work/secret.patch")
test "$got" = "$secret_value" || fail "Secret patch lacks the Vault value: $(cat "$work/secret.patch")"
got=$(jq -r '.[] | select(.path == "/data/dsn") | .value | @base64d' "$work/secret.patch")
test "$got" = "postgres://app:$secret_value@db:5432/app" ||
  fail "inline reference not resolved: $(cat "$work/secret.patch")"
jq -e 'all(.[]; .path != "/data/plain")' "$work/secret.patch" >/dev/null ||
  fail "a plain value was patched: $(cat "$work/secret.patch")"

# ConfigMap through the /configmaps endpoint.
cm=$(jq -n --arg r "$ref" '{apiVersion: "v1", kind: "ConfigMap",
  metadata: {name: "app", namespace: "apps"}, data: {password: $r, mode: "prod"}}')
review ConfigMap configmaps apps "$cm" >"$work/cm.json"
jq -e '.response.allowed == true' "$work/cm.json" >/dev/null || fail "ConfigMap denied: $(cat "$work/cm.json")"
got=$(patch_of <"$work/cm.json" | jq -r '.[] | select(.path == "/data/password") | .value')
test "$got" = "$secret_value" || fail "ConfigMap patch lacks the Vault value: $(cat "$work/cm.json")"

# Negative: the token's policy does not cover secret/data/denied; admission fails.
denied=$(jq -n --arg p "$(b64 'vault:secret/data/denied#password')" \
  '{apiVersion: "v1", kind: "Secret", metadata: {name: "denied", namespace: "apps"}, data: {password: $p}}')
review Secret secrets apps "$denied" >"$work/denied.json"
jq -e '.response.allowed == false and (.response.patch == null)' "$work/denied.json" >/dev/null ||
  fail "a Secret outside the token policy was admitted: $(cat "$work/denied.json")"
jq -r '.response.status.message' "$work/denied.json" | grep -F 'permission denied' >/dev/null ||
  fail "denial does not name the Vault error: $(cat "$work/denied.json")"

# Negative: the upstream skip annotation leaves the object alone.
skip=$(printf '%s' "$secret" | jq '.metadata.annotations = {"vault.security.banzaicloud.io/mutate": "skip"}')
review Secret secrets apps "$skip" >"$work/skip.json"
jq -e '.response.allowed == true' "$work/skip.json" >/dev/null || fail "skipped Secret denied: $(cat "$work/skip.json")"
test "$(patch_of <"$work/skip.json")" = '[]' || fail "skipped Secret was patched: $(cat "$work/skip.json")"

# Pod: an explicit command so no registry lookup is needed. Container app has
# a literal reference, container ref only a secretKeyRef that the webhook must
# read from the API server, container plain has nothing to inject.
pod() { # namespace
  jq -n --arg ns "$1" --arg r "$ref" '{apiVersion: "v1", kind: "Pod",
    metadata: {name: "app", namespace: $ns},
    spec: {automountServiceAccountToken: false, containers: [
      {name: "app", image: "registry.invalid/app:1", command: ["/bin/app"], args: ["--serve"],
       env: [{name: "PASSWORD", value: $r}]},
      {name: "ref", image: "registry.invalid/app:1", command: ["/bin/ref"],
       env: [{name: "PASSWORD", valueFrom: {secretKeyRef: {name: "app-refs", key: "password"}}}]},
      {name: "plain", image: "registry.invalid/app:1", command: ["/bin/plain"],
       env: [{name: "MODE", value: "prod"}]}]}}'
}
review Pod pods apps "$(pod apps)" >"$work/pod.json"
jq -e '.response.allowed == true and .response.patchType == "JSONPatch"' "$work/pod.json" >/dev/null ||
  fail "Pod was not admitted with a JSON patch: $(cat "$work/pod.json")"
patch_of <"$work/pod.json" >"$work/pod.patch"
jq -e --arg img "$vault_env_image" '[.[] | select(.path == "/spec/initContainers" and .op == "add")
  | .value[0] | select(.name == "copy-vault-env" and .image == $img
    and .command == ["sh", "-c", "cp /usr/local/bin/vault-env /vault/"]
    and any(.volumeMounts[]; .name == "vault-env" and .mountPath == "/vault/"))] | length == 1' \
  "$work/pod.patch" >/dev/null || fail "Pod patch does not add the vault-env init container: $(cat "$work/pod.patch")"
jq -e 'any(.[]; .path == "/spec/containers/0/command/0" and .value == "/vault/vault-env")
  or any(.[]; .path == "/spec/containers/0/command" and .value == ["/vault/vault-env"])' \
  "$work/pod.patch" >/dev/null || fail "Pod patch does not wrap the command: $(cat "$work/pod.patch")"
jq -e 'any(.[]; .path == "/spec/volumes" and any(.value[]; .name == "vault-env"))' "$work/pod.patch" \
  >/dev/null || fail "Pod patch does not add the vault-env volume: $(cat "$work/pod.patch")"

# Admission through the API server: register the webhook with the throwaway
# CA and create real objects, which the API server stores mutated.
ca_bundle=$(base64 <"$work/tls/ca.crt" | tr -d '\n')
hook() { # name resource
  printf '  - name: %s.vault-secrets-webhook.verity.test\n' "$1"
  printf '    admissionReviewVersions: [v1]\n    sideEffects: NoneOnDryRun\n'
  printf '    failurePolicy: Fail\n    timeoutSeconds: 20\n'
  printf '    namespaceSelector: {matchLabels: {verity-vault-injection: enabled}}\n'
  printf '    clientConfig: {url: "https://%s:8443/%s", caBundle: %s}\n' "$webhook" "$2" "$ca_bundle"
  printf '    rules: [{operations: [CREATE], apiGroups: [""], apiVersions: [v1], resources: [%s]}]\n' "$2"
}
{
  printf 'apiVersion: admissionregistration.k8s.io/v1\nkind: MutatingWebhookConfiguration\n'
  printf 'metadata: {name: verity-vault-secrets-webhook}\nwebhooks:\n'
  hook pods pods
  hook secrets secrets
  hook configmaps configmaps
} | kubectl apply -f - >/dev/null || fail 'cannot register the webhook'

i=0
until kubectl -n apps create secret generic stored --from-literal="password=$ref" >"$work/kc" 2>&1; do
  i=$((i + 1))
  [ "$i" -le 15 ] || fail "API server could not admit a Secret through the webhook: $(cat "$work/kc")"
  sleep 2
done
got=$(kubectl -n apps get secret stored -o jsonpath='{.data.password}' | base64 -d) ||
  fail 'cannot read the stored Secret'
test "$got" = "$secret_value" || fail 'stored Secret does not hold the Vault value'

kubectl -n apps create configmap stored --from-literal="password=$ref" >/dev/null ||
  fail 'API server could not admit a ConfigMap through the webhook'
got=$(kubectl -n apps get configmap stored -o jsonpath='{.data.password}') || fail 'cannot read the ConfigMap'
test "$got" = "$secret_value" || fail 'stored ConfigMap does not hold the Vault value'

pod apps | kubectl create -f - >"$work/kc" 2>&1 || fail "API server rejected the Pod: $(cat "$work/kc")"
kubectl -n apps get pod app -o json >"$work/stored-pod.json" || fail 'cannot read the stored Pod'
jq -e --arg img "$vault_env_image" '.spec.initContainers | length == 1 and .[0].name == "copy-vault-env"
  and .[0].image == $img' "$work/stored-pod.json" >/dev/null ||
  fail "stored Pod lacks the vault-env init container: $(jq -c .spec.initContainers "$work/stored-pod.json")"
jq -e '.spec.containers[0] | .command == ["/vault/vault-env"] and .args == ["/bin/app", "--serve"]' \
  "$work/stored-pod.json" >/dev/null || fail "app container was not wrapped: $(jq -c '.spec.containers[0]' "$work/stored-pod.json")"
jq -e '.spec.containers[1] | .command == ["/vault/vault-env"] and .args == ["/bin/ref"]' \
  "$work/stored-pod.json" >/dev/null ||
  fail "secretKeyRef container was not wrapped from the API lookup: $(jq -c '.spec.containers[1]' "$work/stored-pod.json")"
jq -e '.spec.containers[2] | .command == ["/bin/plain"] and (.args == null)
  and all(.volumeMounts[]?; .name != "vault-env")' "$work/stored-pod.json" >/dev/null ||
  fail "container without references was mutated: $(jq -c '.spec.containers[2]' "$work/stored-pod.json")"
jq -e --arg addr "http://$vault:8200" --arg token "$app_token" '.spec.containers[0].env as $e
  | any($e[]; .name == "VAULT_ADDR" and .value == $addr)
  and any($e[]; .name == "VAULT_TOKEN" and .value == $token)
  and any($e[]; .name == "PASSWORD" and .value == "vault:secret/data/app#password")' \
  "$work/stored-pod.json" >/dev/null || fail "stored Pod lacks the vault-env environment"

# Negative: in namespace restricted the webhook identity may not read the
# referenced Secret, so the webhook answers allowed=false (with HTTP 500, as
# upstream's kubewebhook does) and the API server refuses the Pod.
pod restricted | kubectl create -f - >"$work/restricted" 2>&1 &&
  fail 'a Pod was admitted although the webhook could not read its secretKeyRef'
for message in 'failed calling webhook "pods.vault-secrets-webhook.verity.test"' \
  'could not mutate object' 'is forbidden' 'verity-webhook' 'cannot get resource'; do
  grep -F "$message" "$work/restricted" >/dev/null ||
    fail "restricted Pod error lacks '$message': $(cat "$work/restricted")"
done
kubectl -n restricted get pod app >/dev/null 2>&1 && fail 'the refused Pod was stored'

# Metrics on the serving port, counting the Vault requests made above.
curl --cacert /ca.crt "https://$webhook:8443/metrics" >"$work/metrics" || fail 'metrics request failed'
grep -E '^vault_client_requests_total\{[^}]*code="200"[^}]*\} [1-9]' "$work/metrics" >/dev/null ||
  fail "Vault request metrics are missing: $(grep -F vault_client "$work/metrics" | head -n 5)"

# The process stops on SIGTERM as PID 1, well before Docker would SIGKILL it.
start=$(date +%s)
docker stop -t 30 "$webhook" >/dev/null || fail 'cannot stop the webhook'
elapsed=$(($(date +%s) - start))
test "$elapsed" -lt 20 || fail "webhook ignored SIGTERM for ${elapsed}s"
test "$(docker inspect -f '{{.State.OOMKilled}}' "$webhook")" = false || fail 'webhook was OOM killed'

printf 'vault-secrets-webhook %s: smoke test passed\n' "$version"

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35, pinned by digest.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332

id=$$
network="verity-polaris-$id"
etcd="verity-polaris-etcd-$id"
api="verity-polaris-api-$id"
dash="verity-polaris-dash-$id"
hook="verity-polaris-hook-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$hook" "$dash" "$api"; do
    docker logs "$c" 2>&1 | tail -n 20 >&2 || true
  done
  exit 1
}

cleanup() {
  docker rm -f "$hook" "$dash" "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# OCI contract: upstream runs as UID 1200 with CMD ["polaris"], no
# entrypoint, from /opt/app.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1200 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = null ||
  fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["polaris"]' ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /opt/app ||
  fail 'unexpected working directory'

run() {
  docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges "$@"
}

# Version stamp from the upstream GoReleaser ldflags, on PATH and at the
# upstream /usr/local/bin/polaris path.
run --network none "$image" polaris version >"$work/version" 2>&1 ||
  fail "version failed: $(cat "$work/version")"
grep -Fx "Polaris version:$expected_version" "$work/version" >/dev/null ||
  fail "unexpected version output: $(cat "$work/version")"
run --network none "$image" /usr/local/bin/polaris version >"$work/version" 2>&1 ||
  fail "upstream path /usr/local/bin/polaris failed: $(cat "$work/version")"

# The default command has no sub-command: it prints usage and exits 1.
status=0
run --network none "$image" >"$work/default" 2>&1 || status=$?
test "$status" -eq 1 || fail "default command exited $status"
for word in audit dashboard webhook fix version; do
  grep -E "^  $word " "$work/default" >/dev/null || fail "usage is missing $word"
done
grep -F 'You must specify a sub-command.' "$work/default" >/dev/null ||
  fail "default command diagnostic is missing: $(cat "$work/default")"

status=0
run --network none "$image" polaris definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -ne 0 || fail 'unknown command unexpectedly succeeded'
grep -Fx 'Error: unknown command "definitely-invalid" for "polaris"' "$work/invalid" >/dev/null ||
  fail "unknown command diagnostic is missing: $(cat "$work/invalid")"

# Fixtures: one compliant and one non-compliant Deployment, and a custom
# configuration with a JSON-schema custom check and an annotation exemption.
mkdir -p "$work/manifests" "$work/config" "$work/pki" "$work/kube" "$work/cert"
cat >"$work/manifests/workloads.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hardened
  namespace: shop
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hardened
  template:
    metadata:
      labels:
        app: hardened
    spec:
      containers:
        - name: web
          image: registry.example.com/web:1.2.3
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
          resources:
            limits:
              cpu: 500m
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: risky
  namespace: shop
  annotations:
    polaris.fairwinds.com/readinessProbeMissing-exempt: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: risky
  template:
    metadata:
      labels:
        app: risky
    spec:
      hostNetwork: true
      containers:
        - name: app
          image: docker.io/library/nginx:latest
          securityContext:
            privileged: true
EOF
cat >"$work/config/config.yaml" <<'EOF'
checks:
  tagNotSpecified: danger
  hostNetworkSet: danger
  runAsPrivileged: danger
  runAsRootAllowed: danger
  privilegeEscalationAllowed: danger
  readinessProbeMissing: warning
  cpuLimitsMissing: warning
  notReadOnlyRootFilesystem: warning
  trustedRegistry: danger
customChecks:
  trustedRegistry:
    successMessage: Image comes from the trusted registry
    failureMessage: Image must come from registry.example.com
    category: Security
    target: Container
    schema:
      '$schema': http://json-schema.org/draft-07/schema
      type: object
      properties:
        image:
          type: string
          pattern: ^registry\.example\.com/
EOF
printf 'checks: [\n' >"$work/config/broken.yaml"
chmod 0755 "$work/manifests" "$work/config" "$work/pki" "$work/kube" "$work/cert"
chmod 0644 "$work/manifests/"*.yaml "$work/config/"*.yaml

audit() {
  run --network none -v "$work/manifests:/manifests:ro" -v "$work/config:/config:ro" \
    "$image" polaris audit --audit-path /manifests --config /config/config.yaml "$@"
}

# Expected result for both the file and the cluster audit. The hardened
# Deployment passes all nine checks (2 points each); risky fails six danger
# checks (2 each) and two warnings (1 each); its readinessProbeMissing is
# exempted by annotation. Score = 18 / (18 + 12 + 2) = 56.
expect_results() { # audit-json label
  jq -e '
    def checks(n): .Results[] | select(.Kind == "Deployment" and .Name == n)
      | [(.PodResult.Results, .PodResult.ContainerResults[].Results) | to_entries[]
         | {key, value: [.value.Success, .value.Severity]}] | from_entries;
    .Score == 56
    and ([.Results[] | select(.Kind == "Deployment") | .Name] | sort) == ["hardened", "risky"]
    and (checks("hardened") | length == 9 and all(.[]; .[0] == true))
    and checks("risky") == {
      hostNetworkSet: [false, "danger"],
      tagNotSpecified: [false, "danger"],
      runAsPrivileged: [false, "danger"],
      runAsRootAllowed: [false, "danger"],
      privilegeEscalationAllowed: [false, "danger"],
      trustedRegistry: [false, "danger"],
      cpuLimitsMissing: [false, "warning"],
      notReadOnlyRootFilesystem: [false, "warning"]}
    and ([.Results[] | select(.Name == "risky") | .PodResult.ContainerResults[].Results.trustedRegistry.Message]
         == ["Image must come from registry.example.com"])
  ' "$1" >/dev/null || fail "$2 results are wrong: $(jq -c '{Score, Results: [.Results[] | select(.Kind == "Deployment")]}' "$1")"
}

audit --format json >"$work/audit.json" 2>"$work/audit.err" ||
  fail "file audit failed: $(cat "$work/audit.err")"
jq -e '.SourceType == "Path" and .SourceName == "/manifests"' "$work/audit.json" >/dev/null ||
  fail "unexpected file audit source: $(jq -c '{SourceType, SourceName}' "$work/audit.json")"
expect_results "$work/audit.json" 'file audit'

audit --format score >"$work/score" 2>&1 || fail "score audit failed: $(cat "$work/score")"
test "$(cat "$work/score")" = 56 || fail "unexpected score: $(cat "$work/score")"

# Without the exemption, the readiness warning counts: 18 / 33 = 54.
audit --format score --disallow-exemptions >"$work/score" 2>&1 ||
  fail "audit without exemptions failed: $(cat "$work/score")"
test "$(cat "$work/score")" = 54 || fail "unexpected score without exemptions: $(cat "$work/score")"

# Only failed tests, filtered to danger severity.
audit --format json --only-show-failed-tests --severity danger >"$work/failed.json" 2>"$work/audit.err" ||
  fail "filtered audit failed: $(cat "$work/audit.err")"
jq -e '[.Results[] | select(.Kind == "Deployment")
        | (.PodResult.Results, .PodResult.ContainerResults[].Results) | keys[]] | sort
       == ["hostNetworkSet", "privilegeEscalationAllowed", "runAsPrivileged",
           "runAsRootAllowed", "tagNotSpecified", "trustedRegistry"]' "$work/failed.json" >/dev/null ||
  fail "unexpected filtered results: $(jq -c '[.Results[] | select(.Kind == "Deployment")]' "$work/failed.json")"

# CI gates: exit 3 on danger findings, exit 4 below a minimum score.
status=0
audit --format score --set-exit-code-on-danger >"$work/gate" 2>&1 || status=$?
test "$status" -eq 3 || fail "danger gate exited $status: $(cat "$work/gate")"
grep -F '6 danger items found in audit' "$work/gate" >/dev/null || fail "danger gate diagnostic: $(cat "$work/gate")"
status=0
audit --format score --set-exit-code-below-score 60 >"$work/gate" 2>&1 || status=$?
test "$status" -eq 4 || fail "score gate exited $status: $(cat "$work/gate")"
grep -F 'Audit score of 56 is less than the provided minimum of 60' "$work/gate" >/dev/null ||
  fail "score gate diagnostic: $(cat "$work/gate")"
audit --format score --set-exit-code-below-score 50 >"$work/gate" 2>&1 ||
  fail "score gate at 50 failed: $(cat "$work/gate")"

# Invalid inputs.
status=0
run --network none -v "$work/config:/config:ro" "$image" \
  polaris audit --audit-path /missing --config /config/config.yaml >"$work/bad" 2>&1 || status=$?
test "$status" -eq 1 || fail "missing audit path exited $status"
grep -F 'Error fetching Kubernetes resources lstat /missing: no such file or directory' "$work/bad" >/dev/null ||
  fail "missing audit path diagnostic: $(cat "$work/bad")"
status=0
run --network none -v "$work/manifests:/manifests:ro" -v "$work/config:/config:ro" "$image" \
  polaris audit --audit-path /manifests --config /config/broken.yaml >"$work/bad" 2>&1 || status=$?
test "$status" -eq 1 || fail "broken config exited $status"
grep -F 'Error parsing config at /config/broken.yaml: decoding config failed' "$work/bad" >/dev/null ||
  fail "broken config diagnostic: $(cat "$work/bad")"

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
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC --allow-privileged=true \
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

kubectl create namespace shop >/dev/null || fail 'cannot create namespace shop'
kubectl apply -f - <"$work/manifests/workloads.yaml" >/dev/null || fail 'cannot apply the workloads'

# Cluster audit through the kubeconfig: the same Deployments, read from the
# API server, give the same results as the file audit.
in_cluster() {
  run --network "$network" -v "$work/kube:/kube:ro" -v "$work/config:/config:ro" \
    -e KUBECONFIG=/kube/config "$@"
}
in_cluster "$image" polaris audit --config /config/config.yaml --format json \
  >"$work/cluster.json" 2>"$work/cluster.err" || fail "cluster audit failed: $(cat "$work/cluster.err")"
jq -e --arg server "https://$api:6443" '
  .SourceType == "Cluster" and .SourceName == $server
  and (.ClusterInfo.Version | test("^1\\.[0-9]+$")) and .ClusterInfo.Controllers == 2
' "$work/cluster.json" >/dev/null ||
  fail "unexpected cluster audit source: $(jq -c '{SourceType, SourceName, ClusterInfo}' "$work/cluster.json")"
expect_results "$work/cluster.json" 'cluster audit'

# A namespace-scoped audit reports the namespace source and still finds the
# workloads; an unknown namespace is an error.
in_cluster "$image" polaris audit --config /config/config.yaml --format json --namespace shop \
  >"$work/shop.json" 2>"$work/cluster.err" || fail "namespaced audit failed: $(cat "$work/cluster.err")"
jq -e '.SourceType == "ClusterNamespace" and .ClusterInfo.Namespaces == 1' "$work/shop.json" >/dev/null ||
  fail "unexpected namespaced source: $(jq -c '{SourceType, ClusterInfo}' "$work/shop.json")"
expect_results "$work/shop.json" 'namespaced audit'
status=0
in_cluster "$image" polaris audit --config /config/config.yaml --namespace definitely-missing \
  >"$work/missing-ns" 2>&1 || status=$?
test "$status" -ne 0 || fail 'audit of a missing namespace unexpectedly succeeded'
grep -F 'Error fetching Kubernetes resources namespaces \"definitely-missing\" not found' "$work/missing-ns" >/dev/null ||
  fail "missing namespace diagnostic: $(cat "$work/missing-ns")"

# Dashboard: serves the cluster audit under a base path on a read-only root.
docker run -d --name "$dash" --network "$network" --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges -p 127.0.0.1::8080 \
  -v "$work/kube:/kube:ro" -v "$work/config:/config:ro" -e KUBECONFIG=/kube/config \
  "$image" polaris dashboard --config /config/config.yaml --port 8080 --base-path /polaris/ >/dev/null
dash_port=$(docker port "$dash" 8080/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$dash_port" ] || fail 'dashboard port is not published'
dash_url="http://127.0.0.1:$dash_port/polaris"
i=0
until [ "$(curl -fsS "$dash_url/health" 2>/dev/null)" = OK ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'dashboard did not become healthy'
  sleep 1
done
docker logs "$dash" 2>&1 | grep -F 'Starting Polaris dashboard server on port 8080' >/dev/null ||
  fail 'dashboard start log is missing'
curl -fsS "$dash_url/results.json" >"$work/dash.json" || fail 'dashboard results.json failed'
jq -e '.SourceType == "Cluster"' "$work/dash.json" >/dev/null || fail 'dashboard results are not from the cluster'
expect_results "$work/dash.json" 'dashboard'
curl -fsS "$dash_url/" >"$work/index.html" || fail 'dashboard page failed'
grep -F '<title>Fairwinds Polaris</title>' "$work/index.html" >/dev/null || fail 'dashboard title is missing'
grep -F 'risky' "$work/index.html" >/dev/null || fail 'dashboard page does not list the risky Deployment'
test "$(curl -sS -o /dev/null -w '%{http_code} %{content_type}' "$dash_url/static/css/main.css")" = \
  '200 text/css; charset=utf-8' || fail 'embedded dashboard asset is not served'
test "$(curl -sS -o /dev/null -w '%{http_code}' "$dash_url/definitely-missing")" = 404 ||
  fail 'unknown dashboard path did not return 404'
test "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$dash_port/health")" = 404 ||
  fail 'dashboard answered outside its base path'
docker rm -f "$dash" >/dev/null

# Validating webhook: TLS from /opt/cert, registered with the API server by
# URL so admission requests travel API server -> Polaris.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=verity-polaris-ca' \
  -keyout "$work/ca.key" -out "$work/ca.crt" 2>/dev/null || fail 'cannot create the webhook CA'
openssl req -newkey rsa:2048 -nodes -subj "/CN=$hook" \
  -keyout "$work/cert/tls.key" -out "$work/hook.csr" 2>/dev/null || fail 'cannot create the webhook CSR'
printf 'subjectAltName=DNS:%s\n' "$hook" >"$work/san.ext"
openssl x509 -req -in "$work/hook.csr" -CA "$work/ca.crt" -CAkey "$work/ca.key" -CAcreateserial \
  -days 1 -extfile "$work/san.ext" -out "$work/cert/tls.crt" 2>/dev/null || fail 'cannot sign the webhook certificate'
chmod 0644 "$work/cert/tls.key" "$work/cert/tls.crt"

# Without a certificate the webhook refuses to start.
status=0
in_cluster "$image" polaris webhook --config /config/config.yaml >"$work/nocert" 2>&1 || status=$?
test "$status" -ne 0 || fail 'webhook without a certificate unexpectedly succeeded'
grep -F 'Cert does not exist' "$work/nocert" >/dev/null || fail "missing certificate diagnostic: $(cat "$work/nocert")"

docker run -d --name "$hook" --network "$network" --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges \
  -v "$work/kube:/kube:ro" -v "$work/config:/config:ro" -v "$work/cert:/opt/cert:ro" \
  -e KUBECONFIG=/kube/config "$image" polaris webhook --config /config/config.yaml >/dev/null
i=0
until docker logs "$hook" 2>&1 | grep -F 'Polaris webhook server listening on port 9876' >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'webhook did not start'
  sleep 1
done

ca_bundle=$(base64 <"$work/ca.crt" | tr -d '\n')
kubectl apply -f - >/dev/null <<EOF || fail 'cannot register the webhook'
apiVersion: v1
kind: Namespace
metadata:
  name: guarded
  labels:
    polaris-smoke: enforce
---
# No kube-controller-manager runs, so the default service account is created here.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: guarded
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: verity-polaris-smoke
webhooks:
  - name: polaris.smoke.verity.dev
    admissionReviewVersions: [v1]
    sideEffects: None
    failurePolicy: Fail
    timeoutSeconds: 10
    clientConfig:
      url: https://$hook:9876/validate
      caBundle: $ca_bundle
    namespaceSelector:
      matchLabels:
        polaris-smoke: enforce
    rules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE]
        resources: [pods]
EOF

# The API server rejects privileged with allowPrivilegeEscalation false, so
# the non-compliant pod allows escalation as well.
pod() { # name image privileged
  escalation=false
  [ "$3" = false ] || escalation=true
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: guarded
spec:
  hostNetwork: $3
  automountServiceAccountToken: false
  containers:
    - name: main
      image: $2
      securityContext:
        runAsNonRoot: true
        allowPrivilegeEscalation: $escalation
        privileged: $3
        readOnlyRootFilesystem: true
      resources:
        limits:
          cpu: 100m
      readinessProbe:
        tcpSocket:
          port: 8080
EOF
}

# A compliant Pod is admitted once the API server reaches the webhook.
i=0
until pod good registry.example.com/web:1.2.3 false | kubectl create -f - >"$work/good" 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail "compliant pod was not admitted: $(cat "$work/good")"
  sleep 1
done
docker logs "$hook" 2>&1 | grep -F '0 validation errors found when validating good' >/dev/null ||
  fail 'webhook did not validate the compliant pod'

# A non-compliant Pod is denied with the danger findings from the config,
# including the custom check.
status=0
pod bad docker.io/library/nginx:latest true | kubectl create -f - >"$work/bad" 2>&1 || status=$?
test "$status" -ne 0 || fail 'non-compliant pod was admitted'
for line in \
  'admission webhook "polaris.smoke.verity.dev" denied the request:' \
  'Polaris prevented this deployment due to configuration problems:' \
  '- Pod: Host network should not be configured' \
  '- Container main: Should not be running as privileged' \
  '- Container main: Privilege escalation should not be allowed' \
  '- Container main: Image tag should be specified' \
  '- Container main: Image must come from registry.example.com'; do
  grep -F -e "$line" "$work/bad" >/dev/null || fail "denial is missing '$line': $(cat "$work/bad")"
done
# Passing checks (runAsRootAllowed here) are not listed.
test "$(grep -c '^- ' "$work/bad")" -eq 5 || fail "denial does not list exactly five findings: $(cat "$work/bad")"
status=0
kubectl get pod bad -n guarded >/dev/null 2>&1 || status=$?
test "$status" -ne 0 || fail 'denied pod exists'
docker logs "$hook" 2>&1 | grep -F '5 validation errors found when validating bad' >/dev/null ||
  fail 'webhook did not report the danger findings'

printf 'polaris %s smoke test passed\n' "$expected_version"

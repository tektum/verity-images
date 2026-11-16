#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Peers for a real control plane: Verity etcd 3.7, kube-apiserver 1.37 and
# kubectl 1.35, and Python 3.13 for a fake RestSubmitter service, pinned by
# digest.
etcd_index=ghcr.io/tektum/etcd@sha256:fc322841b20ac374159333e013fb417aa712e776380c53dc34ab8a1958c07fd2
api_index=ghcr.io/tektum/kube-apiserver@sha256:b46742424f608bb186b83390c41cbe7f97df411ae3cf8fc3e4578c096a6b57bd
kubectl_index=ghcr.io/tektum/kubectl@sha256:537780af388652be3a0130aacd6d1cfed24704ab6a820c6c7024602ec7777332
python_index=ghcr.io/tektum/python@sha256:d059268a2e4f0ef0cc82bb50c847e69e16e174736758013a153cb36311fa6dd6

id=$$
label="verity-test=spark-operator-$id"
network="verity-spark-$id"
etcd="verity-spark-etcd-$id"
api="verity-spark-api-$id"
submitter="verity-spark-submitter-$id"
webhook="verity-spark-webhook-$id"
nosubmit="verity-spark-nosubmit-$id"
controller="verity-spark-controller-$id"
work=$(mktemp -d)
opns=spark-operator
ns=spark-jobs
# The webhook signs its serving certificate for <svc>.<namespace>.svc; the
# webhook container answers on that name through a network alias.
webhook_host=spark-webhook.$opns.svc

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$controller" "$nosubmit" "$webhook" "$submitter" "$api"; do
    docker logs "$c" >/dev/null 2>&1 || continue
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

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'
expected_commit=$(awk '$1 == "source-commit:" { print $2; exit }' "$here/../melange.yaml")
[ -n "$expected_commit" ] || fail 'could not read the source commit'
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")

# Upstream's image runs as spark (185:185); its entrypoint execs the binary.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 185 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/spark-operator"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/spark ||
  fail 'unexpected working directory'

# Upstream's chart runs read-only, non-root, with every capability dropped.
run() {
  docker run --rm --label "$label" --network none --read-only --cap-drop=ALL "$@"
}

# Version stamps match the recipe, as upstream's Makefile sets them.
run "$image" version >"$work/version" 2>&1 || fail "version failed: $(cat "$work/version")"
grep -Fx "Git Version: v$expected_version" "$work/version" >/dev/null ||
  fail "version is not v$expected_version: $(cat "$work/version")"
grep -Fx "Git Commit: $expected_commit" "$work/version" >/dev/null ||
  fail "commit is not $expected_commit: $(cat "$work/version")"
grep -Ex 'Git Tree State: (clean|dirty)' "$work/version" >/dev/null ||
  fail "tree state is missing: $(cat "$work/version")"
grep -Fx "Platform: linux/$image_arch" "$work/version" >/dev/null ||
  fail "platform is not linux/$image_arch: $(cat "$work/version")"
test "$(run "$image" version --short)" = "Git Version: v$expected_version" ||
  fail 'version --short is wrong'

# CLI surface: the subcommands and flags upstream's Helm chart passes.
run "$image" --help >"$work/help" 2>&1 || fail "help failed: $(cat "$work/help")"
for cmd in controller webhook version; do
  grep -E "^  $cmd " "$work/help" >/dev/null || fail "help is missing the $cmd command"
done
run "$image" controller start --help >"$work/chelp" 2>&1 ||
  fail "controller help failed: $(cat "$work/chelp")"
for flag in --namespaces --leader-election --leader-election-lock-namespace --enable-metrics \
  --metrics-bind-address --health-probe-bind-address --feature-gates \
  --submitter-service-url --driver-pod-creation-grace-period --zap-log-level; do
  grep -F -e "$flag" "$work/chelp" >/dev/null || fail "controller help is missing $flag"
done
run "$image" webhook start --help >"$work/whelp" 2>&1 ||
  fail "webhook help failed: $(cat "$work/whelp")"
for flag in --webhook-cert-dir --webhook-port --webhook-secret-name --webhook-svc-name \
  --mutating-webhook-name --validating-webhook-name --enable-resource-quota-enforcement; do
  grep -F -e "$flag" "$work/whelp" >/dev/null || fail "webhook help is missing $flag"
done
status=0
run "$image" definitely-invalid >"$work/invalid" 2>&1 || status=$?
test "$status" -eq 1 || fail "an unknown command exited $status, want 1"
grep -F 'unknown command "definitely-invalid" for "spark-operator"' "$work/invalid" >/dev/null ||
  fail "unknown command diagnostic is missing: $(cat "$work/invalid")"

# Outside a cluster both components refuse to start and say why.
status=0
run "$image" controller start >"$work/nocluster" 2>&1 || status=$?
test "$status" -ne 0 || fail 'controller outside a cluster unexpectedly succeeded'
grep -F 'KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined' "$work/nocluster" \
  >/dev/null || fail "controller in-cluster diagnostic is missing: $(cat "$work/nocluster")"
status=0
run "$image" webhook start >"$work/nocluster" 2>&1 || status=$?
test "$status" -eq 1 || fail "webhook outside a cluster exited $status, want 1"
grep -F '"msg":"failed to get kube config"' "$work/nocluster" >/dev/null ||
  fail "webhook kubeconfig diagnostic is missing: $(cat "$work/nocluster")"

# The image ships the CRDs generated for this build; install exactly those.
mkdir -p "$work/crds"
holder=$(docker create --label "$label" "$image") || fail 'could not create a container to copy the CRDs'
docker cp "$holder:/usr/share/spark-operator/crds/." "$work/crds/" >/dev/null 2>&1 ||
  fail 'image does not ship /usr/share/spark-operator/crds'
docker rm "$holder" >/dev/null
for crd in sparkapplications scheduledsparkapplications sparkconnects; do
  [ -s "$work/crds/sparkoperator.k8s.io_$crd.yaml" ] || fail "missing the $crd CRD"
done
chmod -R a+rX "$work/crds"

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
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
python_image=$(pull_child "$python_index")

# Control plane: etcd and kube-apiserver with a static admin token. No
# scheduler or kubelet runs; this test plays the kubelet for the driver pod.
mkdir -p "$work/pki" "$work/kube" "$work/submitter"
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

docker network create --label "$label" "$network" >/dev/null
docker run -d --name "$etcd" --label "$label" --network "$network" \
  --tmpfs /var/lib/etcd:uid=65532,gid=65532 "$etcd_image" --data-dir=/var/lib/etcd/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls="http://$etcd:2379" >/dev/null
docker run -d --name "$api" --label "$label" --network "$network" --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/pki:/pki:ro" "$api_image" \
  --etcd-servers="http://$etcd:2379" --secure-port=6443 --cert-dir=/tmp \
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC \
  --service-account-issuer=https://kubernetes.default.svc \
  --service-account-key-file=/pki/sa.key --service-account-signing-key-file=/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/16 >/dev/null

kubectl() {
  timeout 120 docker run --rm -i --label "$label" --network "$network" -v "$work/kube:/kube:ro" \
    -v "$work/crds:/crds:ro" -e KUBECONFIG=/kube/config "$kubectl_image" "$@"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done

# The SparkApplication CRD exceeds the client-side apply annotation limit.
kubectl create -f /crds >"$work/crd" 2>&1 || fail "could not create the CRDs: $(cat "$work/crd")"
kubectl wait --for=condition=Established --timeout=60s \
  crd/sparkapplications.sparkoperator.k8s.io crd/scheduledsparkapplications.sparkoperator.k8s.io \
  crd/sparkconnects.sparkoperator.k8s.io >"$work/established" 2>&1 ||
  fail "CRDs not established: $(cat "$work/established")"
kubectl create namespace "$opns" >/dev/null || fail "could not create namespace $opns"
kubectl create namespace "$ns" >/dev/null || fail "could not create namespace $ns"
# No controller manager runs to create default service accounts.
for sa in default spark; do
  kubectl create serviceaccount -n "$ns" "$sa" >/dev/null || fail "could not create service account $sa"
done

# wait_for DESCRIPTION EXPECTED KUBECTL-ARGS...: poll until kubectl prints EXPECTED.
wait_for() {
  what=$1
  want=$2
  shift 2
  i=0
  # kubectl must succeed: an error must not pass as an empty expected value.
  until out=$(kubectl "$@" 2>/dev/null) && [ "$out" = "$want" ]; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || fail "$what: want '$want', got '$(kubectl "$@" 2>&1)'"
    sleep 2
  done
}

# probe URL: HTTP GET from inside the network, through the submitter container.
probe() {
  docker exec "$submitter" python3 -c '
import sys, urllib.request
print(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode())' "$1"
}

# Fake RestSubmitter service: logs every submission, answers 201 as the real
# service does once it has created the driver pod.
cat >"$work/submitter/submitter.py" <<'EOF'
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(200, {"status": "ok"})

    def do_POST(self):
        if self.path != "/api/v1/spark-submit":
            self.reply(404, {"error_code": "NOT_FOUND", "message": self.path})
            return
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        print("SUBMIT " + json.dumps(request, sort_keys=True), flush=True)
        args = request["spark_submit_args"]
        confs = dict(
            args[i + 1].split("=", 1) for i, a in enumerate(args) if a == "--conf"
        )
        self.reply(201, {
            "submission_id": request["submission_id"],
            "app_name": confs.get("spark.app.name", ""),
            "spark_app_id": "spark-verity-smoke",
            "driver_pod_name": confs.get("spark.kubernetes.driver.pod.name", ""),
            "namespace": confs.get("spark.kubernetes.namespace", ""),
            "duplicate_submission": False,
        })

    def log_message(self, *args):
        sys.stderr.write("%s\n" % (args,))


HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
EOF
chmod 0755 "$work/submitter"
chmod 0644 "$work/submitter/submitter.py"
docker run -d --name "$submitter" --label "$label" --network "$network" --read-only \
  --cap-drop=ALL --user 65532:65532 -v "$work/submitter:/submitter:ro" "$python_image" \
  -u /submitter/submitter.py >/dev/null

# Webhook as upstream's chart runs it: read-only root, no capabilities, the
# serving certificate generated into the image's cert directory.
docker run -d --name "$webhook" --label "$label" --network "$network" \
  --network-alias "$webhook_host" --read-only --cap-drop=ALL \
  --tmpfs /etc/k8s-webhook-server/serving-certs:uid=185,gid=185,mode=0775 \
  -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config "$image" webhook start \
  --namespaces="$ns" --webhook-port=9443 --webhook-secret-name=spark-operator-webhook-certs \
  --webhook-secret-namespace="$opns" --webhook-svc-name=spark-webhook \
  --webhook-svc-namespace="$opns" --mutating-webhook-name=spark-operator-webhook \
  --validating-webhook-name=spark-operator-webhook --health-probe-bind-address=:8081 >/dev/null

# The webhook configurations as upstream's chart renders them, except that the
# client config is a URL on the alias instead of a Service: no kube-proxy runs.
webhook_url="https://$webhook_host:9443"
kubectl apply -f - >"$work/whc" 2>&1 <<EOF || fail "could not create the webhook configurations: $(cat "$work/whc")"
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: spark-operator-webhook
webhooks:
  - name: mutate--v1-pod.sparkoperator.k8s.io
    admissionReviewVersions: [v1]
    clientConfig:
      url: $webhook_url/mutate--v1-pod
    sideEffects: None
    failurePolicy: Fail
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: $ns
    objectSelector:
      matchLabels:
        sparkoperator.k8s.io/launched-by-spark-operator: "true"
    rules:
      - apiGroups: [""]
        apiVersions: [v1]
        resources: [pods]
        operations: [CREATE]
  - name: mutate-sparkoperator-k8s-io-v1beta2-sparkapplication.sparkoperator.k8s.io
    admissionReviewVersions: [v1]
    clientConfig:
      url: $webhook_url/mutate-sparkoperator-k8s-io-v1beta2-sparkapplication
    sideEffects: None
    failurePolicy: Fail
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: $ns
    rules:
      - apiGroups: [sparkoperator.k8s.io]
        apiVersions: [v1beta2]
        resources: [sparkapplications]
        operations: [CREATE, UPDATE]
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: spark-operator-webhook
webhooks:
  - name: validate-sparkoperator-k8s-io-v1beta2-sparkapplication.sparkoperator.k8s.io
    admissionReviewVersions: [v1]
    clientConfig:
      url: $webhook_url/validate-sparkoperator-k8s-io-v1beta2-sparkapplication
    sideEffects: None
    failurePolicy: Fail
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: $ns
    rules:
      - apiGroups: [sparkoperator.k8s.io]
        apiVersions: [v1beta2]
        resources: [sparkapplications]
        operations: [CREATE, UPDATE]
EOF

i=0
until probe "http://$webhook_host:8081/readyz" >"$work/readyz" 2>&1; do
  i=$((i + 1))
  [ "$(docker inspect -f '{{.State.Running}}' "$webhook")" = true ] || fail 'webhook exited early'
  [ "$i" -lt 60 ] || fail "webhook did not become ready: $(cat "$work/readyz")"
  sleep 2
done
grep -Fx ok "$work/readyz" >/dev/null || fail "unexpected webhook readyz body: $(cat "$work/readyz")"

# The webhook stored its generated CA and serving pair in the Secret and
# injected the CA into every webhook entry.
kubectl get secret -n "$opns" spark-operator-webhook-certs -o json >"$work/secret.json" ||
  fail 'the webhook certificate Secret was not created'
jq -e '.data | has("ca-cert.pem") and has("server-cert.pem") and has("server-key.pem")' \
  "$work/secret.json" >/dev/null || fail "unexpected Secret keys: $(jq -c '.data | keys' "$work/secret.json")"
ca=$(jq -r '.data["ca-cert.pem"]' "$work/secret.json")
for kind in mutatingwebhookconfiguration validatingwebhookconfiguration; do
  i=0
  until bundles=$(kubectl get "$kind" spark-operator-webhook \
    -o 'jsonpath={range .webhooks[*]}{.clientConfig.caBundle}{"\n"}{end}' 2>/dev/null) &&
    [ -n "$bundles" ] && ! printf '%s\n' "$bundles" | grep -Fvxq "$ca"; do
    i=$((i + 1))
    [ "$i" -lt 30 ] || fail "$kind did not get the webhook CA"
    sleep 2
  done
done

# The validating webhook rejects a node selector set both on the application
# and on the driver, before anything is stored.
status=0
kubectl apply -f - >"$work/rejected" 2>&1 <<EOF || status=$?
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: rejected
  namespace: $ns
spec:
  type: Scala
  mode: cluster
  image: docker.io/library/spark:4.0.1
  mainClass: org.apache.spark.examples.SparkPi
  mainApplicationFile: local:///opt/spark/examples/jars/spark-examples.jar
  sparkVersion: 4.0.1
  nodeSelector:
    disk: ssd
  driver:
    nodeSelector:
      disk: hdd
  executor:
    instances: 1
EOF
test "$status" -ne 0 || fail 'an application with two node selectors was admitted'
grep -F 'node selector cannot be defined at both SparkApplication and Driver/Executor' \
  "$work/rejected" >/dev/null || fail "validation message is missing: $(cat "$work/rejected")"
kubectl get sparkapplication -n "$ns" rejected >/dev/null 2>&1 &&
  fail 'the rejected application was stored'

# spark_app NAME: an application the operator submits.
spark_app() {
  kubectl apply -f - <<EOF
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: $1
  namespace: $ns
spec:
  type: Scala
  mode: cluster
  image: docker.io/library/spark:4.0.1
  mainClass: org.apache.spark.examples.SparkPi
  mainApplicationFile: local:///opt/spark/examples/jars/spark-examples.jar
  arguments: ["1000"]
  sparkVersion: 4.0.1
  sparkConf:
    spark.verity.smoke: "$1"
  driver:
    cores: 1
    memory: 512m
    serviceAccount: spark
    labels:
      verity.test/role: driver
    env:
      - name: VERITY_SMOKE
        value: "$1"
    tolerations:
      - key: verity.test/smoke
        operator: Exists
        effect: NoSchedule
  executor:
    instances: 1
    cores: 1
    memory: 512m
EOF
}

# Without the RestSubmitter feature gate the controller submits with
# spark-submit, which this image does not ship: the submission fails clearly.
# The pod templates go to /tmp/spark, an emptyDir in upstream's chart.
docker run -d --name "$nosubmit" --label "$label" --network "$network" --read-only --cap-drop=ALL \
  --tmpfs /tmp:uid=185,gid=185 -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config \
  -e KUBERNETES_SERVICE_HOST="$api" -e KUBERNETES_SERVICE_PORT=6443 "$image" controller start \
  --namespaces="$ns" --leader-election=false >/dev/null
spark_app no-spark >"$work/apply" 2>&1 || fail "could not create no-spark: $(cat "$work/apply")"
i=0
until msg=$(kubectl get sparkapplication -n "$ns" no-spark \
  -o 'jsonpath={.status.applicationState.errorMessage}' 2>/dev/null) && [ -n "$msg" ]; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'the spark-submit submission did not fail'
  sleep 2
done
case $msg in
  *'env SPARK_HOME is not specified') ;;
  *) fail "unexpected submission error: $msg" ;;
esac
docker rm -f "$nosubmit" >/dev/null
kubectl delete sparkapplication -n "$ns" no-spark --wait=true >/dev/null ||
  fail 'could not delete no-spark'

# The controller as upstream's chart runs it, with leader election, metrics,
# and the RestSubmitter feature gate pointing at the fake submitter.
docker run -d --name "$controller" --label "$label" --network "$network" --read-only --cap-drop=ALL \
  --tmpfs /tmp:uid=185,gid=185 -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config \
  -e KUBERNETES_SERVICE_HOST="$api" -e KUBERNETES_SERVICE_PORT=6443 "$image" controller start \
  --namespaces="$ns" --leader-election=true --leader-election-lock-name=spark-operator-controller-lock \
  --leader-election-lock-namespace="$opns" --enable-metrics=true --metrics-bind-address=:8080 \
  --metrics-endpoint=/metrics --health-probe-bind-address=:8081 \
  --driver-pod-creation-grace-period=10m --feature-gates=RestSubmitter=true \
  --submitter-service-url="http://$submitter:8080/api/v1/spark-submit" >/dev/null

i=0
until probe "http://$controller:8081/readyz" >"$work/readyz" 2>&1; do
  i=$((i + 1))
  [ "$(docker inspect -f '{{.State.Running}}' "$controller")" = true ] || fail 'controller exited early'
  [ "$i" -lt 60 ] || fail "controller did not become ready: $(cat "$work/readyz")"
  sleep 2
done
grep -Fx ok "$work/readyz" >/dev/null || fail "unexpected controller readyz body: $(cat "$work/readyz")"
i=0
until holder=$(kubectl get lease -n "$opns" spark-operator-controller-lock \
  -o 'jsonpath={.spec.holderIdentity}' 2>/dev/null) && [ -n "$holder" ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'controller did not acquire its leader election lease'
  sleep 2
done
docker logs "$controller" >"$work/clog" 2>&1
grep -F 'Using REST submitter service' "$work/clog" >/dev/null ||
  fail 'controller did not select the REST submitter'

spark_app pi >"$work/apply" 2>&1 || fail "could not create pi: $(cat "$work/apply")"
wait_for 'pi was not submitted' SUBMITTED \
  get sparkapplication -n "$ns" pi -o 'jsonpath={.status.applicationState.state}'
kubectl get sparkapplication -n "$ns" pi -o json >"$work/pi.json"

# The submitter received the spark-submit arguments upstream builds for this
# application: cluster mode against this API server, the driver pod name and
# labels, the user conf, and an inline driver template carrying the owner.
docker logs "$submitter" 2>/dev/null | sed -n 's/^SUBMIT //p' >"$work/submissions"
test "$(wc -l <"$work/submissions")" -eq 1 ||
  fail "want exactly one submission, got: $(cat "$work/submissions")"
submission_id=$(jq -r '.status.submissionID' "$work/pi.json")
app_uid=$(jq -r '.metadata.uid' "$work/pi.json")
jq -e --arg id "$submission_id" --arg master "k8s://https://$api:6443" --arg ns "$ns" \
  --arg uid "$app_uid" '
  .submission_id == $id
  and (.spark_submit_args | index(["--master", $master]) != null)
  and (.spark_submit_args | index(["--deploy-mode", "cluster"]) != null)
  and (.spark_submit_args | index(["--class", "org.apache.spark.examples.SparkPi"]) != null)
  and (.spark_submit_args[-2:] == ["local:///opt/spark/examples/jars/spark-examples.jar", "1000"])
  and ([.spark_submit_args[] | select(. == "spark.kubernetes.namespace=" + $ns
       or . == "spark.kubernetes.driver.pod.name=pi-driver"
       or . == "spark.kubernetes.container.image=docker.io/library/spark:4.0.1"
       or . == "spark.verity.smoke=pi"
       or . == "spark.kubernetes.authenticate.driver.serviceAccountName=spark"
       or . == "spark.kubernetes.driver.label.sparkoperator.k8s.io/launched-by-spark-operator=true"
       or . == "spark.kubernetes.driver.label.sparkoperator.k8s.io/submission-id=" + $id
       or . == "spark.executor.instances=1")] | length == 8)
  and (.driver_pod_template.metadata.ownerReferences[0].uid == $uid)
  and (.driver_pod_template.spec.containers[0].name == "spark-kubernetes-driver")
' "$work/submissions" >/dev/null || fail "unexpected submission: $(cat "$work/submissions")"

# The mutating webhook defaulted the application on admission.
jq -e '.spec.restartPolicy.type == "Never"' "$work/pi.json" >/dev/null ||
  fail "application was not defaulted: $(jq -c '.spec.restartPolicy' "$work/pi.json")"

# Play the submitter and the kubelet: create the driver pod Spark would create,
# then report it running and completed.
kubectl apply -f - >"$work/pod" 2>&1 <<EOF || fail "could not create the driver pod: $(cat "$work/pod")"
apiVersion: v1
kind: Pod
metadata:
  name: pi-driver
  namespace: $ns
  labels:
    spark-role: driver
    spark-app-selector: spark-verity-smoke
    sparkoperator.k8s.io/app-name: pi
    sparkoperator.k8s.io/launched-by-spark-operator: "true"
    sparkoperator.k8s.io/submission-id: $submission_id
spec:
  restartPolicy: Never
  serviceAccountName: spark
  containers:
    - name: spark-kubernetes-driver
      image: docker.io/library/spark:4.0.1
EOF

# The pod webhook applied the driver spec from the application.
kubectl get pod -n "$ns" pi-driver -o json >"$work/driver.json"
jq -e --arg uid "$app_uid" '
  (.metadata.ownerReferences | map(select(.kind == "SparkApplication" and .uid == $uid)) | length == 1)
  and (.spec.tolerations | map(select(.key == "verity.test/smoke")) | length == 1)
  and (.spec.containers[0].env | map(select(.name == "VERITY_SMOKE" and .value == "pi")) | length == 1)
' "$work/driver.json" >/dev/null ||
  fail "driver pod was not mutated: $(jq -c '{owners: .metadata.ownerReferences, tolerations: .spec.tolerations, env: .spec.containers[0].env}' "$work/driver.json")"

pod_status() {
  kubectl patch pod -n "$ns" pi-driver --subresource=status --type=merge -p "$1" >"$work/patch" 2>&1 ||
    fail "could not patch the driver status: $(cat "$work/patch")"
}
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
pod_status "{\"status\":{\"phase\":\"Running\",\"startTime\":\"$now\",\"containerStatuses\":[{\"name\":\"spark-kubernetes-driver\",\"image\":\"docker.io/library/spark:4.0.1\",\"imageID\":\"\",\"ready\":true,\"restartCount\":0,\"started\":true,\"state\":{\"running\":{\"startedAt\":\"$now\"}}}]}}"
wait_for 'pi did not start running' RUNNING \
  get sparkapplication -n "$ns" pi -o 'jsonpath={.status.applicationState.state}'
wait_for 'driver info was not recorded' pi-driver/spark-verity-smoke \
  get sparkapplication -n "$ns" pi -o 'jsonpath={.status.driverInfo.podName}/{.status.sparkApplicationId}'

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
pod_status "{\"status\":{\"phase\":\"Succeeded\",\"containerStatuses\":[{\"name\":\"spark-kubernetes-driver\",\"image\":\"docker.io/library/spark:4.0.1\",\"imageID\":\"\",\"ready\":false,\"restartCount\":0,\"started\":false,\"state\":{\"terminated\":{\"exitCode\":0,\"reason\":\"Completed\",\"startedAt\":\"$now\",\"finishedAt\":\"$now\"}}}]}}"
wait_for 'pi did not complete' COMPLETED \
  get sparkapplication -n "$ns" pi -o 'jsonpath={.status.applicationState.state}'

# Metrics report the lifecycle the controller drove.
probe "http://$controller:8080/metrics" >"$work/metrics" 2>&1 || fail 'metrics endpoint failed'
# The running gauge is back to zero once the application completed.
for pair in spark_application_submit_count=1 spark_application_success_count=1 \
  spark_application_running_count=0; do
  metric=${pair%=*}
  grep -E "^$metric(\{[^}]*\})? ${pair#*=}\$" "$work/metrics" >/dev/null ||
    fail "metric $metric is not ${pair#*=}: $(grep -F "$metric" "$work/metrics" || true)"
done

# The controller only manages its configured namespaces.
kubectl create namespace unwatched >/dev/null || fail 'could not create namespace unwatched'
kubectl apply -f - >"$work/apply" 2>&1 <<EOF || fail "could not create the unwatched app: $(cat "$work/apply")"
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: ignored
  namespace: unwatched
spec:
  type: Scala
  mode: cluster
  image: docker.io/library/spark:4.0.1
  mainApplicationFile: local:///opt/spark/examples/jars/spark-examples.jar
  sparkVersion: 4.0.1
  driver: {}
  executor: {}
EOF
sleep 10
test -z "$(kubectl get sparkapplication -n unwatched ignored -o 'jsonpath={.status.applicationState.state}')" ||
  fail 'the controller handled an application outside its namespaces'
test "$(docker logs "$submitter" 2>/dev/null | grep -c '^SUBMIT ')" -eq 1 ||
  fail 'the unwatched application was submitted'

# SIGTERM shuts both components down cleanly.
for c in "$controller" "$webhook"; do
  docker stop --time 30 "$c" >/dev/null || fail "could not stop $c"
  code=$(docker inspect -f '{{.State.ExitCode}}' "$c")
  test "$code" -eq 0 || fail "$c exited $code after SIGTERM"
done

echo "spark-operator $expected_version: OK"

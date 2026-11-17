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
network="verity-clusterctl-$id"
etcd="verity-clusterctl-etcd-$id"
api="verity-clusterctl-api-$id"
work=$(mktemp -d)
# Bind-mount sources exist before the first run so Docker never creates them.
mkdir -p "$work/repo" "$work/cfg"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$api" 2>&1 | tail -n 20 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f "$api" "$etcd" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'
expected_commit=$(awk '$1 == "source-commit:" { print $2; exit }' "$here/../melange.yaml")
[ -n "$expected_commit" ] || fail 'could not read the recipe commit'
major=${expected_version%%.*}
minor=${expected_version#*.}
minor=${minor%%.*}
patch=${expected_version##*.}
# The synthetic older provider release must differ from the current one so
# init/upgrade have something to move between. On an x.y.0 release use the
# previous minor's .0; otherwise use this minor's .0.
old_minor=$minor
if [ "$patch" = 0 ]; then
  [ "$minor" -gt 0 ] || fail "no synthetic older release below v$expected_version"
  old_minor=$((minor - 1))
fi

# OCI contract: upstream distroless nonroot user 65532, WORKDIR /, HOME for
# $HOME/.config/cluster-api.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/clusterctl"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ||
  fail 'unexpected working directory'
envs=$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image")
printf '%s\n' "$envs" | grep -Fx 'HOME=/home/nonroot' >/dev/null || fail 'HOME is not /home/nonroot'
printf '%s\n' "$envs" | grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

# Every clusterctl run is hardened, read-only, with a tmpfs HOME, and never
# checks GitHub for a newer release. Offline runs use --network none.
run() {
  docker run --rm -i --read-only --cap-drop=ALL --security-opt=no-new-privileges \
    --tmpfs /home/nonroot:uid=65532,gid=65532 -e CLUSTERCTL_DISABLE_VERSIONCHECK=true "$@"
}
offline() {
  run --network none -v "$work/repo:/repo:ro" -v "$work/cfg:/cfg:ro" "$image" "$@"
}

# expect_fail OUTPUT_NAME MESSAGE ARGS...: the command must fail with MESSAGE.
expect_fail() {
  out="$work/$1"
  message=$2
  shift 2
  status=0
  offline "$@" >"$out" 2>&1 || status=$?
  test "$status" -ne 0 || fail "clusterctl $* unexpectedly succeeded: $(cat "$out")"
  grep -F -e "$message" "$out" >/dev/null || fail "clusterctl $* missing '$message': $(cat "$out")"
}

# Help, unknown flag and the upstream /clusterctl path.
offline --help >"$work/help" 2>&1 || fail "help failed: $(cat "$work/help")"
for command in init upgrade delete describe generate move 'get '; do
  grep -E "^  $command" "$work/help" >/dev/null || fail "help is missing the $command command"
done
expect_fail invalid 'unknown flag: --definitely-invalid' --definitely-invalid
run --network none --entrypoint /clusterctl "$image" version -o short >"$work/compat" 2>&1 ||
  fail "compatibility path /clusterctl does not run: $(cat "$work/compat")"

# Version stamps from upstream hack/scripts/release/version.sh.
offline version -o short >"$work/short" 2>&1 || fail "version failed: $(cat "$work/short")"
test "$(cat "$work/short")" = "v$expected_version" || fail "unexpected short version: $(cat "$work/short")"
offline version -o json >"$work/version.json" 2>&1 || fail "version -o json failed"
jq -e --arg v "v$expected_version" --arg c "$expected_commit" --arg ma "$major" --arg mi "$minor" '
  .clusterctl
  | .gitVersion == $v and .gitCommit == $c and .major == $ma and .minor == $mi
    and (.gitTreeState == "clean" or .gitTreeState == "dirty")
    and (.buildDate | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
    and (.goVersion | startswith("go1.")) and .compiler == "gc"
    and (.platform | test("^linux/(amd64|arm64)$"))' "$work/version.json" >/dev/null ||
  fail "unexpected version stamps: $(cat "$work/version.json")"
expect_fail badout 'invalid output format' version -o xml

# Air-gapped: without CLUSTERCTL_DISABLE_VERSIONCHECK the upgrade notice must
# fail silently when no network is reachable.
docker run --rm --network none --read-only --cap-drop=ALL --tmpfs /home/nonroot:uid=65532,gid=65532 \
  "$image" version -o short >"$work/airgap" 2>&1 || fail "air-gapped version check failed: $(cat "$work/airgap")"
test "$(cat "$work/airgap")" = "v$expected_version" || fail "air-gapped run printed: $(cat "$work/airgap")"
# clusterctl keeps its state under $HOME/.config, so a read-only HOME is reported.
status=0
docker run --rm --network none --read-only --cap-drop=ALL "$image" version -o short \
  >"$work/rohome" 2>&1 || status=$?
test "$status" -ne 0 || fail 'read-only HOME unexpectedly succeeded'
grep -F 'could not create any of the following paths: [/home/nonroot/.config /etc/xdg]' "$work/rohome" \
  >/dev/null || fail "read-only HOME diagnostic is missing: $(cat "$work/rohome")"

# Local file-based provider repositories: {provider}/{version}/{file}.
crd() { # plural kind group version
  cat <<EOF
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: $1.$3
spec:
  group: $3
  names: {kind: $2, listKind: $2List, plural: $1, singular: $(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')}
  scope: Namespaced
  versions:
    - name: $4
      served: true
      storage: true
      subresources: {status: {}}
      schema:
        openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
EOF
}
manager() { # namespace name image [arg...]
  ns=$1 name=$2 img=$3
  shift 3
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $name
  namespace: $ns
spec:
  selector:
    matchLabels: {control-plane: $name}
  template:
    metadata:
      labels: {control-plane: $name}
    spec:
      containers:
        - name: manager
          image: $img
EOF
  [ "$#" -eq 0 ] || printf '          args:\n'
  for arg in "$@"; do
    printf '            - %s\n' "$arg"
  done
}
metadata() {
  cat <<EOF
apiVersion: clusterctl.cluster.x-k8s.io/v1alpha3
kind: Metadata
releaseSeries:
  - {major: $major, minor: $minor, contract: v1beta2}
EOF
  if [ "$old_minor" != "$minor" ]; then
    printf '  - {major: %s, minor: %s, contract: v1beta2}\n' "$major" "$old_minor"
  fi
}

repo=$work/repo
v=v$expected_version
old=v$major.$old_minor.0
mkdir -p "$repo/cluster-api/$v" "$repo/bootstrap-kubeadm/$v" "$repo/control-plane-kubeadm/$v" \
  "$repo/infrastructure-verity/$v" "$repo/infrastructure-verity/$old" "$repo/cert-manager/v1.19.1" \
  "$work/cfg" "$work/out" "$work/overrides/infrastructure-verity/$v"
# Upstream template and manifest placeholders stay literal in these heredocs.
# shellcheck disable=SC2016
{
  manager capi-system capi-controller-manager "registry.k8s.io/cluster-api/cluster-api-controller:$v" \
    '--feature-gates=ClusterTopology=${CLUSTER_TOPOLOGY:=true}'
  for kind in Cluster ClusterClass Machine MachineSet MachineDeployment MachinePool; do
    plural=$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')
    case $plural in *s) plural="${plural}es" ;; *) plural="${plural}s" ;; esac
    crd "$plural" "$kind" cluster.x-k8s.io v1beta2
  done
} >"$repo/cluster-api/$v/core-components.yaml"
manager capi-kubeadm-bootstrap-system capi-kubeadm-bootstrap-controller-manager \
  "registry.k8s.io/cluster-api/kubeadm-bootstrap-controller:$v" \
  >"$repo/bootstrap-kubeadm/$v/bootstrap-components.yaml"
{
  manager capi-kubeadm-control-plane-system capi-kubeadm-control-plane-controller-manager \
    "registry.k8s.io/cluster-api/kubeadm-control-plane-controller:$v"
  crd kubeadmcontrolplanetemplates KubeadmControlPlaneTemplate controlplane.cluster.x-k8s.io v1beta2
} >"$repo/control-plane-kubeadm/$v/control-plane-components.yaml"
# shellcheck disable=SC2016
{
  manager verity-system verity-controller-manager "registry.invalid/verity/manager:$v" \
    '--region=${VERITY_REGION}' '--sync-period=${VERITY_SYNC_PERIOD:=10m}'
  crd verityclustertemplates VerityClusterTemplate infrastructure.cluster.x-k8s.io v1beta2
} >"$repo/infrastructure-verity/$v/infrastructure-components.yaml"
# shellcheck disable=SC2016
manager verity-system verity-controller-manager "registry.invalid/verity/manager:$old" \
  '--region=${VERITY_REGION}' >"$repo/infrastructure-verity/$old/infrastructure-components.yaml"
{
  manager cert-manager cert-manager quay.io/jetstack/cert-manager-controller:v1.19.1
  crd issuers Issuer cert-manager.io v1
  crd certificates Certificate cert-manager.io v1
} >"$repo/cert-manager/v1.19.1/cert-manager.yaml"
for dir in cluster-api/$v bootstrap-kubeadm/$v control-plane-kubeadm/$v \
  infrastructure-verity/$v infrastructure-verity/$old; do
  metadata >"$repo/$dir/metadata.yaml"
done
sed 's/--region=/--zone=/' "$repo/infrastructure-verity/$v/infrastructure-components.yaml" \
  >"$work/overrides/infrastructure-verity/$v/infrastructure-components.yaml"
mv "$work/overrides" "$repo/overrides"

# Flavors: the default and dev templates use a ClusterClass that clusterctl
# inlines from clusterclass-<name>.yaml in the same release directory.
# shellcheck disable=SC2016
template() { # class
  cat <<EOF
apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  name: \${CLUSTER_NAME}
  namespace: \${NAMESPACE}
spec:
  topology:
    classRef: {name: $1}
    version: \${KUBERNETES_VERSION}
    controlPlane: {replicas: \${CONTROL_PLANE_MACHINE_COUNT}}
    workers:
      machineDeployments:
        - {class: default-worker, name: md-0, replicas: \${WORKER_MACHINE_COUNT}}
    variables:
      - {name: region, value: \${VERITY_REGION}}
      - {name: imageRepository, value: "\${VERITY_IMAGE_REPOSITORY:=registry.example/verity}"}
EOF
}
clusterclass() { # class
  cat <<EOF
apiVersion: cluster.x-k8s.io/v1beta2
kind: ClusterClass
metadata:
  name: $1
  namespace: \${NAMESPACE}
spec:
  infrastructure:
    templateRef: {apiVersion: infrastructure.cluster.x-k8s.io/v1beta2, kind: VerityClusterTemplate, name: $1-cluster}
  controlPlane:
    templateRef: {apiVersion: controlplane.cluster.x-k8s.io/v1beta2, kind: KubeadmControlPlaneTemplate, name: $1-control-plane}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: VerityClusterTemplate
metadata:
  name: $1-cluster
  namespace: \${NAMESPACE}
spec:
  template:
    spec:
      region: \${VERITY_REGION}
      endpointDomain: "\${VERITY_ENDPOINT_DOMAIN:=cluster.example}"
EOF
}
template verity-default >"$repo/infrastructure-verity/$v/cluster-template.yaml"
template verity-dev >"$repo/infrastructure-verity/$v/cluster-template-dev.yaml"
clusterclass verity-default >"$repo/infrastructure-verity/$v/clusterclass-verity-default.yaml"
clusterclass verity-dev >"$repo/infrastructure-verity/$v/clusterclass-verity-dev.yaml"
template verity-old-release >"$repo/infrastructure-verity/$old/cluster-template.yaml"
clusterclass verity-old-release >"$repo/infrastructure-verity/$old/clusterclass-verity-old-release.yaml"

# Built-in providers are overridden by name, so nothing resolves to GitHub.
# The verity URL uses `latest`, resolved from the local release directories.
cat >"$work/cfg/clusterctl.yaml" <<EOF
providers:
  - name: cluster-api
    url: file:///repo/cluster-api/$v/core-components.yaml
    type: CoreProvider
  - name: kubeadm
    url: /repo/bootstrap-kubeadm/$v/bootstrap-components.yaml
    type: BootstrapProvider
  - name: kubeadm
    url: /repo/control-plane-kubeadm/$v/control-plane-components.yaml
    type: ControlPlaneProvider
  - name: verity
    url: file:///repo/infrastructure-verity/latest/infrastructure-components.yaml
    type: InfrastructureProvider
cert-manager:
  url: /repo/cert-manager/v1.19.1/cert-manager.yaml
  version: v1.19.1
VERITY_REGION: config-region
EOF
cat >"$work/cfg/mirror.yaml" <<EOF
providers:
  - name: verity
    url: /repo/infrastructure-verity/$v/infrastructure-components.yaml
    type: InfrastructureProvider
images:
  all:
    repository: mirror.local/capi
  infrastructure-verity:
    tag: v9.9.9
overridesFolder: /repo/overrides
VERITY_REGION: mirror-region
EOF
cat >"$work/cfg/bare.yaml" <<EOF
providers:
  - name: verity
    url: /repo/infrastructure-verity/$v/infrastructure-components.yaml
    type: InfrastructureProvider
EOF
chmod -R a+rX "$work/repo" "$work/cfg"
chmod 0777 "$work/out"
cfg=--config=/cfg/clusterctl.yaml

offline config repositories "$cfg" >"$work/repos" 2>&1 || fail "config repositories failed: $(cat "$work/repos")"
grep -E '^cluster-api +CoreProvider +file:///repo/cluster-api/v[0-9.]+/ +core-components.yaml' \
  "$work/repos" >/dev/null || fail "core provider is not the local repository: $(cat "$work/repos")"
grep -E '^verity +InfrastructureProvider +file:///repo/infrastructure-verity/latest/ ' \
  "$work/repos" >/dev/null || fail "verity provider is missing: $(cat "$work/repos")"

# generate provider: `latest` resolves to the highest local release; variables
# come from the config file, the environment and template defaults.
offline generate provider -i verity --describe "$cfg" >"$work/describe" 2>&1 ||
  fail "generate provider --describe failed: $(cat "$work/describe")"
for line in "Version:            $v" 'TargetNamespace:    verity-system' '  - VERITY_REGION' \
  '  - VERITY_SYNC_PERIOD' "  - registry.invalid/verity/manager:$v"; do
  grep -Fx -e "$line" "$work/describe" >/dev/null || fail "provider description is missing '$line': $(cat "$work/describe")"
done
offline generate provider -i "verity:$v" -n verity-ops "$cfg" >"$work/provider" 2>&1 ||
  fail "generate provider failed: $(cat "$work/provider")"
for line in '- --region=config-region' '- --sync-period=10m' 'namespace: verity-ops' \
  'cluster.x-k8s.io/provider: infrastructure-verity'; do
  grep -F -e "$line" "$work/provider" >/dev/null || fail "provider yaml is missing '$line': $(cat "$work/provider")"
done
run --network none -e VERITY_REGION=env-region -e VERITY_SYNC_PERIOD=5m -v "$work/repo:/repo:ro" \
  -v "$work/cfg:/cfg:ro" "$image" generate provider -i "verity:$v" "$cfg" >"$work/provider-env" 2>&1 ||
  fail "generate provider with environment failed: $(cat "$work/provider-env")"
grep -F -e '- --region=env-region' "$work/provider-env" >/dev/null || fail 'environment does not override the config file'
grep -F -e '- --sync-period=5m' "$work/provider-env" >/dev/null || fail 'environment does not override the default'
offline generate provider -i "verity:$v" --raw "$cfg" >"$work/raw" 2>&1 || fail 'generate provider --raw failed'
# shellcheck disable=SC2016
grep -F -e '- --region=${VERITY_REGION}' "$work/raw" >/dev/null || fail '--raw substituted variables'
expect_fail unset 'value for variables [VERITY_REGION] is not set' \
  generate provider -i "verity:$v" --config=/cfg/bare.yaml
expect_fail unknown 'failed to get configuration for the InfrastructureProvider with name nope' \
  generate provider -i nope:v1.0.0 "$cfg"
expect_fail missing-release "stat /repo/infrastructure-verity/v0.0.1/metadata.yaml: no such file or directory" \
  generate provider -i verity:v0.0.1 "$cfg"

# Image overrides and the local overrides folder.
offline generate provider -i "verity:$v" --config=/cfg/mirror.yaml >"$work/mirror" 2>&1 ||
  fail "generate provider with overrides failed: $(cat "$work/mirror")"
grep -F 'image: mirror.local/capi/manager:v9.9.9' "$work/mirror" >/dev/null || fail "image override not applied: $(cat "$work/mirror")"
grep -F -e '- --zone=mirror-region' "$work/mirror" >/dev/null || fail "overrides folder not applied: $(cat "$work/mirror")"
grep -F "Using override=\"infrastructure-components.yaml\" provider=\"infrastructure-verity\" version=\"$v\"" \
  "$work/mirror" >/dev/null || fail 'override log line is missing'

# generate cluster: flavors, flags as variables, ClusterClass inlining.
offline generate cluster demo -i "verity:$v" -f dev -n team-a --list-variables "$cfg" >"$work/vars" 2>&1 ||
  fail "--list-variables failed: $(cat "$work/vars")"
sed -n '/Required Variables:/,/^$/p' "$work/vars" | grep -Fx '  - KUBERNETES_VERSION' >/dev/null ||
  fail "KUBERNETES_VERSION is not required: $(cat "$work/vars")"
grep -E '^  - VERITY_IMAGE_REPOSITORY +\(defaults to "registry.example/verity"\)$' "$work/vars" >/dev/null ||
  fail "template default is not listed: $(cat "$work/vars")"
grep -E '^  - NAMESPACE +\(defaults to team-a\)$' "$work/vars" >/dev/null || fail 'namespace default is not listed'
generate_demo() {
  run --network none -e VERITY_ENDPOINT_DOMAIN=env.example -v "$work/repo:/repo:ro" -v "$work/cfg:/cfg:ro" \
    -v "$work/out:/out" "$image" generate cluster demo -i "verity:$v" -f dev -n team-a \
    --kubernetes-version v1.37.0 --worker-machine-count 3 --control-plane-machine-count 5 "$cfg" "$@"
}
generate_demo >"$work/demo-dev.yaml" 2>&1 || fail "generate cluster failed: $(cat "$work/demo-dev.yaml")"
for line in 'kind: ClusterClass' '  name: verity-dev' 'kind: VerityClusterTemplate' '      endpointDomain: env.example' \
  '      region: config-region' '  name: demo' '  namespace: team-a' '    version: v1.37.0' \
  '      replicas: 5' '        replicas: 3' '      value: registry.example/verity'; do
  grep -Fx -e "$line" "$work/demo-dev.yaml" >/dev/null ||
    fail "cluster template is missing '$line': $(cat "$work/demo-dev.yaml")"
done
# --write-to creates a file owned by UID 65532 with mode 0600 in the mounted directory.
generate_demo --write-to /out/demo.yaml >"$work/gen" 2>&1 || fail "--write-to failed: $(cat "$work/gen")"
test ! -s "$work/gen" || fail "--write-to also printed: $(cat "$work/gen")"
test "$(stat -c '%u %a %s' "$work/out/demo.yaml")" = "65532 600 $(wc -c <"$work/demo-dev.yaml" | tr -d ' ')" ||
  fail "unexpected --write-to file: $(stat -c '%u %a %s' "$work/out/demo.yaml")"
test "$(grep -c '^kind: ' "$work/demo-dev.yaml")" = 3 || fail 'expected ClusterClass, template and Cluster'
offline generate cluster demo -i "verity:$v" -n team-a --kubernetes-version v1.37.0 "$cfg" >"$work/default" 2>&1 ||
  fail "default flavor failed: $(cat "$work/default")"
grep -Fx '      name: verity-default' "$work/default" >/dev/null ||
  fail "default flavor not used: $(cat "$work/default")"
expect_fail no-flavor "/repo/infrastructure-verity/$v/cluster-template-nope.yaml: no such file or directory" \
  generate cluster demo -i "verity:$v" -f nope -n team-a --kubernetes-version v1.37.0 "$cfg"
expect_fail no-k8s-version 'value for variables [KUBERNETES_VERSION] is not set' \
  generate cluster demo -i "verity:$v" -n team-a "$cfg"
expect_fail no-namespace 'Cannot auto-discover target namespace' \
  generate cluster demo -i "verity:$v" --kubernetes-version v1.37.0 "$cfg"
expect_fail no-version "Cannot auto-discover version for the provider \"verity\"" \
  generate cluster demo -i verity -n team-a --kubernetes-version v1.37.0 "$cfg"

# generate yaml: file and stdin, defaults, missing variables.
# shellcheck disable=SC2016
printf 'a: ${FOO}\nb: ${BAR:-fallback}\nc: ${BAZ:=assigned}\n' >"$work/cfg/plain.yaml"
chmod 0644 "$work/cfg/plain.yaml"
offline generate yaml --from /cfg/plain.yaml --list-variables >"$work/yvars" 2>&1 || fail 'yaml --list-variables failed'
test "$(grep -c '^  - ' "$work/yvars")" = 3 || fail "unexpected yaml variables: $(cat "$work/yvars")"
printf 'a: one\nb: fallback\nc: assigned\n' >"$work/yexpected"
run --network none -e FOO=one -v "$work/cfg:/cfg:ro" "$image" generate yaml --from /cfg/plain.yaml \
  >"$work/yfile" 2>&1 || fail "generate yaml failed: $(cat "$work/yfile")"
cmp -s "$work/yexpected" "$work/yfile" || fail "unexpected yaml from file: $(cat "$work/yfile")"
run --network none -e FOO=one "$image" generate yaml <"$work/cfg/plain.yaml" >"$work/ystdin" 2>&1 ||
  fail "generate yaml from stdin failed: $(cat "$work/ystdin")"
cmp -s "$work/yexpected" "$work/ystdin" || fail "unexpected yaml from stdin: $(cat "$work/ystdin")"
expect_fail yunset 'value for variables [FOO] is not set' generate yaml --from /cfg/plain.yaml

# Management cluster: etcd and kube-apiserver with a static admin token.
mkdir -p "$work/pki" "$work/kube"
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
      namespace: fleet
current-context: smoke
EOF
chmod 0644 "$work/pki/sa.key" "$work/pki/tokens.csv" "$work/kube/config"

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

docker network create --internal "$network" >/dev/null
docker run -d --name "$etcd" --network "$network" --tmpfs /var/lib/etcd:uid=65532,gid=65532 \
  "$etcd_image" --data-dir=/var/lib/etcd/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls="http://$etcd:2379" >/dev/null
# An internal network has no default route, so kube-apiserver cannot pick an
# advertise address; nothing reaches it through the kubernetes Service here.
docker run -d --name "$api" --network "$network" --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$work/pki:/pki:ro" "$api_image" \
  --advertise-address=127.0.0.1 --endpoint-reconciler-type=none \
  --etcd-servers="http://$etcd:2379" --secure-port=6443 --cert-dir=/tmp \
  --token-auth-file=/pki/tokens.csv --authorization-mode=RBAC \
  --service-account-issuer=https://kubernetes.default.svc \
  --service-account-key-file=/pki/sa.key --service-account-signing-key-file=/pki/sa.key \
  --service-cluster-ip-range=10.96.0.0/16 >/dev/null

kubectl() {
  docker run --rm -i --network "$network" -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config \
    "$kubectl_image" "$@"
}
# The network is internal: the management cluster is the only reachable peer.
cluster() {
  run --network "$network" -v "$work/kube:/kube:ro" -e KUBECONFIG=/kube/config \
    -v "$work/repo:/repo:ro" -v "$work/cfg:/cfg:ro" "$image" "$@"
}
expect_cluster_fail() { # output message args...
  out="$work/$1"
  message=$2
  shift 2
  status=0
  cluster "$@" >"$out" 2>&1 || status=$?
  test "$status" -ne 0 || fail "clusterctl $* unexpectedly succeeded: $(cat "$out")"
  grep -F -e "$message" "$out" >/dev/null || fail "clusterctl $* missing '$message': $(cat "$out")"
}

i=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'kube-apiserver did not become ready'
  sleep 2
done
kubectl create namespace fleet >/dev/null || fail 'cannot create namespace fleet'

# Namespace from the kubeconfig context; template from a ConfigMap.
cluster generate cluster demo -i "verity:$v" --kubernetes-version v1.37.0 "$cfg" >"$work/ctx" 2>&1 ||
  fail "generate cluster with kubeconfig failed: $(cat "$work/ctx")"
test "$(grep -c '^  namespace: fleet$' "$work/ctx")" = 3 || fail "context namespace not used: $(cat "$work/ctx")"
# shellcheck disable=SC2016
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: ${CLUSTER_NAME}-settings\ndata:\n  region: ${VERITY_REGION}\n' \
  >"$work/cm-template.yaml"
kubectl -n fleet create configmap verity-template --from-file=template=/dev/stdin <"$work/cm-template.yaml" \
  >/dev/null || fail 'cannot create the template ConfigMap'
cluster generate cluster edge --from-config-map verity-template "$cfg" >"$work/cm" 2>&1 ||
  fail "--from-config-map failed: $(cat "$work/cm")"
for line in '  name: edge-settings' '  namespace: fleet' '  region: config-region'; do
  grep -Fx -e "$line" "$work/cm" >/dev/null || fail "ConfigMap template is missing '$line': $(cat "$work/cm")"
done
expect_cluster_fail cm-missing 'configmaps "absent" not found' \
  generate cluster edge --from-config-map absent "$cfg"

# init list-images reads the local repositories only.
cluster init list-images -i "verity:$old" "$cfg" >"$work/images" 2>&1 || fail "list-images failed: $(cat "$work/images")"
printf '%s\n' quay.io/jetstack/cert-manager-controller:v1.19.1 "registry.invalid/verity/manager:$old" \
  "registry.k8s.io/cluster-api/cluster-api-controller:$v" "registry.k8s.io/cluster-api/kubeadm-bootstrap-controller:$v" \
  "registry.k8s.io/cluster-api/kubeadm-control-plane-controller:$v" >"$work/images-expected"
cmp -s "$work/images-expected" "$work/images" || fail "unexpected init images: $(cat "$work/images")"

# An unknown provider fails before clusterctl writes to the cluster.
expect_cluster_fail init-unknown 'failed to get configuration for the InfrastructureProvider with name nope' \
  init -i nope:v1.0.0 "$cfg"
if kubectl get namespace cert-manager >/dev/null 2>&1; then
  fail 'failed init installed cert-manager'
fi

# init installs cert-manager from the local URL, then every provider. No
# controller pods run, so only the API objects and the inventory are asserted.
cluster init -i "verity:$old" "$cfg" >"$work/init" 2>&1 || fail "init failed: $(cat "$work/init")"
for line in 'Installing cert-manager version="v1.19.1"' \
  "Installing provider=\"cluster-api\" version=\"$v\" targetNamespace=\"capi-system\"" \
  "Installing provider=\"infrastructure-verity\" version=\"$old\" targetNamespace=\"verity-system\"" \
  'Your management cluster has been initialized successfully!'; do
  grep -F -e "$line" "$work/init" >/dev/null || fail "init output is missing '$line': $(cat "$work/init")"
done
kubectl get providers.clusterctl.cluster.x-k8s.io -A \
  -o jsonpath='{range .items[*]}{.metadata.name} {.type} {.version}{"\n"}{end}' | sort >"$work/inventory" ||
  fail 'cannot read the provider inventory'
printf '%s\n' "bootstrap-kubeadm BootstrapProvider $v" "cluster-api CoreProvider $v" \
  "control-plane-kubeadm ControlPlaneProvider $v" "infrastructure-verity InfrastructureProvider $old" \
  >"$work/inventory-expected"
cmp -s "$work/inventory-expected" "$work/inventory" || fail "unexpected inventory: $(cat "$work/inventory")"
args=$(kubectl -n verity-system get deployment verity-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[0].args}') || fail 'verity deployment is missing'
test "$args" = '["--region=config-region"]' || fail "unexpected deployment args: $args"
kubectl get crd certificates.cert-manager.io >/dev/null 2>&1 || fail 'cert-manager CRDs were not installed'

# The installed release decides the template version when none is given.
expect_cluster_fail installed-version "/repo/infrastructure-verity/$old/cluster-template-dev.yaml" \
  generate cluster demo -i verity -f dev --kubernetes-version v1.37.0 "$cfg"

# upgrade plan and apply against the local repository.
cluster upgrade plan "$cfg" >"$work/plan" 2>&1 || fail "upgrade plan failed: $(cat "$work/plan")"
grep -E "^infrastructure-verity +verity-system +InfrastructureProvider +$old +$v\$" "$work/plan" >/dev/null ||
  fail "upgrade plan does not offer $v: $(cat "$work/plan")"
grep -E "^cluster-api +capi-system +CoreProvider +$v +Already up to date\$" "$work/plan" >/dev/null ||
  fail "core provider plan is wrong: $(cat "$work/plan")"
cluster upgrade apply -i "verity-system/verity:$v" "$cfg" >"$work/apply" 2>&1 ||
  fail "upgrade apply failed: $(cat "$work/apply")"
test "$(kubectl -n verity-system get providers.clusterctl.cluster.x-k8s.io infrastructure-verity \
  -o jsonpath='{.version}')" = "$v" || fail 'inventory was not upgraded'
kubectl get crd verityclustertemplates.infrastructure.cluster.x-k8s.io >/dev/null 2>&1 ||
  fail 'upgraded components were not applied'

# Apply a generated cluster, then describe it and read its kubeconfig secret.
cluster generate cluster demo -i verity -f dev --kubernetes-version v1.37.0 "$cfg" >"$work/demo.yaml" 2>&1 ||
  fail "generate cluster from the installed release failed: $(cat "$work/demo.yaml")"
kubectl apply -f - <"$work/demo.yaml" >/dev/null || fail 'cannot apply the generated cluster'
kubectl apply -f - >/dev/null <<'EOF' || fail 'cannot create the machine'
apiVersion: cluster.x-k8s.io/v1beta2
kind: Machine
metadata:
  name: demo-worker-a
  namespace: fleet
  labels: {cluster.x-k8s.io/cluster-name: demo}
spec:
  clusterName: demo
  version: v1.37.0
EOF
kubectl -n fleet patch machine demo-worker-a --subresource=status --type=merge -p \
  '{"status":{"conditions":[{"type":"Ready","status":"False","reason":"WaitingForInfrastructure","message":"verity smoke machine is pending","lastTransitionTime":"2026-01-01T00:00:00Z"}]}}' \
  >/dev/null || fail 'cannot patch the machine status'
cluster describe cluster demo --show-conditions all "$cfg" >"$work/tree" 2>&1 || fail "describe failed: $(cat "$work/tree")"
# The tree leaf glyph is U+2514 U+2500, spelled as UTF-8 octal bytes to keep the source ASCII.
leaf=$(printf '\342\224\224\342\224\200')
for pattern in '^Cluster fleet/demo, v1\.37\.0' "${leaf}Machine fleet/demo-worker-a, v1\\.37\\.0" \
  'Ready +False +WaitingForInfrastructure .*verity smoke machine is pending'; do
  grep -E "$pattern" "$work/tree" >/dev/null || fail "describe is missing /$pattern/: $(cat "$work/tree")"
done
expect_cluster_fail describe-missing 'clusters.cluster.x-k8s.io "absent" not found' \
  describe cluster absent "$cfg"
printf 'apiVersion: v1\nkind: Config\nclusters: [{name: demo, cluster: {server: "https://demo.verity.invalid:6443"}}]\n' \
  >"$work/workload.kubeconfig"
kubectl -n fleet create secret generic demo-kubeconfig --from-file=value=/dev/stdin \
  <"$work/workload.kubeconfig" >/dev/null || fail 'cannot create the kubeconfig secret'
cluster get kubeconfig demo "$cfg" >"$work/got" 2>&1 || fail "get kubeconfig failed: $(cat "$work/got")"
grep -F 'server: "https://demo.verity.invalid:6443"' "$work/got" >/dev/null || fail "unexpected kubeconfig: $(cat "$work/got")"
expect_cluster_fail kubeconfig-missing '"absent-kubeconfig" not found in namespace "fleet"' \
  get kubeconfig absent "$cfg"

# delete removes every provider from the inventory.
cluster delete --all "$cfg" >"$work/delete" 2>&1 || fail "delete failed: $(cat "$work/delete")"
grep -F "Deleting Provider={\"name\":\"infrastructure-verity\",\"namespace\":\"verity-system\"} providerVersion=\"$v\"" \
  "$work/delete" >/dev/null || fail "delete output is unexpected: $(cat "$work/delete")"
test -z "$(kubectl get providers.clusterctl.cluster.x-k8s.io -A -o name)" || fail 'inventory is not empty after delete'

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"

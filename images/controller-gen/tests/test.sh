#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
lockfile="$(dirname "$0")/../apko.lock.json"
version=$(jq -r '[.contents.packages[] | select(.name == "controller-gen") | .version][0]' "$lockfile")
version=${version%-r*}

trap 'chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

expect() {
  grep -Fx -- "$1" "$2" >/dev/null || fail "$3"
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/controller-gen"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Offline with a read-only root: only /tmp (Go caches) and the mounted fixture are writable.
run() {
  docker run --rm --network none --read-only --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e GOPATH=/tmp/go -e GOCACHE=/tmp/go-build -e GOFLAGS=-mod=vendor \
    --tmpfs /tmp:rw,mode=1777 -v "$work:/work" "$@"
}

run "$image" --version >"$work/version" 2>&1 || fail 'version failed'
expect "Version: v${version}" "$work/version" 'version does not match the locked package'

run "$image" --help >"$work/help" 2>&1 || fail 'help failed'
grep -F 'crd' "$work/help" >/dev/null || fail 'help does not list the crd generator'

# controller-gen loads packages through `go list`, so the Go toolchain is part of the contract.
run --entrypoint /usr/bin/go "$image" version >"$work/go-version" 2>&1 || fail 'go version failed'
grep -E '^go version go1\.27\.' "$work/go-version" >/dev/null || fail 'unexpected Go toolchain'

# controller-gen only treats a type as a Kubernetes kind when it embeds TypeMeta and
# ObjectMeta from k8s.io/apimachinery/pkg/apis/meta/v1. The smoke test has no network,
# so a minimal local module at that import path stands in for apimachinery and is
# vendored into the API module like a real dependency.
mkdir -p "$work/apimachinery/pkg/apis/meta/v1" "$work/apimachinery/pkg/runtime" \
  "$work/api/v1alpha1"
cat >"$work/apimachinery/go.mod" <<'EOF'
module k8s.io/apimachinery

go 1.27
EOF
cat >"$work/apimachinery/pkg/runtime/object.go" <<'EOF'
// Package runtime is a minimal offline stand-in for k8s.io/apimachinery/pkg/runtime.
package runtime

// Object is implemented by every API root type.
type Object interface {
	DeepCopyObject() Object
}
EOF
cat >"$work/apimachinery/pkg/apis/meta/v1/types.go" <<'EOF'
// Package v1 is a minimal offline stand-in for k8s.io/apimachinery/pkg/apis/meta/v1.
package v1

// TypeMeta describes an individual object in an API response or request.
type TypeMeta struct {
	Kind       string `json:"kind,omitempty"`
	APIVersion string `json:"apiVersion,omitempty"`
}

// ObjectMeta is metadata that all persisted resources must have.
type ObjectMeta struct {
	Name      string            `json:"name,omitempty"`
	Namespace string            `json:"namespace,omitempty"`
	Labels    map[string]string `json:"labels,omitempty"`
}

// ListMeta describes metadata that synthetic resources must have.
type ListMeta struct {
	ResourceVersion string `json:"resourceVersion,omitempty"`
}

// Condition reports one aspect of an object's state.
type Condition struct {
	// Type of the condition.
	// +required
	Type string `json:"type"`
	// Status of the condition.
	// +kubebuilder:validation:Enum=True;False;Unknown
	// +required
	Status string `json:"status"`
	// Reason is a machine-readable explanation.
	// +kubebuilder:validation:MaxLength=64
	// +optional
	Reason string `json:"reason,omitempty"`
}

func (in *ObjectMeta) DeepCopyInto(out *ObjectMeta) {
	*out = *in
	if in.Labels != nil {
		out.Labels = make(map[string]string, len(in.Labels))
		for k, v := range in.Labels {
			out.Labels[k] = v
		}
	}
}

func (in *ListMeta) DeepCopyInto(out *ListMeta) { *out = *in }

func (in *Condition) DeepCopyInto(out *Condition) { *out = *in }
EOF

cat >"$work/api/go.mod" <<'EOF'
module example.invalid/api

go 1.27

require k8s.io/apimachinery v0.0.0

replace k8s.io/apimachinery => ../apimachinery
EOF
cat >"$work/api/v1alpha1/groupversion_info.go" <<'EOF'
// Package v1alpha1 contains the Widget API.
// +kubebuilder:object:generate=true
// +groupName=widgets.example.com
package v1alpha1

// The generated DeepCopyObject methods return runtime.Object; importing the
// package here makes `go mod vendor` include it before generation.
import _ "k8s.io/apimachinery/pkg/runtime"
EOF
cat >"$work/api/v1alpha1/widget_types.go" <<'EOF'
package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

// WidgetSpec is the desired state of a Widget.
type WidgetSpec struct {
	// Replicas is the desired number of widget instances.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=10
	// +kubebuilder:default=1
	// +optional
	Replicas int32 `json:"replicas,omitempty"`

	// Image is the container image reference.
	// +kubebuilder:validation:Pattern=`^[a-z0-9./:-]+$`
	// +required
	Image string `json:"image"`

	// Mode selects the rollout strategy.
	// +kubebuilder:validation:Enum=Fast;Safe
	// +optional
	Mode string `json:"mode,omitempty"`
}

// WidgetStatus is the observed state of a Widget.
type WidgetStatus struct {
	// Conditions are the latest observations.
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// Widget is a fixture custom resource.
// +kubebuilder:object:root=true
// +kubebuilder:resource:scope=Namespaced,shortName=wdg
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Replicas",type=integer,JSONPath=`.spec.replicas`
type Widget struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   WidgetSpec   `json:"spec,omitempty"`
	Status WidgetStatus `json:"status,omitempty"`
}

// WidgetList contains a list of Widget.
// +kubebuilder:object:root=true
type WidgetList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Widget `json:"items"`
}
EOF
chmod -R a+rwX "$work"

# Vendor the dependency without network access, then remove its source so only
# vendor/ can satisfy it during generation and compilation.
run -w /work/api -e GOFLAGS=-mod=mod --entrypoint /usr/bin/go "$image" mod vendor \
  >"$work/vendor.out" 2>&1 || {
  cat "$work/vendor.out" >&2
  fail 'go mod vendor failed'
}
expect '# k8s.io/apimachinery v0.0.0 => ../apimachinery' "$work/api/vendor/modules.txt" \
  'vendor/modules.txt does not record k8s.io/apimachinery'
rm -rf "$work/apimachinery"

run -w /work/api "$image" crd:crdVersions=v1 object paths=./... output:crd:dir=/work/out \
  >"$work/gen.out" 2>&1 || {
  cat "$work/gen.out" >&2
  fail 'controller-gen crd/object generation failed'
}

crd="$work/out/widgets.example.com_widgets.yaml"
test -f "$crd" || fail 'CRD file widgets.example.com_widgets.yaml was not generated'
test "$(find "$work/out" -type f | wc -l)" -eq 1 || fail 'unexpected extra CRD files'

expect 'apiVersion: apiextensions.k8s.io/v1' "$crd" 'CRD apiVersion is not apiextensions.k8s.io/v1'
expect 'kind: CustomResourceDefinition' "$crd" 'CRD kind is not CustomResourceDefinition'
expect '  name: widgets.widgets.example.com' "$crd" 'CRD metadata.name is wrong'
expect "    controller-gen.kubebuilder.io/version: v${version}" "$crd" 'CRD version annotation is wrong'
expect '  group: widgets.example.com' "$crd" 'CRD group is wrong'
expect '    kind: Widget' "$crd" 'CRD kind is wrong'
expect '    listKind: WidgetList' "$crd" 'CRD listKind is wrong'
expect '    plural: widgets' "$crd" 'CRD plural is wrong'
expect '    singular: widget' "$crd" 'CRD singular is wrong'
expect '    - wdg' "$crd" 'CRD short name is missing'
expect '  scope: Namespaced' "$crd" 'CRD scope is wrong'
expect '    name: v1alpha1' "$crd" 'CRD version v1alpha1 is missing'
expect '    served: true' "$crd" 'CRD version is not served'
expect '    storage: true' "$crd" 'CRD version is not the storage version'
expect '      status: {}' "$crd" 'status subresource is missing'
expect '    - jsonPath: .spec.replicas' "$crd" 'printer column path is missing'
expect '      name: Replicas' "$crd" 'printer column name is missing'

# Schema: ObjectMeta known-type override, spec fields with validation, vendored Condition.
test "$(grep -A1 -Fx '          metadata:' "$crd" | sed -n 2p)" = '            type: object' ||
  fail 'metadata is not the ObjectMeta known-type schema'
expect '        description: Widget is a fixture custom resource.' "$crd" 'root description is missing'
expect '            description: WidgetSpec is the desired state of a Widget.' "$crd" \
  'spec description is missing'
expect '              image:' "$crd" 'spec.image is missing'
expect "                pattern: ^[a-z0-9./:-]+\$" "$crd" 'spec.image pattern is missing'
expect '              mode:' "$crd" 'spec.mode is missing'
expect '                - Fast' "$crd" 'spec.mode enum value Fast is missing'
expect '                - Safe' "$crd" 'spec.mode enum value Safe is missing'
expect '              replicas:' "$crd" 'spec.replicas is missing'
expect '                default: 1' "$crd" 'spec.replicas default is missing'
expect '                format: int32' "$crd" 'spec.replicas format is missing'
expect '                maximum: 10' "$crd" 'spec.replicas maximum is missing'
expect '                minimum: 1' "$crd" 'spec.replicas minimum is missing'
expect '            - image' "$crd" 'spec.image is not required'
expect '              conditions:' "$crd" 'status.conditions is missing'
expect '                  description: Condition reports one aspect of an object'"'"'s state.' "$crd" \
  'vendored Condition type is not described'
expect '                    reason:' "$crd" 'vendored Condition.reason is missing'
expect '                      maxLength: 64' "$crd" 'vendored Condition.reason maxLength is missing'
expect '                      - "True"' "$crd" 'vendored Condition.status enum is missing True'
expect '                      - Unknown' "$crd" 'vendored Condition.status enum is missing Unknown'
expect '                  - status' "$crd" 'vendored Condition.status is not required'

# The object generator wrote DeepCopy methods; prove they compile offline against vendor/.
deepcopy="$work/api/v1alpha1/zz_generated.deepcopy.go"
test -f "$deepcopy" || fail 'deepcopy file was not generated'
grep -F 'func (in *Widget) DeepCopyObject() runtime.Object {' "$deepcopy" >/dev/null ||
  fail 'Widget DeepCopyObject is missing'
grep -F 'func (in *WidgetList) DeepCopyInto(out *WidgetList) {' "$deepcopy" >/dev/null ||
  fail 'WidgetList DeepCopyInto is missing'
run -w /work/api --entrypoint /usr/bin/go "$image" vet ./... >"$work/vet.out" 2>&1 || {
  cat "$work/vet.out" >&2
  fail 'generated code does not build offline'
}

# Invalid marker values are rejected with a diagnostic that names the marker.
sed 's/Maximum=10/Maximum=ten/' "$work/api/v1alpha1/widget_types.go" >"$work/bad.go"
cat "$work/bad.go" >"$work/api/v1alpha1/widget_types.go"
rm -rf "$work/out"
if run -w /work/api "$image" crd paths=./... output:crd:dir=/work/out >"$work/bad.out" 2>&1; then
  fail 'invalid marker value unexpectedly accepted'
fi
grep -F 'widget_types.go:9:2: invalid maximum value' "$work/bad.out" >/dev/null ||
  fail 'invalid marker diagnostic does not name the file, line, and marker'
test ! -e "$crd" || fail 'CRD written despite invalid marker'

printf 'SMOKE PASS image=%s\n' "$image"

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
: "${IMAGE_VERSION:?IMAGE_VERSION is required}"
flavor=${2:-plain}
[ "$flavor" = plain ] || { echo "unexpected flavor: $flavor" >&2; exit 1; }

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/tofu"]' ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["version"]' ] ||
  fail 'unexpected default command'
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /workspace ] ||
  fail 'unexpected OCI working directory'

version=$(docker run --rm --network none "$image" version)
printf '%s\n' "$version" | grep -Fq "OpenTofu v${IMAGE_VERSION}" || fail 'unexpected OpenTofu version'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work/valid" "$work/invalid"
chmod 777 "$work/valid" "$work/invalid"

# terraform_data is served by OpenTofu's built-in provider, so this fixture
# proves real init/validate/plan behavior without any network access.
cat > "$work/valid/main.tf" <<'EOF'
terraform {
  required_version = ">= 1.0.0"
}

variable "greeting" {
  type    = string
  default = "hello-from-smoke-test"
}

resource "terraform_data" "example" {
  input = var.greeting
}

output "greeting" {
  value = terraform_data.example.output
}
EOF
chmod 666 "$work/valid/main.tf"

run_tofu() {
  docker run --rm --network none -v "$work/valid:/workspace" "$image" "$@"
}

run_tofu init -no-color -input=false >"$work/init.log" 2>&1 ||
  { cat "$work/init.log" >&2; fail 'offline init failed on a valid configuration'; }
grep -Fq 'OpenTofu has been successfully initialized!' "$work/init.log" ||
  fail 'init did not report success'

run_tofu validate -no-color >"$work/validate.log" 2>&1 ||
  { cat "$work/validate.log" >&2; fail 'validate failed on a valid configuration'; }
grep -Fq 'The configuration is valid.' "$work/validate.log" || fail 'validate did not report success'

run_tofu plan -no-color -input=false -out=plan.tfplan >"$work/plan.log" 2>&1 ||
  { cat "$work/plan.log" >&2; fail 'plan failed on a valid configuration'; }
grep -Fq 'terraform_data.example will be created' "$work/plan.log" ||
  fail 'plan did not describe the expected resource change'
grep -Fq 'Plan: 1 to add, 0 to change, 0 to destroy.' "$work/plan.log" ||
  fail 'plan summary did not match the expected change count'
test -f "$work/valid/plan.tfplan" || fail 'plan did not persist a plan file'

cat > "$work/invalid/main.tf" <<'EOF'
resource "terraform_data" "broken" {
  input =
}
EOF
chmod 666 "$work/invalid/main.tf"

if docker run --rm --network none -v "$work/invalid:/workspace" "$image" \
  init -no-color -input=false >"$work/invalid-init.log" 2>&1; then
  cat "$work/invalid-init.log" >&2
  fail 'init unexpectedly succeeded on a malformed configuration'
fi
grep -Fq 'Error:' "$work/invalid-init.log" || fail 'malformed configuration failure did not report an error'

printf 'SMOKE PASS image=%s\n' "$image"

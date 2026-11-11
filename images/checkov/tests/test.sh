#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
# Run as the host user so the bind mount stays removable.
run_as=$(id -u):$(id -g)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

checkov() {
  # Networking is off: the scan must work offline and must not phone home.
  docker run --rm --network none --user "$run_as" -v "$work:/src" "$image" "$@"
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/checkov"]' || fail 'unexpected entrypoint'

docker run --rm --network none --read-only --tmpfs /tmp "$image" --version | grep -E '^3\.4\.[0-9]+$' >/dev/null ||
  fail 'checkov --version does not report 3.4.x'

# Negative: an unknown flag must exit non-zero.
if docker run --rm --network none --read-only --tmpfs /tmp "$image" --no-such-flag >/dev/null 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi

mkdir -p "$work/bad" "$work/good"
cat >"$work/bad/main.tf" <<'TF'
resource "aws_security_group" "open" {
  name = "open"
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
TF
cat >"$work/good/main.tf" <<'TF'
resource "aws_security_group" "closed" {
  name        = "closed"
  description = "Managed by Terraform"
  ingress {
    description = "ssh from the internal range"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }
}
TF

# The open security group must fail CKV_AWS_24 (SSH open to the world) and exit 1.
set +e
checkov -d /src/bad --framework terraform --check CKV_AWS_24 --compact --quiet >"$work/bad.out" 2>&1
status=$?
set -e
test "$status" = 1 || { cat "$work/bad.out" >&2; fail "open security group exited $status, expected 1"; }
grep -F 'CKV_AWS_24' "$work/bad.out" >/dev/null || { cat "$work/bad.out" >&2; fail 'CKV_AWS_24 failure is not reported'; }

# The compliant file passes the same check and exits 0.
checkov -d /src/good --framework terraform --check CKV_AWS_24 --compact >"$work/good.out" 2>&1 ||
  { cat "$work/good.out" >&2; fail 'compliant security group did not pass'; }
grep -E 'Passed checks: [1-9]' "$work/good.out" >/dev/null || { cat "$work/good.out" >&2; fail 'compliant file reports no passed checks'; }

# Machine-readable output carries the failed check.
set +e
checkov -d /src/bad --framework terraform --check CKV_AWS_24 -o json >"$work/bad.json" 2>/dev/null
set -e
grep -F '"check_id": "CKV_AWS_24"' "$work/bad.json" >/dev/null || fail 'JSON output is missing the failed check'

printf 'SMOKE PASS image=%s\n' "$image"

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([0-9][0-9.]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'kubescape package version not found\n' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/artifacts" "$work/out"
cat >"$work/privileged.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: verity-privileged
spec:
  containers:
    - name: app
      image: example.invalid/app:1
      securityContext:
        privileged: true
YAML
cat >"$work/restricted.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: verity-restricted
spec:
  containers:
    - name: app
      image: example.invalid/app:1
      securityContext:
        privileged: false
        allowPrivilegeEscalation: false
YAML
chmod -R a+rwX "$work"

user=$(docker image inspect --format '{{.Config.User}}' "$image")
case "$user" in
  "" | 0 | 0:* | root | root:*)
    printf 'image runs as root: %s\n' "$user" >&2
    exit 1
    ;;
esac
entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")
[ "$entrypoint" = '["/usr/bin/kubescape"]' ] || {
  printf 'unexpected entrypoint: %s\n' "$entrypoint" >&2
  exit 1
}

version=$(docker run --rm --network none "$image" version 2>&1)
printf '%s\n' "$version" | grep -Fxq "Your current version is: ${expected_version}" || {
  printf 'unexpected kubescape version output: %s\n' "$version" >&2
  exit 1
}

if docker run --rm --network none "$image" --verity-no-such-flag >/dev/null 2>&1; then
  printf 'unknown flag unexpectedly succeeded\n' >&2
  exit 1
fi

# Fetch the policy artifacts once, then scan with networking disabled so the
# scan proves it runs entirely from the local artifact directory.
docker run --rm -v "$work:/work" "$image" download artifacts --output /work/artifacts >/dev/null
[ -s "$work/artifacts/nsa.json" ] || { printf 'nsa framework artifact missing\n' >&2; exit 1; }

# kubescape writes results with mode 0600, so the scans run as the invoking
# (non-root) host user to keep the reports readable here.
scan() {
  docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/work \
    -v "$work:/work" "$image" \
    scan framework nsa "/work/$1.yaml" --use-artifacts-from /work/artifacts \
    --keep-local --format json --output "/work/out/$1.json" >/dev/null
}
control_status() {
  sed -n 's/.*"C-0057":{[^}]*"status":"\([a-z]*\)".*/\1/p' "$work/out/$1.json" | head -n 1
}

scan privileged
scan restricted
privileged=$(control_status privileged)
restricted=$(control_status restricted)
[ "$privileged" = failed ] || {
  printf 'privileged pod: C-0057 status %s, want failed\n' "$privileged" >&2
  exit 1
}
[ "$restricted" = passed ] || {
  printf 'restricted pod: C-0057 status %s, want passed\n' "$restricted" >&2
  exit 1
}

printf 'SMOKE PASS version=%s user=%s\n' "$expected_version" "$user"

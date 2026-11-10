#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/ko-app/entrypoint"]' || fail 'unexpected entrypoint'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

run() {
  docker run --rm --network none --read-only --cpus 2 --memory 512m --pids-limit 256 \
    --tmpfs /tmp:uid=65532,gid=65532,mode=1777 "$@"
}

run "$image" --help >"$work/help" 2>&1
grep -F 'Usage of /ko-app/entrypoint:' "$work/help" >/dev/null ||
  fail 'entrypoint help is missing usage text'
for flag in -entrypoint -post_file -termination_path -wait_file; do
  grep -F -- "$flag" "$work/help" >/dev/null ||
    fail "entrypoint help is missing $flag"
done

if run "$image" --definitely-invalid >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

# The cp subcommand places the binary into the shared tools directory, which
# is how Tekton injects it into step containers that have no cp of their own.
run "$image" cp /ko-app/entrypoint /tmp/entrypoint >"$work/cp" 2>&1 ||
  fail 'cp subcommand failed'
grep -F 'Copied /ko-app/entrypoint to /tmp/entrypoint' "$work/cp" >/dev/null ||
  fail 'cp subcommand did not report the copy'

if run "$image" cp /definitely-missing /tmp/entrypoint >"$work/cp-missing" 2>&1; then
  fail 'cp of a missing source unexpectedly succeeded'
fi
grep -F 'cp error:' "$work/cp-missing" >/dev/null ||
  fail 'cp error diagnostic is missing'

if run "$image" decode-script /definitely-missing >"$work/decode" 2>&1; then
  fail 'decode-script of a missing file unexpectedly succeeded'
fi
grep -F 'decode-script error:' "$work/decode" >/dev/null ||
  fail 'decode-script error diagnostic is missing'

printf 'SMOKE PASS image=%s\n' "$image"

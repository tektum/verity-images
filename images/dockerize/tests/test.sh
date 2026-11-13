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
  '["/usr/bin/dockerize"]' || fail 'unexpected entrypoint'

docker run --rm --network none --read-only "$image" -help 2>&1 |
  grep -F 'Utility to simplify running applications in docker containers' >/dev/null ||
  fail 'dockerize help output is missing'

# Negative: an unknown flag must exit non-zero and name the flag.
if docker run --rm --network none --read-only "$image" -no-such-flag >"$work/flag.log" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -no-such-flag' "$work/flag.log" >/dev/null ||
  fail 'unknown flag error was not reported'

# The bind mount is writable by the image user so rendered output lands on the host.
chmod 0777 "$work"
cat >"$work/app.tmpl" <<'EOF'
listen={{ .Env.APP_LISTEN }}
mode={{ default .Env.APP_MODE "fallback" }}
{{ range $i, $v := split .Env.APP_PEERS "," }}peer{{ $i }}={{ $v }}
{{ end }}
EOF
chmod 0644 "$work/app.tmpl"

docker run --rm --network none --read-only -v "$work:/work" \
  -e APP_LISTEN=0.0.0.0:8080 -e APP_PEERS=a.example,b.example \
  "$image" -template /work/app.tmpl:/work/app.conf ||
  fail 'template rendering failed'
grep -Fx 'listen=0.0.0.0:8080' "$work/app.conf" >/dev/null || fail 'environment value was not rendered'
grep -Fx 'mode=fallback' "$work/app.conf" >/dev/null || fail 'default function was not applied'
grep -Fx 'peer1=b.example' "$work/app.conf" >/dev/null || fail 'split and range were not rendered'

# -no-overwrite must keep an existing destination untouched.
printf 'keep\n' >"$work/keep.conf"
chmod 0666 "$work/keep.conf"
docker run --rm --network none --read-only -v "$work:/work" -e APP_LISTEN=x -e APP_PEERS=y \
  "$image" -no-overwrite -template /work/app.tmpl:/work/keep.conf ||
  fail 'no-overwrite rendering failed'
test "$(cat "$work/keep.conf")" = keep || fail 'no-overwrite replaced an existing file'

# Wait for a file dependency, then exec the command and propagate its exit status.
: >"$work/ready"
docker run --rm --network none --read-only -v "$work:/work" "$image" \
  -wait file:///work/ready -timeout 5s /usr/bin/dockerize -version ||
  fail 'wait on an existing file or command exec failed'

# Negative: an unreachable TCP dependency must time out with a non-zero status.
if docker run --rm --network none --read-only "$image" \
  -wait tcp://127.0.0.1:9 -timeout 2s -wait-retry-interval 500ms >"$work/wait.log" 2>&1; then
  fail 'wait on an unreachable dependency unexpectedly succeeded'
fi
grep -F 'Timeout after 2s waiting on dependencies' "$work/wait.log" >/dev/null ||
  fail 'wait timeout was not reported'

# Negative: a missing template source must fail.
if docker run --rm --network none --read-only "$image" \
  -template /work/missing.tmpl:/tmp/out >/dev/null 2>&1; then
  fail 'missing template unexpectedly succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"

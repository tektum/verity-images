#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
: "${IMAGE_VERSION:?IMAGE_VERSION is required}"
work=$(mktemp -d)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

user=$(docker image inspect --format '{{.Config.User}}' "$image")
[ -z "$user" ] || [ "$user" = 0 ] || fail 'image must run as root for executor compatibility'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/dumb-init","--","/usr/bin/gitlab-runner-entrypoint"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["run"]' ] \
  || fail 'unexpected image command'

docker run --rm --cpus 4 --network none --entrypoint /bin/sh "$image" -c \
  'test -x /usr/bin/gitlab-runner && test -x /usr/bin/gitlab-runner-entrypoint \
   && test -x /usr/bin/git && test -x /bin/bash \
   && test -d /etc/gitlab-runner \
   && test -f /usr/share/licenses/gitlab-runner/LICENSE' \
  || fail 'required runner files are missing'

docker run --rm --cpus 4 --network none "$image" --version 2>&1 \
  | grep -F "Version:      ${IMAGE_VERSION}" >/dev/null \
  || fail 'runner version check failed'
docker run --rm --cpus 4 --network none "$image" --help 2>&1 \
  | grep -F 'run' >/dev/null \
  || fail 'runner help check failed'

if docker run --rm --cpus 4 --network none "$image" >/dev/null 2>&1; then
  fail 'runner unexpectedly started without registration config'
fi

output=$(docker run --rm --cpus 4 --network none "$image" run -c /tmp/missing.toml 2>&1) \
  && fail 'runner unexpectedly started with a missing explicit config'
printf '%s\n' "$output" | grep -F '/tmp/missing.toml' >/dev/null \
  || fail 'runner ignored the -c config path'

cat >"$work/config.toml" <<'EOF'
concurrent = 1
check_interval = 0

[[runners]]
  name = "synthetic"
  url = "https://gitlab.invalid/"
  token = "glrt-synthetic"
  executor = "shell"
EOF
chmod 644 "$work/config.toml"

docker run --rm --cpus 4 --network none \
  -v "$work/config.toml:/tmp/config.toml:ro" \
  "$image" list --config /tmp/config.toml 2>&1 \
  | grep -F 'synthetic' >/dev/null \
  || fail 'valid synthetic registration config was rejected'

printf '%s\n' '[[runners]' >"$work/invalid.toml"
chmod 644 "$work/invalid.toml"
if docker run --rm --cpus 4 --network none \
  -v "$work/invalid.toml:/etc/gitlab-runner/config.toml:ro" \
  "$image" >/dev/null 2>&1; then
  fail 'invalid registration config unexpectedly succeeded'
fi

docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" \
  | grep -E '(^|_)(TOKEN|PASSWORD|SECRET)=' >/dev/null \
  && fail 'image config contains a registration secret'

printf 'SMOKE PASS image=%s\n' "$image"

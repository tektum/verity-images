#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/bash"]' ] \
  || fail 'unexpected image entrypoint'
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in
  null|'[]') ;;
  *) fail 'unexpected image command' ;;
esac
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected image user'

docker run --rm --network none "$image" --version | grep -Fq 'GNU bash, version 5.3' \
  || fail 'unexpected bash version'

# Bash-only features: associative arrays, [[ ]], process substitution, pipefail.
out=$(docker run --rm --network none "$image" -c '
  declare -A m=([b]=2 [a]=1)
  [[ ${m[a]}${m[b]} == 12 ]] || exit 10
  mapfile -t lines < <(printf "x\ny\n")
  echo "${#lines[@]}:${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}:$(id -u 2>/dev/null || echo "$UID")"
') || fail 'bash feature script failed'
[ "$out" = '2:5.3:65532' ] || fail "unexpected feature script output: $out"

# shellcheck disable=SC2016
out=$(printf 'echo "$((6 * 7))"\n' | docker run --rm -i --network none "$image") || fail 'script from stdin failed'
[ "$out" = 42 ] || fail 'script from stdin returned unexpected output'

status=0
docker run --rm --network none "$image" -c 'exit 7' || status=$?
[ "$status" -eq 7 ] || fail 'exit status was not propagated'

status=0
docker run --rm --network none "$image" -c 'set -o pipefail; false | true' || status=$?
[ "$status" -eq 1 ] || fail 'pipefail was not honored'

status=0
output=$(docker run --rm --network none "$image" -c 'if then fi' 2>&1) || status=$?
[ "$status" -eq 2 ] || fail 'syntax error did not exit with status 2'
printf '%s\n' "$output" | grep -Fq 'syntax error' || fail 'syntax error diagnostic not found'

printf 'SMOKE PASS image=%s\n' "$image"

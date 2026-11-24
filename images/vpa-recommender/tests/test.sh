#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
component=recommender
banner='Vertical Pod Autoscaler Recommender'
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")
container="vpa-$component-smoke-$$"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'cannot read package.version from melange.yaml'
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = "[\"/$component\"]" ] \
  || fail "entrypoint is not upstream /$component"

help=$(docker run --rm --network none "$image" --help 2>&1) || fail "/$component --help failed"
for flag in --kubeconfig --leader-elect --address --recommender-name --storage \
  --pod-recommendation-min-cpu-millicores --memory-saver; do
  case "$help" in
    *"      $flag "*) ;;
    *)
      printf '%s\n' "$help" >&2
      fail "--help does not list $flag"
      ;;
  esac
done
docker run --rm --network none --entrypoint "/usr/bin/$component" "$image" --help >/dev/null 2>&1 \
  || fail "/usr/bin/$component is not executable"

if bad_flag=$(docker run --rm --network none "$image" --no-such-flag 2>&1); then
  fail 'unknown flag unexpectedly succeeded'
fi
case "$bad_flag" in
  *'unknown flag: --no-such-flag'*) ;;
  *)
    printf '%s\n' "$bad_flag" >&2
    fail 'unknown flag diagnostic missing'
    ;;
esac

if missing=$(docker run --rm --network none "$image" \
  --kubeconfig=/nonexistent/kubeconfig --leader-elect=false 2>&1); then
  fail 'missing kubeconfig unexpectedly succeeded'
fi
case "$missing" in
  *'Failed to build kubeconfig from file'*'/nonexistent/kubeconfig'*) ;;
  *)
    printf '%s\n' "$missing" >&2
    fail 'missing kubeconfig diagnostic missing'
    ;;
esac

work=$(mktemp -d)
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM
chmod 755 "$work"
cat > "$work/kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
  - name: smoke
    cluster:
      server: https://127.0.0.1:1
      insecure-skip-tls-verify: true
contexts:
  - name: smoke
    context:
      cluster: smoke
      user: smoke
current-context: smoke
users:
  - name: smoke
    user:
      token: smoke
EOF
chmod 644 "$work/kubeconfig"

# The API server is unreachable: the component must report the refused
# connection and must not exit successfully.
docker run -d --name "$container" --network none \
  -v "$work/kubeconfig:/tmp/kubeconfig:ro" \
  "$image" --kubeconfig=/tmp/kubeconfig --leader-elect=false >/dev/null \
  || fail 'unreachable kubeconfig container failed to start'
refused=
i=0
while [ "$i" -lt 60 ]; do
  logs=$(docker logs "$container" 2>&1 || true)
  case "$logs" in
    *'dial tcp 127.0.0.1:1: connect: connection refused'*)
      refused=1
      break
      ;;
  esac
  [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] || break
  i=$((i + 1))
  sleep 1
done
logs=$(docker logs "$container" 2>&1 || true)
state=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$container")
if [ -z "$refused" ]; then
  printf '%s\n%s\n' "$state" "$logs" >&2
  fail 'unreachable API server was not reported'
fi
[ "$state" != 'exited 0' ] || fail 'unreachable API server run exited successfully'
case "$logs" in
  *"\"$banner\" version=\"$version\""*) ;;
  *)
    printf '%s\n' "$logs" >&2
    fail "startup banner does not report version $version"
    ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"

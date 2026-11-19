#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
name="mdbook-serve-$$"

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$work/book" "$work/empty"
chmod 777 "$work/book" "$work/empty"

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] \
  || fail 'image does not run as 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/mdbook"]' ] \
  || fail 'unexpected entrypoint'

docker run --rm --network none "$image" --version | grep -Eq '^mdbook v0\.5\.' \
  || fail 'unexpected version'

docker run --rm --network none -v "$work/book:/book" "$image" \
  init --force --title 'Verity Smoke' --ignore none /book >/dev/null
[ -f "$work/book/book.toml" ] || fail 'init did not write book.toml'
[ -f "$work/book/src/SUMMARY.md" ] || fail 'init did not write SUMMARY.md'

cat >"$work/book/src/chapter_1.md" <<'MD'
# Verity Chapter

Marker text verity-mdbook-smoke.
MD

docker run --rm --network none -v "$work/book:/book" "$image" build /book >/dev/null
[ -f "$work/book/book/index.html" ] || fail 'build did not write index.html'
grep -F 'verity-mdbook-smoke' "$work/book/book/chapter_1.html" >/dev/null \
  || fail 'chapter content missing from HTML'
grep -F '<title>' "$work/book/book/chapter_1.html" | grep -F 'Verity Smoke' >/dev/null \
  || fail 'book title missing from HTML'
set -- "$work"/book/book/searchindex*.js
[ -f "$1" ] || fail 'search index missing'

# Optional readiness check for the built-in server.
docker run -d --name "$name" -v "$work/book:/book" "$image" \
  serve -n 0.0.0.0 -p 3000 /book >/dev/null
ready=0
for _ in $(seq 1 30); do
  if docker logs "$name" 2>&1 | grep -F 'Serving on' >/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" = 1 ] || fail "serve did not become ready: $(docker logs "$name" 2>&1)"
docker rm -f "$name" >/dev/null

# A directory without book.toml has no src and must fail to build.
if out=$(docker run --rm --network none -v "$work/empty:/book" "$image" build /book 2>&1); then
  fail 'build succeeded without a book'
fi
printf '%s\n' "$out" | grep -F 'SUMMARY.md' >/dev/null \
  || fail "unexpected failure output: $out"
[ ! -e "$work/empty/book" ] || fail 'failed build wrote output'

printf '%s\n' verity

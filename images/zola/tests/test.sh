#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - zola=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
id=$$
builder="verity-zola-build-$id"
broken="verity-zola-broken-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$builder" "$broken" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned zola version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/zola"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "zola $version" "$work/version" >/dev/null ||
  fail "version does not report zola $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F "unexpected argument '--definitely-invalid'" "$work/invalid" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/invalid")"

# Fixture site: config, one section with Markdown, one template that renders
# section content, the config title and a Tera filter.
mkdir -p "$work/site/content" "$work/site/templates"
cat >"$work/site/config.toml" <<'TOML'
base_url = "https://example.test"
title = "Verity smoke site"
TOML
cat >"$work/site/content/_index.md" <<'MD'
+++
title = "Home"
+++
Hello from **zola**.
MD
cat >"$work/site/templates/index.html" <<'HTML'
<!doctype html>
<title>{{ section.title | upper }}</title>
<main>{{ section.content | safe }}</main>
<footer>{{ config.title }}</footer>
HTML

# Copy the fixture into the container instead of bind-mounting it, so the
# build runs as the image user on its own /work and the host never has to
# delete files owned by uid 65532.
docker create --name "$builder" --network none "$image" build >/dev/null
docker cp "$work/site/." "$builder:/work/"
docker start -a "$builder" >"$work/build.log" 2>&1 || fail "build failed: $(cat "$work/build.log")"
test "$(docker inspect --format '{{.State.ExitCode}}' "$builder")" -eq 0 ||
  fail "build exit code: $(cat "$work/build.log")"
grep -F 'Done in' "$work/build.log" >/dev/null || fail "build log incomplete: $(cat "$work/build.log")"
mkdir -p "$work/out"
docker cp "$builder:/work/public/." "$work/out/"

for f in index.html 404.html robots.txt sitemap.xml; do
  test -s "$work/out/$f" || fail "public/$f was not generated"
done
grep -F '<title>HOME</title>' "$work/out/index.html" >/dev/null ||
  fail "template filter output missing: $(cat "$work/out/index.html")"
grep -F '<p>Hello from <strong>zola</strong>.</p>' "$work/out/index.html" >/dev/null ||
  fail "Markdown was not rendered: $(cat "$work/out/index.html")"
grep -F '<footer>Verity smoke site</footer>' "$work/out/index.html" >/dev/null ||
  fail "config value missing: $(cat "$work/out/index.html")"
grep -F '<loc>https://example.test/</loc>' "$work/out/sitemap.xml" >/dev/null ||
  fail "sitemap does not use base_url: $(cat "$work/out/sitemap.xml")"

# Negative: a template that references an undefined variable must fail the build.
printf '{{ definitely_undefined_variable }}\n' >"$work/site/templates/index.html"
docker create --name "$broken" --network none "$image" build >/dev/null
docker cp "$work/site/." "$broken:/work/"
rc=0
docker start -a "$broken" >"$work/broken.log" 2>&1 || rc=$?
test "$(docker inspect --format '{{.State.ExitCode}}' "$broken")" -ne 0 ||
  fail 'build with a broken template unexpectedly succeeded'
grep -F 'definitely_undefined_variable' "$work/broken.log" >/dev/null ||
  fail "broken template diagnostic is missing: $(cat "$work/broken.log")"

printf 'SMOKE PASS image=%s\n' "$image"

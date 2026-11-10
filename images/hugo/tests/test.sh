#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
name="hugo-smoke-$$"
# Run as the host user so files created in the bind mount stay removable.
run_as=$(id -u):$(id -g)

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$name" >&2 2>&1 || true
  exit 1
}

hugo_run() {
  docker run --rm --network none --user "$run_as" -v "$work:/src" "$image" "$@"
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/hugo"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /src ||
  fail 'unexpected working directory'

version=$(docker run --rm --network none --read-only "$image" version) ||
  fail 'hugo version failed'
printf '%s\n' "$version" | grep -F '+extended' >/dev/null || fail 'hugo is not the extended edition'

# Negative: an unknown flag must exit non-zero.
if docker run --rm --network none --read-only "$image" --no-such-flag >/dev/null 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi

# Create a site, add a page, and a Sass asset that only the extended edition can compile.
hugo_run new site . --force >/dev/null || fail 'hugo new site failed'
hugo_run new content content/posts/hello.md >/dev/null || fail 'hugo new content failed'
printf '%s\n' 'Smoke body text.' >>"$work/content/posts/hello.md"
sed -i 's/^draft = true/draft = false/;s/^draft: true/draft: false/' "$work/content/posts/hello.md"
mkdir -p "$work/layouts" "$work/assets"
cat >"$work/assets/main.scss" <<'SCSS'
$c: #123456;
body { color: $c; }
SCSS
cat >"$work/layouts/home.html" <<'HTML'
{{ $css := resources.Get "main.scss" | css.Sass }}
<html><head><link rel="stylesheet" href="{{ $css.RelPermalink }}"></head>
<body><h1>smoke-home</h1>{{ range .Site.RegularPages }}<a href="{{ .RelPermalink }}">{{ .Title }}</a>{{ end }}</body></html>
HTML
cat >"$work/layouts/page.html" <<'HTML'
<html><body><article>{{ .Content }}</article></body></html>
HTML

hugo_run >"$work/build.log" 2>&1 || { cat "$work/build.log" >&2; fail 'hugo build failed'; }
grep -F 'smoke-home' "$work/public/index.html" >/dev/null || fail 'public/index.html is missing the home content'
grep -F 'Hello' "$work/public/index.html" >/dev/null || fail 'home page does not list the new post'
grep -F 'Smoke body text.' "$work/public/posts/hello/index.html" >/dev/null || fail 'post page was not rendered'
css=$(find "$work/public" -name '*.css' | head -n 1)
test -n "$css" || fail 'Sass was not compiled to CSS'
grep -F '#123456' "$css" >/dev/null || fail 'compiled CSS lost the Sass variable value'

# Serve the site and fetch it over HTTP.
docker run -d --name "$name" --label verity.smoke=hugo --user "$run_as" \
  -v "$work:/src" -p 127.0.0.1::1313 "$image" \
  server --bind 0.0.0.0 --port 1313 --disableLiveReload >/dev/null
port=$(docker port "$name" 1313/tcp | awk -F: 'NR == 1 { print $2 }')
i=0
until response=$(curl --fail --silent "http://127.0.0.1:$port/"); do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'hugo server did not become ready'
  sleep 1
done
printf '%s' "$response" | grep -F 'smoke-home' >/dev/null || fail 'served page is missing the home content'

printf 'SMOKE PASS image=%s\n' "$image"

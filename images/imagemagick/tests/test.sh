#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  upstream-version: \([0-9][0-9.-]*\) .*$/\1/p' "$recipe")
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read vars.upstream-version from melange.yaml'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/magick"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -E "^Version: ImageMagick $version Q16-HDRI " "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"
# The Wolfi imagemagick-7 delegates, minus X11 (headless CLI).
grep -Fx 'Delegates (built-in): bzlib fontconfig freetype heic jng jp2 jpeg lcms lzma pangocairo png tiff webp xml zlib zstd' \
  "$work/version" >/dev/null || fail "unexpected delegates: $(cat "$work/version")"

rc=0
docker run --rm --network none --read-only "$image" -size 2x2 xc:red -definitely-invalid out.png \
  >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid option unexpectedly succeeded'
grep -F "unrecognized option \`-definitely-invalid'" "$work/flag" >/dev/null ||
  fail "invalid option diagnostic is missing: $(cat "$work/flag")"

mkdir -p "$work/data" "$work/policy"
printf 'this is not a PNG file\n' >"$work/data/broken.png"
cat >"$work/data/box.mvg" <<'MVG'
viewbox 0 0 20 10
fill red
rectangle 0 0 19 9
MVG
# Files without an extension, so only the explicit coder or the @ syntax applies.
printf 'gradient.png\n' >"$work/data/list"
printf 'secret\n' >"$work/data/note"
printf '<?xml version="1.0"?>\n<image><read filename="gradient.png"/></image>\n' >"$work/data/script"
printf '%%PDF-1.4\n' >"$work/data/doc.pdf"
printf '%%!PS-Adobe-3.0\n' >"$work/data/doc.ps"
printf '%%!PS-Adobe-3.0 EPSF-3.0\n' >"$work/data/doc.eps"
printf 'not an XPS document\n' >"$work/data/doc.xps"
# An operator policy that replaces the shipped one: MVG and @file are allowed again.
cat >"$work/policy/policy.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<policymap>
  <policy domain="coder" rights="none" pattern="{MSL,TEXT,HTTP,HTTPS,URL,FTP}"/>
  <policy domain="resource" name="width" value="16KP"/>
</policymap>
XML
chmod -R a+rwX "$work"

run() {
  docker run --rm --network none --read-only -v "$work/data:/work" "$image" "$@"
}

run_operator() {
  docker run --rm --network none --read-only -e MAGICK_CONFIGURE_PATH=/policy \
    -v "$work/policy:/policy:ro" -v "$work/data:/work" "$image" "$@"
}

# expect_denied DIAGNOSTIC RUNNER ARGS...: the command fails and reports DIAGNOSTIC.
expect_denied() {
  diagnostic=$1
  shift
  rc=0
  "$@" >"$work/denied" 2>&1 || rc=$?
  test "$rc" -ne 0 || fail "unexpectedly succeeded: $*"
  grep -F "$diagnostic" "$work/denied" >/dev/null ||
    fail "expected '$diagnostic' from '$*': $(cat "$work/denied")"
}

# Generate an image, resize it, and convert between encoders under the default policy.
run -size 64x48 gradient:red-blue -resize 50% gradient.png >"$work/gen" 2>&1 ||
  fail "generating a PNG failed: $(cat "$work/gen")"
run identify -format '%m %wx%h\n' gradient.png >"$work/identify" 2>&1 ||
  fail "identify failed: $(cat "$work/identify")"
test "$(cat "$work/identify")" = 'PNG 32x24' || fail "unexpected PNG identity: $(cat "$work/identify")"
for format in jpg webp tiff jp2 heic; do
  run gradient.png -quality 85 "gradient.$format" >"$work/convert" 2>&1 ||
    fail "converting to $format failed: $(cat "$work/convert")"
done
run identify -format '%m %wx%h\n' gradient.jpg gradient.webp gradient.tiff gradient.jp2 \
  >"$work/formats" 2>&1 || fail "identify of converted images failed: $(cat "$work/formats")"
printf 'JPEG 32x24\nWEBP 32x24\nTIFF 32x24\nJP2 32x24\n' >"$work/formats.want"
cmp -s "$work/formats" "$work/formats.want" || fail "unexpected converted images: $(cat "$work/formats")"
# The gradient starts red at the top and ends blue at the bottom.
run gradient.png -format '%[fx:p{0,0}.r>0.9 && p{0,0}.b<0.1 && p{0,23}.b>0.9 && p{0,23}.r<0.1]' \
  info: >"$work/pixel" 2>&1 || fail "pixel query failed: $(cat "$work/pixel")"
test "$(cat "$work/pixel")" = 1 || fail "unexpected gradient pixels: $(cat "$work/pixel")"

rc=0
run identify broken.png >"$work/broken" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'malformed input unexpectedly succeeded'
grep -F 'improper image header' "$work/broken" >/dev/null ||
  fail "malformed input diagnostic is missing: $(cat "$work/broken")"

# The shipped policy is the restrictive default, and only it is loaded.
run -list policy >"$work/policy.list" 2>&1 || fail 'listing policies failed'
grep -Fx 'Path: /etc/ImageMagick-7/secure/policy.xml' "$work/policy.list" >/dev/null ||
  fail "default policy was not loaded: $(cat "$work/policy.list")"
denied='not authorized by the security policy'
expect_denied "$denied \`MVG'" run mvg:box.mvg mvg.png
# A denied MSL module is never registered, so msl: has no decoder.
expect_denied "no decode delegate for this image format \`msl:script'" run msl:script msl.png
expect_denied "$denied \`TXT'" run text:note text.png
expect_denied "$denied \`PDF'" run gradient.png pdf.pdf
expect_denied "$denied \`PS'" run gradient.png ps.ps
expect_denied "$denied \`PS'" run gradient.png eps.eps
expect_denied "$denied \`PDF'" run doc.pdf pdf.png
expect_denied "$denied \`PS'" run doc.ps ps.png
expect_denied "$denied \`PS'" run eps:doc.eps eps.png
expect_denied "$denied \`XPS'" run doc.xps xps.png
expect_denied "$denied \`/etc/passwd'" run png:/etc/passwd passwd.png
# A denied @file is left as a literal file name instead of being expanded.
expect_denied "no decode delegate for this image format \`@list'" run @list at.png
test ! -e "$work/data/at.png" || fail 'the default policy expanded @list'
# With the URL coders denied a URL is never fetched through the curl delegate;
# ImageMagick falls back to opening the remainder as a local path.
rc=0
run https://example.com/a.png https.png >"$work/https" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'HTTPS read unexpectedly succeeded under the default policy'
grep -F "unable to open image '//example.com/a.png'" "$work/https" >/dev/null ||
  fail "HTTPS was not denied by the default policy: $(cat "$work/https")"
# ImageMagick 7 has no EPHEMERAL coder (the policy still denies the name): the
# ephemeral: prefix must never delete its input.
run ephemeral:gradient.png ephemeral.png >"$work/ephemeral" 2>&1 || true
test -f "$work/data/gradient.png" || fail 'ephemeral: deleted its input file'
rc=0
run -size 9000x10 xc:white wide.png >"$work/wide" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'the default policy did not enforce the 8KP width limit'
grep -F 'width or height exceeds limit' "$work/wide" >/dev/null ||
  fail "width limit diagnostic is missing: $(cat "$work/wide")"

# A mounted operator policy replaces the default through MAGICK_CONFIGURE_PATH.
run_operator -list policy >"$work/operator.list" 2>&1 || fail 'listing operator policies failed'
grep -Fx 'Path: /policy/policy.xml' "$work/operator.list" >/dev/null ||
  fail "operator policy was not loaded: $(cat "$work/operator.list")"
if grep -F '/etc/ImageMagick-7/secure/' "$work/operator.list" >/dev/null; then
  fail "default policy is still loaded under the operator policy: $(cat "$work/operator.list")"
fi
run_operator mvg:box.mvg box.png >"$work/mvg" 2>&1 ||
  fail "rendering MVG under the operator policy failed: $(cat "$work/mvg")"
run identify -format '%m %wx%h\n' box.png >"$work/box" 2>&1 || fail 'identify of box.png failed'
test "$(cat "$work/box")" = 'PNG 20x10' || fail "unexpected MVG render: $(cat "$work/box")"
run_operator @list at.png >"$work/at" 2>&1 ||
  fail "@file under the operator policy failed: $(cat "$work/at")"
run identify -format '%m %wx%h\n' at.png >"$work/at.id" 2>&1 || fail 'identify of at.png failed'
test "$(cat "$work/at.id")" = 'PNG 32x24' || fail "unexpected @file result: $(cat "$work/at.id")"
run_operator -size 9000x10 xc:white wide.png >"$work/wide" 2>&1 ||
  fail "the operator width limit was not applied: $(cat "$work/wide")"
expect_denied "$denied \`TEXT'" run_operator text:note text.png

printf 'SMOKE PASS\n'

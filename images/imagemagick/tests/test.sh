#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
# Wolfi encodes ImageMagick 7.1.2-35 as 7.1.2.35.
package_version=$(sed -n 's/^    - imagemagick-7=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
version=$(printf '%s' "$package_version" | sed 's/^\([0-9]*\.[0-9]*\.[0-9]*\)\.\([0-9]*\)$/\1-\2/')
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$package_version" ] || fail 'could not read the pinned imagemagick-7 version'
test "$version" != "$package_version" || fail "unexpected package version format: $package_version"

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
for delegate in jpeg png tiff webp heic; do
  grep -E "^Delegates \(built-in\):.* $delegate( |$)" "$work/version" >/dev/null ||
    fail "delegate $delegate is missing: $(cat "$work/version")"
done

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
# A restrictive policy layered on top of the shipped one, as an operator would mount it.
cat >"$work/policy/policy.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<policymap>
  <policy domain="coder" rights="none" pattern="{MSL,MVG,TEXT,HTTP,HTTPS,URL,FTP}"/>
  <policy domain="path" rights="none" pattern="@*"/>
  <policy domain="resource" name="width" value="8KP"/>
</policymap>
XML
chmod -R a+rwX "$work"

run() {
  docker run --rm --network none --read-only -v "$work/data:/work" "$image" "$@"
}

run_hardened() {
  docker run --rm --network none --read-only -e MAGICK_CONFIGURE_PATH=/policy \
    -v "$work/policy:/policy:ro" -v "$work/data:/work" "$image" "$@"
}

# Generate an image, resize it, and convert between encoders.
run -size 64x48 gradient:red-blue -resize 50% gradient.png >"$work/gen" 2>&1 ||
  fail "generating a PNG failed: $(cat "$work/gen")"
run identify -format '%m %wx%h\n' gradient.png >"$work/identify" 2>&1 ||
  fail "identify failed: $(cat "$work/identify")"
test "$(cat "$work/identify")" = 'PNG 32x24' || fail "unexpected PNG identity: $(cat "$work/identify")"
for format in jpg webp tiff; do
  run gradient.png -quality 85 "gradient.$format" >"$work/convert" 2>&1 ||
    fail "converting to $format failed: $(cat "$work/convert")"
done
run identify -format '%m %wx%h\n' gradient.jpg gradient.webp gradient.tiff >"$work/formats" 2>&1 ||
  fail "identify of converted images failed: $(cat "$work/formats")"
printf 'JPEG 32x24\nWEBP 32x24\nTIFF 32x24\n' >"$work/formats.want"
cmp -s "$work/formats" "$work/formats.want" || fail "unexpected converted images: $(cat "$work/formats")"
# The gradient starts red at the top and ends blue at the bottom.
run gradient.png -format '%[fx:p{0,0}.r>0.9 && p{0,0}.b<0.1 && p{0,23}.b>0.9 && p{0,23}.r<0.1]' \
  info: >"$work/pixel" 2>&1 || fail "pixel query failed: $(cat "$work/pixel")"
test "$(cat "$work/pixel")" = 1 || fail "unexpected gradient pixels: $(cat "$work/pixel")"

# The shipped policy is the upstream open policy: MVG is readable by default.
run mvg:box.mvg box.png >"$work/mvg" 2>&1 || fail "rendering MVG failed: $(cat "$work/mvg")"
run identify -format '%m %wx%h\n' box.png >"$work/box" 2>&1 || fail 'identify of box.png failed'
test "$(cat "$work/box")" = 'PNG 20x10' || fail "unexpected MVG render: $(cat "$work/box")"

rc=0
run identify broken.png >"$work/broken" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'malformed input unexpectedly succeeded'
grep -F 'improper image header' "$work/broken" >/dev/null ||
  fail "malformed input diagnostic is missing: $(cat "$work/broken")"

# An operator policy from MAGICK_CONFIGURE_PATH is loaded and enforced.
run_hardened -list policy >"$work/policy.list" 2>&1 || fail 'listing policies failed'
grep -Fx 'Path: /policy/policy.xml' "$work/policy.list" >/dev/null ||
  fail "operator policy was not loaded: $(cat "$work/policy.list")"
grep -Fx 'Path: /etc/ImageMagick-7/policy.xml' "$work/policy.list" >/dev/null ||
  fail "shipped policy was not loaded: $(cat "$work/policy.list")"
rc=0
run_hardened mvg:box.mvg denied.png >"$work/denied" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'the operator policy did not block MVG'
grep -F 'not authorized' "$work/denied" >/dev/null ||
  fail "policy denial diagnostic is missing: $(cat "$work/denied")"
rc=0
run_hardened -size 9000x10 xc:white wide.png >"$work/wide" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'the operator policy did not enforce the width limit'
run_hardened gradient.png hardened.png >"$work/hardened" 2>&1 ||
  fail "PNG conversion failed under the operator policy: $(cat "$work/hardened")"

printf 'SMOKE PASS\n'

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")
[ -n "$version" ] || { printf 'package version not found in melange.yaml\n' >&2; exit 1; }

prefix=ffmpeg-test-$$
label="verity-test=$prefix"
tmp=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || :
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Every container runs without a network: transcoding needs no download.
run() {
  docker run --rm --label "$label" --network none "$@"
}

# Runs ffmpeg or ffprobe against the shared work directory.
media() {
  tool=$1
  shift
  run -v "$tmp/work:/work" --entrypoint "$tool" "$image" "$@"
}

# Asserts that a probed duration is within 0.1s of the expected one.
assert_duration() {
  file=$1 expected=$2
  got=$(media ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file") ||
    fail "ffprobe duration failed for $file"
  awk -v got="$got" -v want="$expected" 'BEGIN { d = got - want; if (d < 0) d = -d; exit !(got != "" && d <= 0.1) }' ||
    fail "$file duration is '$got', expected about $expected"
}

# Asserts the sorted codec names of every stream in a file.
assert_codecs() {
  file=$1 expected=$2
  got=$(media ffprobe -v error -show_entries stream=codec_name -of csv=p=0 "$file" | sort | tr '\n' ' ') ||
    fail "ffprobe codecs failed for $file"
  [ "$got" = "$expected " ] || fail "$file codecs are '$got', expected '$expected '"
}

# Asserts the container format name reported by ffprobe.
assert_format() {
  file=$1 expected=$2
  got=$(media ffprobe -v error -show_entries format=format_name -of default=noprint_wrappers=1:nokey=1 "$file") ||
    fail "ffprobe format failed for $file"
  [ "$got" = "$expected" ] || fail "$file format is '$got', expected '$expected'"
}

# OCI contract.
test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 || fail 'image does not run as uid 65532'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/ffmpeg"]' || fail 'unexpected entrypoint'
test "$(docker image inspect "$image" --format '{{.Config.WorkingDir}}')" = /work || fail 'unexpected working directory'

# Versions: the default command prints the ffmpeg version.
out=$(run "$image") || fail 'default command failed'
printf '%s\n' "$out" | head -n1 | grep -F "ffmpeg version $version " >/dev/null ||
  fail "default command reports '$(printf '%s\n' "$out" | head -n1)', expected ffmpeg version $version"
out=$(run --entrypoint ffprobe "$image" -hide_banner -version) || fail 'ffprobe -version failed'
printf '%s\n' "$out" | head -n1 | grep -F "ffprobe version $version " >/dev/null ||
  fail "ffprobe reports '$(printf '%s\n' "$out" | head -n1)', expected ffprobe version $version"

# License: an LGPL build. Neither the configure line nor the build
# configuration may carry --enable-gpl, --enable-version3 or --enable-nonfree.
config=$(run "$image" -hide_banner -buildconf) || fail 'ffmpeg -buildconf failed'
printf '%s\n' "$config" | grep -F -- '--disable-autodetect' >/dev/null || fail "unexpected build configuration: $config"
for flag in --enable-gpl --enable-version3 --enable-nonfree; do
  if printf '%s\n' "$config" | grep -F -- "$flag" >/dev/null; then
    fail "build configuration contains $flag"
  fi
  if printf '%s\n' "$out" | grep -F -- "$flag" >/dev/null; then
    fail "ffprobe -version configuration contains $flag"
  fi
done
license=$(run "$image" -hide_banner -L) || fail 'ffmpeg -L failed'
printf '%s\n' "$license" | grep -F 'GNU Lesser General Public' >/dev/null || fail "unexpected license: $license"
printf '%s\n' "$license" | grep -F 'version 2.1 of the License' >/dev/null || fail "unexpected license version: $license"
if printf '%s\n' "$license" | grep -E 'GNU General Public|nonfree|unredistributable' >/dev/null; then
  fail "build is not LGPL: $license"
fi
if run --entrypoint /usr/bin/ffplay "$image" -version >/dev/null 2>&1; then
  fail 'ffplay is shipped'
fi

# The promised external codec libraries are enabled.
encoders=$(run "$image" -hide_banner -encoders) || fail 'ffmpeg -encoders failed'
for encoder in libvpx-vp9 libopus libopenh264 libmp3lame libsvtav1 libvorbis libwebp; do
  printf '%s\n' "$encoders" | grep -E "^ [A-Z.]{6} $encoder( |$)" >/dev/null || fail "encoder $encoder is missing"
done
decoders=$(run "$image" -hide_banner -decoders) || fail 'ffmpeg -decoders failed'
printf '%s\n' "$decoders" | grep -E '^ [A-Z.]{6} libdav1d( |$)' >/dev/null || fail 'decoder libdav1d is missing'

# Negative cases: an unknown option and a missing input both fail with a
# readable error.
status=0
out=$(run "$image" -hide_banner -definitely-not-an-option 2>&1) || status=$?
[ "$status" -ne 0 ] || fail 'unknown option unexpectedly succeeded'
printf '%s\n' "$out" | grep -F 'definitely-not-an-option' >/dev/null || fail "unexpected error for unknown option: $out"
status=0
out=$(run "$image" -hide_banner -i /work/missing.mkv -f null - 2>&1) || status=$?
[ "$status" -ne 0 ] || fail 'missing input unexpectedly succeeded'
printf '%s\n' "$out" | grep -F 'No such file or directory' >/dev/null || fail "unexpected error for missing input: $out"

# Generate a 2 second lossless clip from lavfi test sources, as the image user
# in a scratch directory it owns through mode 0777.
mkdir "$tmp/work"
chmod 777 "$tmp/work"
media ffmpeg -hide_banner -nostdin -loglevel error \
  -f lavfi -i testsrc=duration=2:size=320x240:rate=25 \
  -f lavfi -i sine=frequency=440:sample_rate=48000:duration=2 \
  -c:v ffv1 -c:a pcm_s16le -shortest source.mkv || fail 'lavfi clip generation failed'
owner=$(stat -c %u "$tmp/work/source.mkv") || fail 'generated clip is missing'
[ "$owner" = 65532 ] || fail "ffmpeg wrote its output as uid $owner, expected 65532"
assert_format source.mkv 'matroska,webm'
assert_codecs source.mkv 'ffv1 pcm_s16le'
assert_duration source.mkv 2

# Transcode to WebM with libvpx VP9 and libopus.
media ffmpeg -hide_banner -nostdin -loglevel error -i source.mkv \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 500k -c:a libopus -b:a 64k out.webm ||
  fail 'webm transcode failed'
assert_format out.webm 'matroska,webm'
assert_codecs out.webm 'opus vp9'
assert_duration out.webm 2

# Transcode to MP4 with OpenH264 and the native AAC encoder.
media ffmpeg -hide_banner -nostdin -loglevel error -i source.mkv \
  -c:v libopenh264 -b:v 500k -c:a aac -b:a 96k -movflags +faststart out.mp4 ||
  fail 'mp4 transcode failed'
assert_format out.mp4 'mov,mp4,m4a,3gp,3g2,mj2'
assert_codecs out.mp4 'aac h264'
assert_duration out.mp4 2

# Encode AV1 with SVT-AV1 and MP3 with LAME, then decode the AV1 stream with
# dav1d and count every frame.
media ffmpeg -hide_banner -nostdin -loglevel error -i source.mkv \
  -c:v libsvtav1 -preset 12 -crf 50 -c:a libmp3lame -b:a 96k out-av1.mkv ||
  fail 'av1 transcode failed'
assert_codecs out-av1.mkv 'av1 mp3'
assert_duration out-av1.mkv 2
media ffmpeg -hide_banner -nostdin -loglevel error -c:v libdav1d -i out-av1.mkv \
  -map 0:v:0 -f framemd5 - >"$tmp/av1.framemd5" || fail 'dav1d decode failed'
frames=$(grep -vc '^#' "$tmp/av1.framemd5") || :
[ "$frames" = 50 ] || fail "dav1d decoded '$frames' frames, expected 50"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"

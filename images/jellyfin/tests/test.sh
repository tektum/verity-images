#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(cd "$(dirname "$0")" && pwd)
version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml")
ffmpeg_version=$(awk '$1 == "ffmpeg-version:" { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml")
dotnet_runtime_version=$(awk '$1 == "dotnet-runtime-version:" { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml")
container="verity-jellyfin-test-$$"
config_volume="verity-jellyfin-config-$$"
cache_volume="verity-jellyfin-cache-$$"
media_volume="verity-jellyfin-media-$$"
password="verity-$$"
auth='MediaBrowser Client="verity-smoke", Device="ci", DeviceId="verity-smoke", Version="1.0"'

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$config_volume" "$cache_volume" "$media_volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail "cannot read package.version from melange.yaml"
[ -n "$ffmpeg_version" ] || fail "cannot read vars.ffmpeg-version from melange.yaml"
[ -n "$dotnet_runtime_version" ] || fail "cannot read vars.dotnet-runtime-version from melange.yaml"

# OCI contract.
test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ||
  fail "image user is not 65532"
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = \
  '["/usr/bin/dotnet","/usr/lib/jellyfin/jellyfin.dll"]' || fail "unexpected entrypoint"
test "$(docker image inspect "$image" --format '{{.Config.WorkingDir}}')" = /config ||
  fail "unexpected working directory"
env_list=$(docker image inspect "$image" --format '{{range .Config.Env}}{{println .}}{{end}}')
for expected in JELLYFIN_DATA_DIR=/config JELLYFIN_CACHE_DIR=/cache \
  JELLYFIN_WEB_DIR=/usr/share/jellyfin/web JELLYFIN_FFMPEG=/usr/lib/jellyfin-ffmpeg/ffmpeg; do
  printf '%s\n' "$env_list" | grep -Fx "$expected" >/dev/null || fail "missing environment $expected"
done
test "$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.licenses"}}')" = \
  'GPL-2.0-only AND GPL-2.0-or-later AND LGPL-2.1-or-later AND MIT' || fail "unexpected license label"

# The server runs on the pinned official ASP.NET Core runtime.
runtimes=$(docker run --rm --entrypoint /usr/bin/dotnet "$image" --list-runtimes) ||
  fail "dotnet --list-runtimes failed"
for framework in Microsoft.AspNetCore.App Microsoft.NETCore.App; do
  printf '%s\n' "$runtimes" | grep -F "$framework $dotnet_runtime_version " >/dev/null ||
    fail "missing $framework $dotnet_runtime_version: $runtimes"
done

# Codec policy: LGPL FFmpeg, no GPL, nonfree or version3 code, and no
# patent-pool encoder libraries.
ffmpeg() {
  docker run --rm --entrypoint /usr/lib/jellyfin-ffmpeg/ffmpeg "$image" -hide_banner "$@"
}
ffmpeg -version | head -n1 | grep -F "ffmpeg version $ffmpeg_version " >/dev/null ||
  fail "bundled ffmpeg is not $ffmpeg_version"
buildconf=$(ffmpeg -buildconf)
if printf '%s\n' "$buildconf" |
  grep -E -- '--enable-(gpl|nonfree|version3|libx264|libx265|libopenh264|libfdk-aac|libopencore)'; then
  fail "ffmpeg build configuration violates the codec policy"
fi
ffmpeg -L | grep -F 'GNU Lesser General Public' >/dev/null || fail "ffmpeg does not report LGPL"
encoders=$(ffmpeg -encoders)
if printf '%s\n' "$encoders" | grep -E ' (libx264|libx265|libopenh264|libfdk_aac) '; then
  fail "a patent-pool encoder library is present"
fi
for encoder in libvpx-vp9 libsvtav1 libopus; do
  printf '%s\n' "$encoders" | grep -F " $encoder " >/dev/null || fail "missing encoder $encoder"
done
ffmpeg -filters | grep -E ' subtitles ' >/dev/null || fail "missing libass subtitles filter"

docker volume create "$config_volume" >/dev/null
docker volume create "$cache_volume" >/dev/null
docker volume create "$media_volume" >/dev/null

# A small VP9/Opus video for the library scan, written by the bundled ffmpeg.
# Avoid extra-type suffixes such as -clip or -sample: Jellyfin files those as
# hidden extras instead of library videos.
docker run --rm --entrypoint /usr/lib/jellyfin-ffmpeg/ffmpeg -v "$media_volume:/media" "$image" \
  -hide_banner -loglevel error -nostdin \
  -f lavfi -i testsrc=duration=2:size=128x96:rate=10 \
  -f lavfi -i sine=frequency=440:duration=2 \
  -c:v libvpx-vp9 -c:a libopus -shortest /media/verity.webm ||
  fail "could not encode the test clip"

port=
start_server() {
  docker run --name "$container" -d \
    -v "$config_volume:/config" \
    -v "$cache_volume:/cache" \
    -v "$media_volume:/media:ro" \
    -p 127.0.0.1::8096 \
    "$image" >/dev/null
  port=$(docker port "$container" 8096/tcp | awk -F: 'NR == 1 { print $2 }')
  # arm64 runs under emulation in CI, so allow a slow first start.
  i=0
  until [ "$(curl --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/health" || true)" = Healthy ]; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || fail "server did not report Healthy on /health"
    [ "$(docker inspect "$container" --format '{{.State.Running}}')" = true ] || fail "server exited"
    sleep 1
  done
}

# Requests carry the session token once login has set one.
token=
api() {
  curl --fail --silent --show-error --max-time 60 \
    -H "Authorization: $auth${token:+, Token=\"$token\"}" "$@"
}

start_server

info=$(api "http://127.0.0.1:$port/System/Info/Public") || fail "System/Info/Public failed"
printf '%s' "$info" | jq -e --arg v "$version" \
  '.ProductName == "Jellyfin Server" and (.Version == $v or .Version == ($v + ".0")) and .StartupWizardCompleted == false' \
  >/dev/null || fail "unexpected System/Info/Public: $info"

curl --fail --silent "http://127.0.0.1:$port/web/index.html" | grep -F '<title>Jellyfin</title>' >/dev/null ||
  fail "web client is not served"

docker logs "$container" 2>&1 | grep -F 'FFmpeg: /usr/lib/jellyfin-ffmpeg/ffmpeg' >/dev/null ||
  fail "server did not select the bundled ffmpeg"
docker logs "$container" 2>&1 | grep -F "Found ffmpeg version $ffmpeg_version" >/dev/null ||
  fail "server did not validate ffmpeg $ffmpeg_version"

# Complete the startup wizard.
api "http://127.0.0.1:$port/Startup/Configuration" -H 'Content-Type: application/json' \
  -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null ||
  fail "Startup/Configuration failed"
api "http://127.0.0.1:$port/Startup/User" >/dev/null || fail "GET Startup/User failed"
api "http://127.0.0.1:$port/Startup/User" -H 'Content-Type: application/json' \
  -d "{\"Name\":\"verity\",\"Password\":\"$password\"}" >/dev/null || fail "POST Startup/User failed"
api -X POST "http://127.0.0.1:$port/Startup/Complete" >/dev/null || fail "Startup/Complete failed"

# Negative: once the wizard is complete, an authenticated endpoint rejects
# anonymous requests (the first-time-setup policy admits them until then).
anonymous_system_info() {
  code=$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$port/System/Info")
  [ "$code" = 401 ] || fail "anonymous System/Info returned $code $1, expected 401"
}
anonymous_system_info "after Startup/Complete"

login() {
  api "http://127.0.0.1:$port/Users/AuthenticateByName" -H 'Content-Type: application/json' \
    -d "{\"Username\":\"verity\",\"Pw\":\"$password\"}" | jq -er .AccessToken
}
token=$(login) || fail "login failed"

# Negative: a wrong password is rejected.
code=$(curl --silent --output /dev/null --write-out '%{http_code}' -H "Authorization: $auth" \
  -H 'Content-Type: application/json' -d '{"Username":"verity","Pw":"wrong"}' \
  "http://127.0.0.1:$port/Users/AuthenticateByName")
[ "$code" = 401 ] || fail "wrong password returned $code, expected 401"

# A library scan probes the clip with the bundled ffprobe. Completing the
# wizard starts a scan of its own, which can swallow the refresh that adding a
# library queues, so request library refreshes explicitly until the clip shows.
api -X POST -H 'Content-Type: application/json' \
  -d '{"LibraryOptions":{}}' \
  "http://127.0.0.1:$port/Library/VirtualFolders?name=Verity&collectionType=homevideos&paths=%2Fmedia&refreshLibrary=false" \
  >/dev/null || fail "could not add the library"
api "http://127.0.0.1:$port/Library/VirtualFolders" | jq -e 'any(.[]; .Locations | index("/media"))' >/dev/null ||
  fail "library Verity does not list /media"
assert_running() {
  [ "$(docker inspect "$container" --format '{{.State.Running}}')" = true ] || fail "server exited $1"
}
items="http://127.0.0.1:$port/Items?Recursive=true&Fields=MediaStreams,Path"
i=0
until api "$items" |
  jq -e '[.Items[].MediaStreams[]?.Codec] | index("vp9") and index("opus")' >/dev/null 2>&1; do
  assert_running "during the library scan"
  [ $((i % 30)) -ne 0 ] || api -X POST "http://127.0.0.1:$port/Library/Refresh" >/dev/null ||
    fail "Library/Refresh failed"
  i=$((i + 1))
  if [ "$i" -ge 240 ]; then
    api "http://127.0.0.1:$port/Library/VirtualFolders" >&2 || true
    api "$items" >&2 || true
    fail "library scan did not report the vp9/opus clip"
  fi
  sleep 1
done

# Regression: a post-scan task renders the library poster in-process with
# SkiaSharp and shapes its title through HarfBuzzSharp. Two HarfBuzz copies in
# one process aborted the server there, so require the poster and a live server.
library_id=$(api "http://127.0.0.1:$port/Library/VirtualFolders" |
  jq -er '.[] | select(.Name == "Verity") | .ItemId') || fail "cannot read the Verity library id"
i=0
until api "http://127.0.0.1:$port/Items/$library_id/Images" |
  jq -e 'any(.[]; .ImageType == "Primary")' >/dev/null 2>&1; do
  assert_running "while rendering the library poster"
  i=$((i + 1))
  [ $((i % 30)) -ne 0 ] || api -X POST "http://127.0.0.1:$port/Library/Refresh" >/dev/null ||
    fail "Library/Refresh failed"
  [ "$i" -lt 240 ] || fail "library Verity did not get a rendered poster"
  sleep 1
done

# Persistence: the wizard state and user survive a container restart.
docker rm -f "$container" >/dev/null
start_server
api "http://127.0.0.1:$port/System/Info/Public" | jq -e '.StartupWizardCompleted == true' >/dev/null ||
  fail "startup wizard state did not survive restart"
anonymous_system_info "after restart"
token=
token=$(login) || fail "login failed after restart"
api "http://127.0.0.1:$port/System/Info" |
  jq -e '.Id | length > 0' >/dev/null || fail "authenticated System/Info failed after restart"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"

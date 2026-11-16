#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")
commit=$(sed -n 's/^  source-commit: \([0-9a-f]*\)$/\1/p' "$recipe")

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test -n "$version" && test -n "$commit" ||
  fail 'cannot read version and source commit from melange.yaml'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/nfpm"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Source tree is read-only; only /out is writable.
mkdir -p "$work/src/files" "$work/out" "$work/neg"
chmod 0777 "$work/out" "$work/neg"
outdir=out

run() {
  docker run --rm --network none --read-only --user "$(id -u):$(id -g)" \
    -e HOME=/tmp --tmpfs /tmp:rw,mode=1777 \
    -v "$work/src:/work:ro" -v "$work/$outdir:/out" -w /work "$image" "$@"
}

run --version >"$work/version" 2>&1 || fail 'version failed'
grep -Ex "GitVersion: +$version" "$work/version" >/dev/null ||
  fail "version $version is not embedded"
grep -Ex "GitCommit: +$commit" "$work/version" >/dev/null ||
  fail "source commit $commit is not embedded"

run --help >"$work/help" 2>&1 || fail 'help failed'
grep -F 'package' "$work/help" >/dev/null || fail 'help is missing the package command'

marker="verity-nfpm-smoke-$$"
printf '%s\n' "$marker" >"$work/src/files/hello.txt"
cat >"$work/src/files/hello.sh" <<'SH'
#!/bin/sh
echo hello
SH

cat >"$work/src/nfpm.yaml" <<'YAML'
name: verity-smoke
arch: amd64
platform: linux
version: 1.2.3
release: 4
maintainer: Verity Smoke <smoke@example.invalid>
description: nfpm smoke test package
license: MIT
contents:
  - src: ./files/hello.txt
    dst: /usr/share/verity-smoke/hello.txt
  - src: ./files/hello.sh
    dst: /usr/bin/verity-smoke
    file_info:
      mode: 0755
YAML

# --- deb: build, then inspect with ar + tar on the host. ---
run package -f nfpm.yaml -p deb -t /out/ >"$work/deb.log" 2>&1 ||
  { cat "$work/deb.log" >&2; fail 'deb build failed'; }
deb="$work/out/verity-smoke_1.2.3-4_amd64.deb"
test -s "$deb" || { ls -l "$work/out" >&2; fail 'deb file missing or misnamed'; }

mkdir "$work/deb"
(cd "$work/deb" && ar x "$deb") || fail 'deb is not an ar archive'
test "$(cat "$work/deb/debian-binary")" = 2.0 || fail 'deb format is not 2.0'
mkdir "$work/deb/control" "$work/deb/data"
tar -xzf "$work/deb/control.tar.gz" -C "$work/deb/control" ||
  fail 'deb control archive is unreadable'
tar -xzf "$work/deb/data.tar.gz" -C "$work/deb/data" ||
  fail 'deb data archive is unreadable'
ctl="$work/deb/control/control"
grep -Fx 'Package: verity-smoke' "$ctl" >/dev/null || fail 'deb package name is wrong'
grep -Fx 'Version: 1.2.3-4' "$ctl" >/dev/null || fail 'deb version is wrong'
grep -Fx 'Architecture: amd64' "$ctl" >/dev/null || fail 'deb architecture is wrong'
test "$(cat "$work/deb/data/usr/share/verity-smoke/hello.txt")" = "$marker" ||
  fail 'deb file content does not match the local source file'
test -x "$work/deb/data/usr/bin/verity-smoke" || fail 'deb script is not executable'
tar -tvzf "$work/deb/data.tar.gz" | grep -E '^-rwxr-xr-x .*\./usr/bin/verity-smoke$' \
  >/dev/null || fail 'deb script mode is not 0755'
grep -E '^[0-9a-f]{32}  usr/share/verity-smoke/hello.txt$' "$work/deb/control/md5sums" \
  >/dev/null || fail 'deb md5sums is missing the payload file'

# --- apk: concatenated gzip tar streams. ---
run package -f nfpm.yaml -p apk -t /out/ >"$work/apk.log" 2>&1 ||
  { cat "$work/apk.log" >&2; fail 'apk build failed'; }
apk=$(find "$work/out" -name 'verity-smoke*.apk' | sed -n 1p)
test -n "$apk" && test -s "$apk" || fail 'apk file missing'
mkdir "$work/apk"
gzip -dc "$apk" | tar -x --ignore-zeros -C "$work/apk" 2>/dev/null ||
  fail 'apk is not readable as gzip tar streams'
grep -Fx 'pkgname = verity-smoke' "$work/apk/.PKGINFO" >/dev/null ||
  fail 'apk package name is wrong'
grep -Fx 'pkgver = 1.2.3-r4' "$work/apk/.PKGINFO" >/dev/null ||
  fail 'apk version is wrong'
test "$(cat "$work/apk/usr/share/verity-smoke/hello.txt")" = "$marker" ||
  fail 'apk file content does not match the local source file'

# --- rpm: the lead carries name-version-release; the header lists the file. ---
run package -f nfpm.yaml -p rpm -t /out/ >"$work/rpm.log" 2>&1 ||
  { cat "$work/rpm.log" >&2; fail 'rpm build failed'; }
rpm=$(find "$work/out" -name 'verity-smoke*.rpm' | sed -n 1p)
test -n "$rpm" && test -s "$rpm" || fail 'rpm file missing'
test "$(od -An -tx1 -N4 "$rpm" | tr -d ' \n')" = edabeedb || fail 'rpm lead magic is wrong'
# RPM lead: 4-byte magic, 2 version bytes, 2-byte type, 2-byte arch, then a
# 66-byte NUL-padded name-version-release field at offset 10.
lead_name=$(dd if="$rpm" bs=1 skip=10 count=66 2>/dev/null | tr -d '\000')
test "$lead_name" = verity-smoke-1.2.3-4 ||
  fail "rpm lead name-version-release is '$lead_name', expected verity-smoke-1.2.3-4"
grep -aF '/usr/share/verity-smoke' "$rpm" >/dev/null || fail 'rpm header does not list the file'

# --- negative cases, written to a separate output directory ---
outdir=neg
rc=0
run package -f missing.yaml -p deb -t /out/ >"$work/neg-config.log" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'missing config was accepted'
grep -F 'missing.yaml' "$work/neg-config.log" >/dev/null ||
  fail 'missing config diagnostic does not name the file'

sed 's#\./files/hello.txt#./files/absent.txt#' "$work/src/nfpm.yaml" >"$work/src/absent.yaml"
rc=0
run package -f absent.yaml -p deb -t /out/ >"$work/neg-src.log" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'missing source file was accepted'
grep -F 'absent.txt' "$work/neg-src.log" >/dev/null ||
  fail 'missing source diagnostic does not name the file'

rc=0
run package -f nfpm.yaml -p nosuchformat -t /out/ >"$work/neg-fmt.log" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'unknown packager was accepted'
grep -F 'nosuchformat' "$work/neg-fmt.log" >/dev/null ||
  fail 'unknown packager diagnostic does not name the format'

grep -v '^name:' "$work/src/nfpm.yaml" >"$work/src/noname.yaml"
rc=0
run package -f noname.yaml -p deb -t /out/ >"$work/neg-name.log" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'config without a name was accepted'
grep -Fi 'package name must be provided' "$work/neg-name.log" >/dev/null ||
  fail 'missing name diagnostic does not mention the field'

# Nothing from the failed runs may be left behind.
test -z "$(find "$work/neg" -type f)" ||
  { ls -l "$work/neg" >&2; fail 'failed runs left packages behind'; }

printf 'SMOKE PASS image=%s\n' "$image"

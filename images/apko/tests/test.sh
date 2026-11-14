#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")
[ -n "$expected_version" ] || { echo 'melange package version not found' >&2; exit 1; }
work=$(mktemp -d)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# OCI runtime contract.
[ "$(docker image inspect -f '{{.Config.Entrypoint}}' "$image")" = '[/usr/bin/apko]' ] || fail 'unexpected OCI entrypoint'
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ] || fail 'unexpected OCI working directory'
docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image" | grep -Fx 'HOME=/home/nonroot' >/dev/null ||
  fail 'HOME is not /home/nonroot'

case $(docker image inspect -f '{{.Architecture}}' "$image") in
  amd64) arch=x86_64 ;;
  arm64) arch=aarch64 ;;
  *) fail 'unsupported image architecture' ;;
esac

docker run --rm --network none "$image" version >"$work/version" 2>&1 || fail "apko version failed: $(cat "$work/version")"
grep -Eq "^GitVersion: +v${expected_version}\$" "$work/version" ||
  fail "apko version does not report v${expected_version}: $(cat "$work/version")"

# A minimal APK v2 package: a control and a data gzip member, as apk-tools and
# apko expect, with per-file SHA-1 PAX records, the control checksum, and the
# datahash wired into a hand-written APKINDEX.
pkg=apko-smoke
pkgver=1.0.0-r0
repo="$work/repo"
build="$work/build"
mkdir -p "$repo/$arch" "$build"
cat >"$build/apkrepo.py" <<'PY'
import base64, gzip, hashlib, io, sys, tarfile

def member(entries, cut=False, checksums=False):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for name, mode, data in entries:
            info = tarfile.TarInfo(name)
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = 0
            info.mode = mode
            if data is None:
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
            else:
                info.size = len(data)
                if checksums:
                    info.pax_headers = {"APK-TOOLS.checksum.SHA1": hashlib.sha1(data).hexdigest()}
                tar.addfile(info, io.BytesIO(data))
    body = raw.getvalue()
    if cut:
        # Like abuild, drop the end-of-archive blocks so apk can tell where the
        # signature member ends and the signed index begins.
        body = body.rstrip(b"\0")
        body += b"\0" * (-len(body) % 512)
    return gzip.compress(body, compresslevel=9, mtime=0)

def package(build, repo, pkg, ver, arch):
    data = member([
        ("usr", 0o755, None),
        ("usr/bin", 0o755, None),
        ("usr/bin/" + pkg, 0o755, b"#!/bin/sh\necho apko-smoke\n"),
        ("usr/share", 0o755, None),
        ("usr/share/" + pkg, 0o755, None),
        ("usr/share/%s/payload.txt" % pkg, 0o644, b"apko-smoke-payload\n"),
    ], checksums=True)
    pkginfo = (
        "pkgname = %s\npkgver = %s\npkgdesc = apko smoke test package\n"
        "url = https://example.invalid/\nsize = 64\narch = %s\norigin = %s\n"
        "license = Apache-2.0\ndatahash = %s\n"
    ) % (pkg, ver, arch, pkg, hashlib.sha256(data).hexdigest())
    control = member([(".PKGINFO", 0o644, pkginfo.encode())])
    apk = control + data
    with open("%s/%s-%s.apk" % (repo, pkg, ver), "wb") as out:
        out.write(apk)
    checksum = "Q1" + base64.b64encode(hashlib.sha1(control).digest()).decode()
    index = (
        "C:%s\nP:%s\nV:%s\nA:%s\nS:%d\nI:64\nT:apko smoke test package\n"
        "U:https://example.invalid/\nL:Apache-2.0\no:%s\n\n"
    ) % (checksum, pkg, ver, arch, len(apk), pkg)
    with open(build + "/index.tar.gz", "wb") as out:
        out.write(member([("APKINDEX", 0o644, index.encode())]))
    print(checksum)

def signature(build, name):
    with open(build + "/signature", "rb") as sig:
        data = sig.read()
    with open(build + "/sig.tar.gz", "wb") as out:
        out.write(member([(name, 0o644, data)], cut=True))

if sys.argv[1] == "package":
    package(*sys.argv[2:])
else:
    signature(*sys.argv[2:])
PY
checksum=$(python3 "$build/apkrepo.py" package "$build" "$repo/$arch" "$pkg" "$pkgver" "$arch")
case $checksum in Q1*) ;; *) fail 'package generation did not report a Q1 checksum' ;; esac

# Sign the index with a throwaway RSA key. apk resolves the key by the file
# name embedded in the signature member, so the wrong key reuses that name.
keys="$work/keys"
mkdir -p "$keys" "$work/wrongkey"
openssl genrsa -out "$keys/smoke.rsa" 2048 2>/dev/null
openssl rsa -in "$keys/smoke.rsa" -pubout -out "$repo/smoke.rsa.pub" 2>/dev/null
openssl genrsa -out "$keys/wrong.rsa" 2048 2>/dev/null
openssl rsa -in "$keys/wrong.rsa" -pubout -out "$work/wrongkey/smoke.rsa.pub" 2>/dev/null
openssl dgst -sha256 -sign "$keys/smoke.rsa" -out "$build/signature" "$build/index.tar.gz"
rm -rf "$keys"
python3 "$build/apkrepo.py" signature "$build" .SIGN.RSA256.smoke.rsa.pub
cat "$build/sig.tar.gz" "$build/index.tar.gz" >"$repo/$arch/APKINDEX.tar.gz"

cat >"$work/smoke.yaml" <<EOF
contents:
  repositories:
    - /work/repo
  keyring:
    - /work/repo/smoke.rsa.pub
  packages:
    - $pkg
accounts:
  groups:
    - groupname: smoke
      gid: 10001
  users:
    - username: smoke
      uid: 10001
      gid: 10001
  run-as: 10001
entrypoint:
  command: /usr/bin/$pkg
archs:
  - $arch
EOF
sed 's|/work/repo/smoke.rsa.pub|/work/wrongkey/smoke.rsa.pub|' "$work/smoke.yaml" >"$work/wrongkey.yaml"
sed "s|^    - $pkg\$|    - $pkg\n    - apko-smoke-missing|" "$work/smoke.yaml" >"$work/missing.yaml"
sed 's|^  packages:$|  packagez:|' "$work/smoke.yaml" >"$work/unknown.yaml"
grep -Fx '    - apko-smoke-missing' "$work/missing.yaml" >/dev/null || fail 'missing-package fixture not generated'
grep -Fx '  packagez:' "$work/unknown.yaml" >/dev/null || fail 'unknown-field fixture not generated'

# The image runs as 65532: it writes only files into host-owned writable dirs.
mkdir -p "$work/out" "$work/sbom"
chmod 0755 "$work" "$repo" "$repo/$arch" "$work/wrongkey"
chmod 0644 "$repo/$arch"/* "$repo/smoke.rsa.pub" "$work/wrongkey/smoke.rsa.pub" "$work"/*.yaml
chmod 0777 "$work/out" "$work/sbom"

run_apko() {
  docker run --rm --network none \
    -v "$work/repo:/work/repo:ro" \
    -v "$work/wrongkey:/work/wrongkey:ro" \
    -v "$work/smoke.yaml:/work/smoke.yaml:ro" \
    -v "$work/wrongkey.yaml:/work/wrongkey.yaml:ro" \
    -v "$work/missing.yaml:/work/missing.yaml:ro" \
    -v "$work/unknown.yaml:/work/unknown.yaml:ro" \
    -v "$work/out:/work/out" \
    -v "$work/sbom:/work/sbom" \
    "$image" "$@"
}

run_apko show-config /work/smoke.yaml >"$work/show-config" 2>&1 ||
  fail "show-config rejected a valid config: $(cat "$work/show-config")"
grep -F "$pkg" "$work/show-config" >/dev/null || fail 'show-config does not list the package'

run_apko lock /work/smoke.yaml --arch "$arch" --output /work/out/smoke.lock.json >"$work/lock.log" 2>&1 ||
  fail "apko lock failed: $(cat "$work/lock.log")"
lock="$work/out/smoke.lock.json"
[ "$(jq -r --arg p "$pkg" '[.contents.packages[] | select(.name == $p)] | length' "$lock")" = 1 ] ||
  fail 'lock does not list the package exactly once'
[ "$(jq -r --arg p "$pkg" '.contents.packages[] | select(.name == $p) | .version' "$lock")" = "$pkgver" ] ||
  fail 'lock has the wrong package version'
[ "$(jq -r --arg p "$pkg" '.contents.packages[] | select(.name == $p) | .checksum' "$lock")" = "$checksum" ] ||
  fail 'lock has the wrong package checksum'
[ "$(jq -r --arg p "$pkg" '.contents.packages[] | select(.name == $p) | .architecture' "$lock")" = "$arch" ] ||
  fail 'lock has the wrong package architecture'

run_apko build /work/smoke.yaml apko-smoke:test /work/out/image.tar \
  --offline --arch "$arch" --lockfile /work/out/smoke.lock.json --sbom-path /work/sbom \
  >"$work/build.log" 2>&1 || fail "offline apko build failed: $(cat "$work/build.log")"

# Inspect the produced image tarball without loading it.
oci="$work/oci"
mkdir -p "$oci"
tar -xf "$work/out/image.tar" -C "$oci"
[ -f "$oci/manifest.json" ] || fail 'image tarball has no manifest.json'
config_path=$(jq -r '.[0].Config' "$oci/manifest.json")
[ "$(jq -r '.config.User' "$oci/$config_path")" = 10001 ] || fail 'built image has the wrong user'
[ "$(jq -c '.config.Entrypoint' "$oci/$config_path")" = "[\"/usr/bin/$pkg\"]" ] || fail 'built image has the wrong entrypoint'
[ "$(jq -r '.architecture' "$oci/$config_path")" = "$(docker image inspect -f '{{.Architecture}}' "$image")" ] ||
  fail 'built image has the wrong architecture'
layer=$(jq -r '.[0].Layers[0]' "$oci/manifest.json")
mkdir -p "$oci/rootfs"
tar -tvzf "$oci/$layer" >"$oci/layer.list" || fail 'built image layer is not a gzip tarball'
grep -E "^-rwxr-xr-x .* usr/bin/$pkg\$" "$oci/layer.list" >/dev/null || fail 'built image lost the package executable'
apk_db=$(sed -n 's|^.* \(\(usr/\)\{0,1\}lib/apk/db/installed\)$|\1|p' "$oci/layer.list")
[ -n "$apk_db" ] || fail 'built image has no apk database'
tar -xzf "$oci/$layer" -C "$oci/rootfs" "usr/share/$pkg/payload.txt" etc/passwd "$apk_db" ||
  fail 'built image layer lacks the package payload or passwd'
[ "$(cat "$oci/rootfs/usr/share/$pkg/payload.txt")" = apko-smoke-payload ] || fail 'built image has the wrong package payload'
grep -E "^smoke:x:10001:10001:" "$oci/rootfs/etc/passwd" >/dev/null || fail 'built image lacks the configured account'
grep -Fx "P:$pkg" "$oci/rootfs/$apk_db" >/dev/null || fail 'built image apk database does not record the package'

sbom="$work/sbom/sbom-$arch.spdx.json"
[ -s "$sbom" ] || fail 'apko build wrote no SBOM'
[ "$(jq -r --arg p "$pkg" '.packages[] | select(.name == $p) | .versionInfo' "$sbom")" = "$pkgver" ] ||
  fail 'SBOM does not list the package version'

# Negative cases.
if run_apko show-config /work/unknown.yaml >"$work/unknown.log" 2>&1; then
  fail 'config with an unknown field was accepted'
fi
grep -F packagez "$work/unknown.log" >/dev/null || fail "unknown field diagnostic missing: $(cat "$work/unknown.log")"

if run_apko lock /work/missing.yaml --arch "$arch" --output /work/out/missing.lock.json >"$work/missing.log" 2>&1; then
  fail 'lock with a missing package succeeded'
fi
grep -F apko-smoke-missing "$work/missing.log" >/dev/null || fail "missing package diagnostic missing: $(cat "$work/missing.log")"

if run_apko build /work/wrongkey.yaml apko-smoke:test /work/out/wrongkey.tar \
  --offline --arch "$arch" >"$work/wrongkey.log" 2>&1; then
  fail 'build trusting the wrong key succeeded'
fi
grep -Ei 'signature|verif' "$work/wrongkey.log" >/dev/null || fail "signature diagnostic missing: $(cat "$work/wrongkey.log")"
[ ! -e "$work/out/wrongkey.tar" ] || fail 'failed signature build left an image tarball'

printf 'SMOKE PASS image=%s\n' "$image"

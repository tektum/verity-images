#!/bin/sh
# Offline smoke test for the gitsign image.
#
# No container started here can reach the internet. gitsign runs with
# --network none or on an internal Docker network whose only peer is a local
# fixture, and every Sigstore endpoint (Fulcio, Rekor, the OIDC issuer, the
# Fulcio root, and the Rekor and CT log keys) is pointed at a fixture host or a
# local file, so nothing here calls the Sigstore public-good instance. On the
# internal network the public-good host names resolve to the fixture, which
# records every connection, and the test asserts that none of them arrives.
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - gitsign=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
python_index='docker.io/library/python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e'
public_hosts='fulcio.sigstore.dev rekor.sigstore.dev oauth2.sigstore.dev tuf-repo-cdn.sigstore.dev timestamp.sigstore.dev'
label="verity-gitsign-test-$$"
network="verity-gitsign-network-$$"
fixture="verity-gitsign-fixture-$$"
# Hard deadline for every container. gitsign has no Fulcio client timeout of
# its own, so this bounds the job if a failure path ever stops failing fast;
# each path below finishes far inside it, including arm64 under emulation.
deadline=90
work=$(mktemp -d)
uid="$(id -u):$(id -g)"

cleanup() {
  ids=$(docker ps -aq --filter "label=$label" 2>/dev/null || true)
  # shellcheck disable=SC2086 # one container id per word
  [ -z "$ids" ] || docker rm -f $ids >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

fail_with() {
  printf 'FAIL: %s\n--- output ---\n' "$1" >&2
  cat "$2" >&2
  exit 1
}

# box OUTPUT NETWORK DOCKER_ARGS... IMAGE ARGS...
# Runs one container under the hard deadline as the invoking user with a
# read-only root filesystem and /work/home as HOME, and stores its exit status
# in rc. A container that outlives the deadline fails the test as a hang.
box() {
  out=$1
  net=$2
  shift 2
  rc=0
  timeout -k 10 "$deadline" docker run --rm --label "$label" --network "$net" \
    --read-only --tmpfs /tmp:rw,mode=1777 --user "$uid" -e HOME=/work/home \
    -v "$work:/work" -w /work/repo "$@" >"$out" 2>&1 || rc=$?
  case $rc in
    124 | 137) fail_with "container hung past the ${deadline}s deadline: $*" "$out" ;;
  esac
}

expect_ok() {
  [ "$rc" -eq 0 ] || fail_with "$2 exited with status $rc" "$1"
}

expect_fail() {
  [ "$rc" -ne 0 ] || fail_with "$2 unexpectedly succeeded" "$1"
}

has() {
  grep -F -- "$2" "$1" >/dev/null || fail_with "$3" "$1"
}

lacks() {
  if grep -F -- "$2" "$1" >/dev/null; then
    fail_with "$3" "$1"
  fi
}

no_public_good() {
  lacks "$1" sigstore.dev 'gitsign targeted a Sigstore public-good host'
}

git_box() {
  box "$work/git.out" none --entrypoint /usr/bin/git "$image" "$@"
  expect_ok "$work/git.out" "git $*"
}

git_out() {
  git_box "$@"
  cat "$work/git.out"
}

# Print one field of the "parsed config" JSON that gitsign version emits.
cfg() {
  sed '1,/^parsed config:$/d' "$1" | jq -r "$2"
}

expect_cfg() {
  actual=$(cfg "$1" "$2") || fail_with "parsed config is not JSON" "$1"
  [ "$actual" = "$3" ] || fail_with "$4: $2 is '$actual', want '$3'" "$1"
}

[ -n "$version" ] || fail 'could not read the pinned gitsign version'

# OCI runtime contract.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/gitsign"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx HOME=/home/nonroot >/dev/null || fail 'HOME is not /home/nonroot'

# Version and built-in defaults, as the image user with no network. Printing
# the default public-good URLs is local; nothing is contacted.
rc=0
timeout -k 10 "$deadline" docker run --rm --label "$label" --network none --read-only \
  "$image" version >"$work/version" 2>&1 || rc=$?
expect_ok "$work/version" 'gitsign version'
# Wolfi rebuilds with patched dependencies, which Go marks as +dirty.
head -n 1 "$work/version" | grep -Ex "gitsign version v$version(\+dirty)?" >/dev/null ||
  fail_with "version does not report $version" "$work/version"
lacks "$work/version" 'env:' 'version reports Sigstore environment variables the image does not set'
expect_cfg "$work/version" .Fulcio https://fulcio.sigstore.dev 'default Fulcio'
expect_cfg "$work/version" .Rekor https://rekor.sigstore.dev 'default Rekor'
expect_cfg "$work/version" .Issuer https://oauth2.sigstore.dev/auth 'default issuer'
expect_cfg "$work/version" .RekorMode online 'default Rekor mode'
expect_cfg "$work/version" .EnableSigstoreGo true 'default signing path'
expect_cfg "$work/version" .RekorVersion 1 'default Rekor version'

rc=0
timeout -k 10 "$deadline" docker run --rm --label "$label" --network none --read-only \
  --entrypoint /usr/bin/git "$image" version >"$work/git-version" 2>&1 || rc=$?
expect_ok "$work/git-version" 'git version'
grep -Ex 'git version [0-9]+\.[0-9]+\.[0-9]+' "$work/git-version" >/dev/null ||
  fail_with 'git is not usable in the image' "$work/git-version"

rc=0
timeout -k 10 "$deadline" docker run --rm --label "$label" --network none --read-only \
  "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
expect_fail "$work/flag" 'an unknown flag'
has "$work/flag" 'unknown flag: --definitely-invalid' 'invalid flag diagnostic is missing'

# A repository whose commits git signs through gitsign.
mkdir -p "$work/home" "$work/repo" "$work/pki"
git_box init -q -b main .
git_box config user.name 'Verity Smoke'
git_box config user.email verity@example.test
git_box config gpg.format x509
git_box config gpg.x509.program gitsign
git_box commit -q --allow-empty -m unsigned
head=$(git_out rev-parse HEAD)

# Configuration precedence: git config, then SIGSTORE_*, then GITSIGN_*.
git_box config --global gitsign.fulcio http://fulcio.gitconfig.test
git_box config --global gitsign.rekorMode offline
git_box config --global gitsign.connectorID https://github.com/login/oauth
box "$work/cfg-git" none "$image" version
expect_ok "$work/cfg-git" 'version with git config'
expect_cfg "$work/cfg-git" .Fulcio http://fulcio.gitconfig.test 'global git config'
expect_cfg "$work/cfg-git" .RekorMode offline 'global git config'
expect_cfg "$work/cfg-git" .ConnectorID https://github.com/login/oauth 'global git config'

box "$work/cfg-sigstore" none -e SIGSTORE_FULCIO_URL=http://fulcio.sigstore-env.test \
  -e SIGSTORE_ROOT_FILE=/work/pki/legacy-root.pem "$image" version
expect_ok "$work/cfg-sigstore" 'version with SIGSTORE_ variables'
expect_cfg "$work/cfg-sigstore" .Fulcio http://fulcio.sigstore-env.test 'SIGSTORE_FULCIO_URL over git config'
expect_cfg "$work/cfg-sigstore" .FulcioRoot /work/pki/legacy-root.pem 'SIGSTORE_ROOT_FILE'
has "$work/cfg-sigstore" 'SIGSTORE_FULCIO_URL=http://fulcio.sigstore-env.test' \
  'version does not list the SIGSTORE_ environment'

box "$work/cfg-gitsign" none -e SIGSTORE_FULCIO_URL=http://fulcio.sigstore-env.test \
  -e GITSIGN_FULCIO_URL=http://fulcio.gitsign-env.test \
  -e SIGSTORE_ROOT_FILE=/work/pki/legacy-root.pem -e GITSIGN_FULCIO_ROOT=/work/pki/ca.pem \
  -e GITSIGN_REKOR_MODE=online -e GITSIGN_REKOR_VERSION=2 "$image" version
expect_ok "$work/cfg-gitsign" 'version with GITSIGN_ variables'
expect_cfg "$work/cfg-gitsign" .Fulcio http://fulcio.gitsign-env.test 'GITSIGN_FULCIO_URL over SIGSTORE_FULCIO_URL'
expect_cfg "$work/cfg-gitsign" .FulcioRoot /work/pki/ca.pem 'GITSIGN_FULCIO_ROOT over SIGSTORE_ROOT_FILE'
expect_cfg "$work/cfg-gitsign" .RekorMode online 'GITSIGN_REKOR_MODE over git config'
expect_cfg "$work/cfg-gitsign" .RekorVersion 2 'GITSIGN_REKOR_VERSION'
expect_cfg "$work/cfg-gitsign" .ConnectorID https://github.com/login/oauth 'unset variables keep git config'
has "$work/cfg-gitsign" 'GITSIGN_FULCIO_URL=http://fulcio.gitsign-env.test' \
  'version does not list the GITSIGN_ environment'
rm -f "$work/home/.gitconfig"

# Invalid configuration fails before any network use, with exit status 2.
box "$work/bad-range" none -e GITSIGN_REKOR_VERSION=3 "$image" version
[ "$rc" -eq 2 ] || fail_with "out-of-range Rekor version exited $rc, want 2" "$work/bad-range"
has "$work/bad-range" 'gitsign.rekorVersion must be 1 or 2, got 3' 'out-of-range Rekor version diagnostic'

box "$work/bad-number" none -e GITSIGN_REKOR_VERSION=two "$image" version
[ "$rc" -eq 2 ] || fail_with "non-numeric Rekor version exited $rc, want 2" "$work/bad-number"
has "$work/bad-number" 'invalid GITSIGN_REKOR_VERSION "two"' 'non-numeric Rekor version diagnostic'

box "$work/bad-legacy" none -e GITSIGN_ENABLE_SIGSTORE_GO=false -e GITSIGN_REKOR_VERSION=2 \
  "$image" version
[ "$rc" -eq 2 ] || fail_with "Rekor version on the legacy path exited $rc, want 2" "$work/bad-legacy"
has "$work/bad-legacy" 'gitsign.rekorVersion can only be set when gitsign.enableSigstoreGo=true' \
  'legacy-path Rekor version diagnostic'

# An invalid repository-level value is reported and ignored.
git_box config gitsign.rekorVersion bogus
box "$work/bad-git" none "$image" version
expect_ok "$work/bad-git" 'version with an invalid git config value'
has "$work/bad-git" 'invalid gitsign.rekorVersion value "bogus", ignoring' \
  'invalid git config value is not reported'
expect_cfg "$work/bad-git" .RekorVersion 1 'ignored git config value'
git_box config --unset gitsign.rekorVersion

# Local trust material: a stand-in Fulcio root with one email leaf, a second
# root that never issued it, and a stand-in transparency log key.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "$work/pki/ca.key" -out "$work/pki/ca.pem" -days 30 -subj /CN=verity-fulcio-root \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign >/dev/null 2>&1 ||
  fail 'cannot create the test root'
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "$work/pki/other.key" -out "$work/pki/other-ca.pem" -days 30 -subj /CN=verity-other-root \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign >/dev/null 2>&1 ||
  fail 'cannot create the untrusted root'
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$work/pki/leaf.key" \
  -out "$work/pki/leaf.csr" -subj /CN=verity >/dev/null 2>&1 || fail 'cannot create the leaf request'
printf '%s\n' 'subjectAltName=email:verity@example.test' 'extendedKeyUsage=codeSigning' \
  'keyUsage=critical,digitalSignature' 'basicConstraints=critical,CA:FALSE' >"$work/pki/leaf.ext"
openssl x509 -req -in "$work/pki/leaf.csr" -CA "$work/pki/ca.pem" -CAkey "$work/pki/ca.key" \
  -CAcreateserial -out "$work/pki/leaf.pem" -days 30 -extfile "$work/pki/leaf.ext" >/dev/null 2>&1 ||
  fail 'cannot issue the leaf certificate'
openssl ecparam -name prime256v1 -genkey -noout -out "$work/pki/log.key" 2>/dev/null ||
  fail 'cannot create the log key'
openssl ec -in "$work/pki/log.key" -pubout -out "$work/pki/log.pub" 2>/dev/null ||
  fail 'cannot export the log key'

# Every endpoint and trust source gitsign would otherwise take from the
# public-good instance or its TUF repository. The Fulcio URL and root are
# passed per run instead, because a variable repeated with -e does not
# reliably override an --env-file entry.
cat >"$work/sigstore.env" <<'ENV'
GITSIGN_REKOR_URL=http://rekor.fixture.test
GITSIGN_OIDC_ISSUER=http://issuer.fixture.test
SIGSTORE_REKOR_PUBLIC_KEY=/work/pki/log.pub
SIGSTORE_CT_LOG_PUBLIC_KEY_FILE=/work/pki/log.pub
ENV

# A syntactically valid ES256 identity token. Fulcio verifies it; gitsign only
# reads its claims, so the signature bytes are a placeholder.
b64url() {
  printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'
}
token="$(b64url '{"alg":"ES256","typ":"JWT"}').$(b64url \
  '{"iss":"http://issuer.fixture.test","sub":"verity@example.test","email":"verity@example.test","email_verified":true,"aud":"sigstore","iat":1700000000,"exp":4102444800}').$(b64url placeholder)"

# sign OUTPUT NETWORK FULCIO_URL DOCKER_ARGS...
sign() {
  out=$1
  net=$2
  fulcio=$3
  shift 3
  box "$out" "$net" --env-file "$work/sigstore.env" -e GITSIGN_FULCIO_URL="$fulcio" \
    -e GITSIGN_FULCIO_ROOT=/work/pki/ca.pem "$@" \
    --entrypoint /usr/bin/git "$image" commit --allow-empty -S -m 'must not be created'
}

# expect_unsigned OUTPUT DESCRIPTION: signing failed and created no commit.
expect_unsigned() {
  expect_fail "$1" "$2"
  has "$1" 'gpg failed to sign the data' "$2 did not fail in the signing program"
  no_public_good "$1"
  [ "$(git_out rev-parse HEAD)" = "$head" ] || fail "$2 created a commit"
}

# Signing with no reachable Fulcio fails promptly with the Fulcio error.
sign "$work/sign-offline" none http://fulcio.fixture.test -e SIGSTORE_ID_TOKEN="$token"
expect_unsigned "$work/sign-offline" 'signing without a reachable Fulcio'
has "$work/sign-offline" 'failed to get identity' 'unreachable Fulcio is not reported as an identity failure'
has "$work/sign-offline" 'http://fulcio.fixture.test/api/v1/signingCert' \
  'unreachable Fulcio error does not name the configured Fulcio'

# Without a token gitsign needs the OIDC issuer, which is unreachable too.
sign "$work/sign-no-token" none http://fulcio.fixture.test
expect_unsigned "$work/sign-no-token" 'signing without a token or reachable issuer'
has "$work/sign-no-token" 'http://issuer.fixture.test/.well-known/openid-configuration' \
  'unreachable issuer error does not name the configured issuer'

# Verification negative cases. git cat-file gives the signed payload; OpenSSL
# builds a CMS signature over it in the SIGNED MESSAGE armor gitsign emits.
git_out cat-file commit HEAD >"$work/payload"
openssl cms -sign -binary -md sha256 -in "$work/payload" -signer "$work/pki/leaf.pem" \
  -inkey "$work/pki/leaf.key" -outform PEM -out "$work/payload.cms" 2>/dev/null ||
  fail 'cannot create the CMS signature'
sed -e 's/BEGIN CMS/BEGIN SIGNED MESSAGE/' -e 's/END CMS/END SIGNED MESSAGE/' \
  "$work/payload.cms" >"$work/payload.sig"
printf '%s\n' '-----BEGIN SIGNED MESSAGE-----' 'bm90IGEgQ01TIHNpZ25hdHVyZQ==' \
  '-----END SIGNED MESSAGE-----' >"$work/garbage.sig"

# forge NAME SIGNATURE PAYLOAD: store a commit carrying SIGNATURE as refs/heads/NAME.
forge() {
  awk -v sigfile="$2" '
    BEGIN { while ((getline line < sigfile) > 0) sig[n++] = line }
    { print }
    /^committer / { print "gpgsig " sig[0]; for (i = 1; i < n; i++) print " " sig[i] }
  ' "$3" >"$work/$1.commit"
  id=$(git_out hash-object -t commit -w "/work/$1.commit")
  git_box update-ref "refs/heads/$1" "$id"
}
sed 's/^unsigned$/tampered/' "$work/payload" >"$work/tampered.payload"
forge signed "$work/payload.sig" "$work/payload"
forge tampered "$work/payload.sig" "$work/tampered.payload"
forge garbage "$work/garbage.sig" "$work/payload"

# verify OUTPUT NETWORK FULCIO_ROOT DOCKER_ARGS... IMAGE ARGS...
verify() {
  out=$1
  net=$2
  root=$3
  shift 3
  box "$out" "$net" --env-file "$work/sigstore.env" -e GITSIGN_FULCIO_ROOT="$root" "$@"
  expect_fail "$out" "verification ($*)"
  no_public_good "$out"
}

verify "$work/v-unsigned" none /work/pki/ca.pem --entrypoint /usr/bin/git "$image" verify-commit HEAD
verify "$work/v-unsigned-cli" none /work/pki/ca.pem "$image" verify \
  --certificate-identity=verity@example.test --certificate-oidc-issuer=http://issuer.fixture.test HEAD
has "$work/v-unsigned-cli" 'commit has no gpgsig or gpgsig-sha256 signature' \
  'unsigned commit diagnostic is missing'

verify "$work/v-garbage" none /work/pki/ca.pem --entrypoint /usr/bin/git "$image" verify-commit garbage
has "$work/v-garbage" 'failed to parse signature' 'malformed signature diagnostic is missing'

verify "$work/v-tampered" none /work/pki/ca.pem --entrypoint /usr/bin/git "$image" verify-commit tampered
has "$work/v-tampered" 'content digest does not match signed message digest' \
  'tampered commit diagnostic is missing'
verify "$work/v-tampered-legacy" none /work/pki/ca.pem -e GITSIGN_ENABLE_SIGSTORE_GO=false \
  --entrypoint /usr/bin/git "$image" verify-commit tampered
has "$work/v-tampered-legacy" 'invalid message digest' 'legacy tampered commit diagnostic is missing'

# The legacy path checks the chain before the transparency log, so an
# unrelated root rejects the certificate without any lookup.
verify "$work/v-untrusted" none /work/pki/other-ca.pem -e GITSIGN_ENABLE_SIGSTORE_GO=false \
  --entrypoint /usr/bin/git "$image" verify-commit signed
has "$work/v-untrusted" 'x509: certificate signed by unknown authority' \
  'untrusted root diagnostic is missing'
verify "$work/v-untrusted-cli" none /work/pki/other-ca.pem -e GITSIGN_ENABLE_SIGSTORE_GO=false \
  "$image" verify \
  --certificate-identity=verity@example.test --certificate-oidc-issuer=http://issuer.fixture.test signed
has "$work/v-untrusted-cli" 'x509: certificate signed by unknown authority' \
  'untrusted root diagnostic is missing from gitsign verify'

# A correctly chained signature is still rejected when Rekor is unreachable.
verify "$work/v-no-rekor" none /work/pki/ca.pem --entrypoint /usr/bin/git "$image" verify-commit signed
has "$work/v-no-rekor" 'looking up rekor entry' 'unreachable Rekor is not reported'
has "$work/v-no-rekor" 'http://rekor.fixture.test/api/v1/index/retrieve' \
  'unreachable Rekor error does not name the configured Rekor'
verify "$work/v-no-rekor-legacy" none /work/pki/ca.pem -e GITSIGN_ENABLE_SIGSTORE_GO=false \
  --entrypoint /usr/bin/git "$image" verify-commit signed
has "$work/v-no-rekor-legacy" 'failed to validate rekor entry' 'legacy unreachable Rekor is not reported'

# Internal network: one fixture answers for the configured hosts and for the
# public-good names, and logs every HTTP request and every TLS connection.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
helper_raw=$(docker buildx imagetools inspect --raw "$python_index") ||
  fail 'cannot inspect helper image index'
[ "sha256:$(printf '%s' "$helper_raw" | sha256sum | cut -d' ' -f1)" = "${python_index#*@}" ] ||
  fail 'helper image index digest mismatch'
helper_digest=$(printf '%s' "$helper_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail 'cannot resolve helper image digest'
case $helper_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch helper image in $python_index" ;;
esac
python=${python_index%%:*}@$helper_digest
docker pull --quiet --platform "linux/$image_arch" "$python" >/dev/null ||
  fail 'cannot pull helper image'

cat >"$work/fixture.py" <<'PY'
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def log(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def answer(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        host = (self.headers.get("Host") or "-").split(":")[0]
        log("HTTP %s %s %s" % (host, self.command, self.path))
        if host == "fulcio.fixture.test":
            code, body = 503, '{"code":503,"message":"verity fixture fulcio unavailable"}'
        elif host == "rekor.fixture.test" and self.path == "/api/v1/index/retrieve":
            code, body = 200, "[]"
        else:
            code, body = 404, '{"code":404,"message":"not found"}'
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = answer


def tls_trap(server):
    while True:
        conn, peer = server.accept()
        log("TLS %s" % peer[0])
        conn.close()


# Bind both listeners before READY so the first request cannot be refused.
trap = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
trap.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
trap.bind(("0.0.0.0", 443))
trap.listen(16)
httpd = ThreadingHTTPServer(("0.0.0.0", 80), Handler)
threading.Thread(target=tls_trap, args=(trap,), daemon=True).start()
log("READY")
httpd.serve_forever()
PY
chmod -R a+rX "$work"

docker network create --internal --label "$label" "$network" >/dev/null
test "$(docker network inspect -f '{{.Internal}}' "$network")" = true ||
  fail 'fixture network is not internal'
set --
# shellcheck disable=SC2086 # one host name per word
for host in fulcio.fixture.test rekor.fixture.test issuer.fixture.test $public_hosts; do
  set -- "$@" --network-alias "$host"
done
docker run -d --label "$label" --name "$fixture" --network "$network" "$@" --read-only \
  -v "$work/fixture.py:/fixture.py:ro" "$python" python -u /fixture.py >/dev/null
attempts=0
until docker logs "$fixture" 2>&1 | grep -Fx READY >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || { docker logs "$fixture" >&2; fail 'fixture did not become ready'; }
  sleep 1
done
# READY must mean listening: a refused first request would turn the Fulcio 503
# case into a connection error. A bare connect logs nothing in the fixture.
docker exec "$fixture" python -c 'import socket; socket.create_connection(("127.0.0.1", 80), 5).close()' ||
  { docker logs "$fixture" >&2; fail 'fixture reported READY before its HTTP listener accepted'; }
fixture_log() {
  docker logs "$fixture" >"$work/fixture.log" 2>&1
}

# Control: every public-good name resolves to the fixture on this network.
# shellcheck disable=SC2086 # one host name per word
docker exec "$fixture" python -c '
import socket, sys
own = socket.gethostbyname(socket.gethostname())
for host in sys.argv[1:]:
    if socket.gethostbyname(host) != own:
        sys.exit("%s does not resolve to the fixture" % host)
' $public_hosts || fail 'public-good names do not resolve to the fixture'

# Fulcio answers with an error: signing fails with that error.
sign "$work/sign-503" "$network" http://fulcio.fixture.test -e SIGSTORE_ID_TOKEN="$token"
expect_unsigned "$work/sign-503" 'signing against a failing Fulcio'
has "$work/sign-503" '503 Service Unavailable' 'Fulcio status is not reported'
has "$work/sign-503" 'verity fixture fulcio unavailable' 'Fulcio error body is not reported'

# Fulcio host is up but its port is closed: signing fails at once.
sign "$work/sign-refused" "$network" http://fulcio.fixture.test:9 -e SIGSTORE_ID_TOKEN="$token"
expect_unsigned "$work/sign-refused" 'signing against a closed Fulcio port'
has "$work/sign-refused" 'connection refused' 'refused Fulcio connection is not reported'

# Rekor has no entry for a correctly chained signature: verification fails.
verify "$work/v-no-entry" "$network" /work/pki/ca.pem --entrypoint /usr/bin/git "$image" verify-commit signed
has "$work/v-no-entry" 'could not find matching tlog entry' 'missing Rekor entry is not reported'
verify "$work/v-no-entry-legacy" "$network" /work/pki/ca.pem -e GITSIGN_ENABLE_SIGSTORE_GO=false \
  --entrypoint /usr/bin/git "$image" verify-commit signed
has "$work/v-no-entry-legacy" 'could not find matching tlog entry' \
  'legacy missing Rekor entry is not reported'

fixture_log
has "$work/fixture.log" 'HTTP fulcio.fixture.test POST /api/v1/signingCert' \
  'the configured Fulcio received no signing request'
has "$work/fixture.log" 'HTTP rekor.fixture.test POST /api/v1/index/retrieve' \
  'the configured Rekor received no lookup'
lacks "$work/fixture.log" sigstore.dev 'gitsign sent a request to a Sigstore public-good host'
lacks "$work/fixture.log" 'TLS ' 'gitsign opened a TLS connection to a public-good or unconfigured host'
lacks "$work/fixture.log" issuer.fixture.test 'a static identity token still contacted the OIDC issuer'

# Control: the TLS trap does record an HTTPS attempt.
sign "$work/sign-tls" "$network" https://fulcio.fixture.test -e SIGSTORE_ID_TOKEN="$token"
expect_unsigned "$work/sign-tls" 'signing against a TLS endpoint that resets'
fixture_log
has "$work/fixture.log" 'TLS ' 'the TLS trap did not record a connection'

printf 'SMOKE PASS image=%s\n' "$image"

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml" | head -n 1)
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/node"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = '' ] || fail 'unexpected OCI user'

# The image has no shell, so every assertion runs through the node entrypoint.
docker run --rm "$image" -e 'if (process.versions.node.split(".")[0] !== "22") process.exit(1)' ||
  fail 'node major is not 22'
version=$(docker run --rm "$image" -p process.versions.node)
[ "$version" = "$expected_version" ] || fail "node version $version != $expected_version"

# npm and corepack ship with the runtime and must run.
docker run --rm "$image" /usr/lib/node_modules/npm/bin/npm-cli.js --version >/dev/null || fail 'npm does not run'
docker run --rm "$image" /usr/lib/node_modules/corepack/dist/corepack.js --version >/dev/null || fail 'corepack does not run'
docker run --rm "$image" /usr/lib/node_modules/npm/bin/npm-cli.js ls --global --all >/dev/null ||
  fail 'npm global tree has invalid dependencies'
docker run --rm "$image" -e '
const { execFileSync } = require("child_process");
const fs = require("fs");
const dir = fs.mkdtempSync("/tmp/pack-");
fs.writeFileSync(dir + "/package.json", JSON.stringify({ name: "probe", version: "1.0.0" }));
const out = execFileSync(process.execPath, ["/usr/lib/node_modules/npm/bin/npm-cli.js", "pack", "--silent"], { cwd: dir }).toString().trim();
if (out !== "probe-1.0.0.tgz") { console.error("unexpected pack output: " + out); process.exit(1); }
' || fail 'npm pack failed'

# TLS: ICU, OpenSSL and the bundled root store must all work.
docker run --rm "$image" -e '
if (new Intl.NumberFormat("de-DE").format(1234.56) !== "1.234,56") process.exit(1);
require("crypto").createHash("sha256").update("x").digest("hex");
' || fail 'ICU or crypto is broken'

# Neither root store may carry the roots dropped from the 22.23 line (negative
# case). tls.rootCertificates is Node's compiled-in snapshot; the build uses
# --openssl-use-def-ca-store, so TLS verification trusts the system bundle in
# /etc/ssl/certs, which must be checked as well.
docker run --rm "$image" -e '
const fs = require("fs");
const tls = require("tls");
const { X509Certificate } = require("crypto");
const pems = {
  bundled: tls.rootCertificates,
  system: fs.readFileSync("/etc/ssl/certs/ca-certificates.crt", "utf8")
    .match(/-----BEGIN CERTIFICATE-----[^-]+-----END CERTIFICATE-----/g) || [],
};
for (const [store, list] of Object.entries(pems)) {
  const subjects = list.map((pem) => new X509Certificate(pem).subject);
  if (subjects.length < 100) { console.error(store + " root store too small: " + subjects.length); process.exit(2); }
  const banned = subjects.filter((s) => /^CN=(emSign ECC Root CA - G3|AAA Certificate Services)$/m.test(s));
  if (banned.length) { console.error("removed roots in " + store + " store:\n" + banned.join("\n")); process.exit(1); }
}
' || fail 'root store contains removed roots or is incomplete'

# Unsupported input is rejected with a non-zero status.
if docker run --rm "$image" --no-such-flag >/dev/null 2>&1; then
  fail 'unknown node flag was accepted'
fi

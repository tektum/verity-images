#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
recipe="$here/../melange.yaml"

id=$$
proxy="verity-l5d-proxy-$id"
work=$(mktemp -d)
lib=/usr/lib/linkerd
ee_mount=/var/run/linkerd/identity/end-entity
token_mount=/var/run/secrets/tokens/linkerd-identity-token
local_name=default.default.serviceaccount.identity.linkerd.cluster.local
svc_name=linkerd-identity.linkerd.serviceaccount.identity.linkerd.cluster.local
dst_name=linkerd-destination.linkerd.serviceaccount.identity.linkerd.cluster.local

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$proxy" 2>&1 | tail -n 40 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f "$proxy" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

var() {
  awk -v key="$1:" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$recipe"
}
proxy_version=$(var version)
linkerd2_version=$(var linkerd2-version)
[ -n "$proxy_version" ] || fail 'could not read package.version from the recipe'
[ -n "$linkerd2_version" ] || fail 'could not read vars.linkerd2-version from the recipe'
command -v openssl >/dev/null || fail 'openssl is required on the host to mint a test trust anchor'
command -v curl >/dev/null || fail 'curl is required on the host'

# OCI contract of cr.l5d.io/linkerd/proxy.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65534 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  "[\"$lib/linkerd2-proxy-identity\"]" || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" >"$work/env"
for kv in LINKERD2_PROXY_LOG=warn,linkerd=info LINKERD2_PROXY_LOG_FORMAT=plain \
  "LINKERD_CONTAINER_VERSION_OVERRIDE=edge-$linkerd2_version"; do
  grep -Fqx "$kv" "$work/env" || fail "image env lacks $kv"
done

run() {
  docker run --rm --network none --read-only --cap-drop=ALL "$@"
}

out=$(run --entrypoint /usr/bin/cat "$image" "$lib/linkerd2-proxy-version.txt") ||
  fail 'cannot read the proxy version file'
test "$out" = "v$proxy_version" || fail "proxy version file says '$out', want v$proxy_version"

# /bin/sleep backs the chart's waitBeforeExitSeconds preStop hook. Upstream
# ships no shell.
run --entrypoint /bin/sleep "$image" 0 || fail '/bin/sleep 0 failed'
if run --entrypoint /bin/sleep "$image" not-a-duration >"$work/sleep" 2>&1; then
  fail '/bin/sleep accepted an invalid interval'
fi
if run --entrypoint /bin/sh "$image" -c true >/dev/null 2>&1; then
  fail 'image unexpectedly ships /bin/sh'
fi

# Bundled tools.
# Upstream builds clap without its help feature, so probe --version and a
# readiness timeout against an absent proxy admin server instead of --help.
run --entrypoint "$lib/linkerd-await" "$image" --version >"$work/await" 2>&1 ||
  fail "linkerd-await --version failed: $(cat "$work/await")"
grep -Eq '^linkerd-await [0-9]+\.[0-9]+\.[0-9]+$' "$work/await" ||
  fail "unexpected linkerd-await version: $(cat "$work/await")"
if run --entrypoint "$lib/linkerd-await" "$image" --timeout=1s -- /usr/bin/true >"$work/await" 2>&1; then
  fail 'linkerd-await ran CMD although the proxy never became ready'
fi
grep -Fq 'failed to become ready within 1s timeout' "$work/await" ||
  fail "unexpected linkerd-await timeout output: $(cat "$work/await")"
run --entrypoint "$lib/linkerd2-network-validator" "$image" --help >"$work/validator" 2>&1 ||
  fail "network validator --help failed: $(cat "$work/validator")"
grep -Fq -- '--connect-addr' "$work/validator" || fail 'network validator help lacks --connect-addr'

# proxy-identity must fail fast without an end-entity directory or trust anchors.
if run "$image" >"$work/neg" 2>&1; then fail 'proxy-identity started without an identity dir'; fi
grep -Fq 'Invalid end-entity directory: no end entity directory specified' "$work/neg" ||
  fail "unexpected error without an identity dir: $(cat "$work/neg")"
if run -e LINKERD2_PROXY_IDENTITY_DIR=/nonexistent "$image" >"$work/neg" 2>&1; then
  fail 'proxy-identity accepted a missing identity dir'
fi
grep -Fq 'Invalid end-entity directory: stat /nonexistent' "$work/neg" ||
  fail "unexpected error for a missing identity dir: $(cat "$work/neg")"
if run -e LINKERD2_PROXY_IDENTITY_DIR=/run "$image" >"$work/neg" 2>&1; then
  fail 'proxy-identity started without trust anchors'
fi
grep -Fq "Failed to load trust anchors: 'LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS' must be set" "$work/neg" ||
  fail "unexpected error without trust anchors: $(cat "$work/neg")"

# A throwaway trust anchor, minted for this run only.
openssl ecparam -name prime256v1 -genkey -noout -out "$work/ca.key" 2>/dev/null
openssl req -x509 -new -key "$work/ca.key" -sha256 -days 1 \
  -subj '/CN=root.linkerd.cluster.local' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -out "$work/ca.pem" 2>/dev/null || fail 'could not mint a test trust anchor'
trust_anchors=$(cat "$work/ca.pem")
ee="$work/end-entity"
mkdir "$ee"
chmod 0777 "$ee"
printf 'not-a-real-token\n' >"$work/token"
chmod 0644 "$work/token"

# The injected sidecar's environment, pointed at unreachable control-plane
# addresses. The proxy still serves its admin listener while identity is pending.
# $1 is the identity dir mount suffix; the rest are extra docker run arguments.
start_proxy() {
  mount_mode=$1
  shift
  docker rm -f "$proxy" >/dev/null 2>&1 || true
  docker run -d --name "$proxy" --read-only --cap-drop=ALL -p 127.0.0.1::4191 \
    -v "$ee:$ee_mount$mount_mode" -v "$work/token:$token_mount:ro" \
    -e "LINKERD2_PROXY_IDENTITY_DIR=$ee_mount" \
    -e "LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS=$trust_anchors" \
    -e "LINKERD2_PROXY_IDENTITY_LOCAL_NAME=$local_name" \
    -e "LINKERD2_PROXY_IDENTITY_TOKEN_FILE=$token_mount" \
    -e LINKERD2_PROXY_IDENTITY_SVC_ADDR=127.0.0.1:8080 \
    -e "LINKERD2_PROXY_IDENTITY_SVC_NAME=$svc_name" \
    -e LINKERD2_PROXY_DESTINATION_SVC_ADDR=127.0.0.1:8086 \
    -e "LINKERD2_PROXY_DESTINATION_SVC_NAME=$dst_name" \
    -e LINKERD2_PROXY_POLICY_SVC_ADDR=127.0.0.1:8090 \
    -e "LINKERD2_PROXY_POLICY_SVC_NAME=$dst_name" \
    -e 'LINKERD2_PROXY_POLICY_WORKLOAD={"ns":"default","pod":"smoke"}' \
    -e LINKERD2_PROXY_ADMIN_LISTEN_ADDR=0.0.0.0:4191 \
    -e LINKERD2_PROXY_CONTROL_LISTEN_ADDR=0.0.0.0:4190 \
    -e LINKERD2_PROXY_INBOUND_LISTEN_ADDR=0.0.0.0:4143 \
    -e LINKERD2_PROXY_OUTBOUND_LISTEN_ADDR=127.0.0.1:4140 \
    "$@" "$image" >/dev/null || fail 'could not start the proxy container'
  port=''
  i=0
  while [ "$i" -lt 30 ] && [ -z "$port" ]; do
    port=$(docker port "$proxy" 4191/tcp 2>/dev/null | awk -F: 'NR == 1 { print $NF }')
    [ -n "$port" ] || sleep 1
    i=$((i + 1))
  done
  [ -n "$port" ] || fail 'admin port was not published'
  i=0
  until live=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/live"); do
    i=$((i + 1))
    [ "$i" -lt 120 ] || fail 'admin /live never answered'
    [ "$(docker inspect --format '{{.State.Running}}' "$proxy")" = true ] ||
      fail 'proxy container exited'
    sleep 1
  done
  test "$live" = live || fail "unexpected /live body: $live"
}

check_admin() {
  curl --fail --silent --max-time 10 "http://127.0.0.1:$port/metrics" >"$work/metrics" ||
    fail '/metrics failed'
  grep '^proxy_build_info{' "$work/metrics" >"$work/build_info" ||
    fail '/metrics has no proxy_build_info'
  for label in "version=\"$proxy_version\"" 'vendor="tektum"' 'profile="release"'; do
    grep -Fq "$label" "$work/build_info" || fail "proxy_build_info lacks $label: $(cat "$work/build_info")"
  done
  grep -q '^process_start_time_seconds' "$work/metrics" || fail '/metrics has no process metrics'
  # No identity service answers, so the proxy must report itself not ready.
  code=$(curl --silent --output "$work/ready" --write-out '%{http_code}' --max-time 10 \
    "http://127.0.0.1:$port/ready") || fail '/ready did not answer'
  test "$code" = 503 || fail "/ready returned $code before identity was issued"
  grep -Fqx 'not ready' "$work/ready" || fail "unexpected /ready body: $(cat "$work/ready")"
}

# Entrypoint path: proxy-identity writes key and CSR, then execs the proxy.
start_proxy ''
check_admin
test -e "$ee/key.p8" || fail 'proxy-identity did not write key.p8'
test -e "$ee/csr.der" || fail 'proxy-identity did not write csr.der'
docker logs "$proxy" >"$work/logs" 2>&1
grep -Fq 'Admin interface on 0.0.0.0:4191' "$work/logs" ||
  fail 'the proxy did not log its admin listener after proxy-identity exec'
run -v "$ee:/ee:ro" --entrypoint /usr/bin/cat "$image" /ee/csr.der >"$work/csr.der" ||
  fail 'cannot read the CSR'
openssl req -inform DER -in "$work/csr.der" -noout -verify -subject >"$work/csr" 2>&1 ||
  fail "CSR does not verify: $(cat "$work/csr")"
grep -Fq "CN=$local_name" "$work/csr" || grep -Fq "CN = $local_name" "$work/csr" ||
  fail "CSR subject is not $local_name: $(cat "$work/csr")"
docker rm -f "$proxy" >/dev/null

# The proxy binary directly, reusing the identity documents read-only.
start_proxy :ro --entrypoint "$lib/linkerd2-proxy"
check_admin
docker rm -f "$proxy" >/dev/null

# Identity can no longer be disabled; the proxy must refuse to start. The proxy
# validates destination and policy settings first, so those are supplied.
if run -e LINKERD2_PROXY_IDENTITY_DISABLED=true \
  -e LINKERD2_PROXY_DESTINATION_SVC_ADDR=127.0.0.1:8086 -e "LINKERD2_PROXY_DESTINATION_SVC_NAME=$dst_name" \
  -e LINKERD2_PROXY_POLICY_SVC_ADDR=127.0.0.1:8090 -e "LINKERD2_PROXY_POLICY_SVC_NAME=$dst_name" \
  -e 'LINKERD2_PROXY_POLICY_WORKLOAD={"ns":"default","pod":"smoke"}' \
  --entrypoint "$lib/linkerd2-proxy" "$image" >"$work/neg" 2>&1; then
  fail 'proxy started with identity disabled'
fi
grep -Fq 'LINKERD2_PROXY_IDENTITY_DISABLED is no longer supported' "$work/neg" ||
  fail "unexpected error with identity disabled: $(cat "$work/neg")"

# linkerd-init runs proxy-init from this image as 65534 with NET_ADMIN and
# NET_RAW added and privilege escalation disabled; the file capabilities on
# proxy-init and on the xtables binaries it runs by name carry those into each
# exec. Upstream's setcap paths are /usr/sbin; iptables-xtables-privileged
# ships them capable, and merged-sbin resolves /usr/sbin to /usr/bin.
xt=/usr/sbin
docker run --rm --entrypoint /usr/bin/getcap "$image" \
  "$lib/linkerd2-proxy-init" "$xt/xtables-legacy-multi" "$xt/xtables-nft-multi" >"$work/caps" ||
  fail 'getcap failed'
for file in "$lib/linkerd2-proxy-init" "$xt/xtables-legacy-multi" "$xt/xtables-nft-multi"; do
  grep -Fqx "$file cap_net_admin,cap_net_raw=eip" "$work/caps" ||
    fail "$file lacks cap_net_admin,cap_net_raw=eip: $(cat "$work/caps")"
done
for name in iptables-legacy iptables-legacy-save iptables-legacy-restore iptables-nft iptables-nft-save \
  iptables-nft-restore ip6tables-legacy ip6tables-nft iptables iptables-save; do
  target=$(run --entrypoint /usr/bin/readlink "$image" -f "$xt/$name") ||
    fail "$xt/$name is missing"
  case "$target" in
    */xtables-legacy-multi | */xtables-nft-multi) ;;
    *) fail "$xt/$name resolves to $target, not a capable xtables binary" ;;
  esac
done

init() {
  docker run --rm --read-only --tmpfs /run --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW \
    --security-opt no-new-privileges "$@"
}
# The capable xtables binaries come from iptables' own subpackage; they must
# match the iptables package whose libraries and extensions they load.
run --entrypoint /usr/bin/cat "$image" /lib/apk/db/installed >"$work/installed" ||
  fail 'cannot read the apk database'
iptables_version=$(awk -F: '$1 == "P" { p = $2 } $1 == "V" && p == "iptables" { sub(/-r[0-9]+$/, "", $2); print $2 }' \
  "$work/installed")
[ -n "$iptables_version" ] || fail 'iptables is not installed'
privileged_version=$(awk -F: '$1 == "P" { p = $2 } $1 == "V" && p == "iptables-xtables-privileged" {
  sub(/-r[0-9]+$/, "", $2); print $2 }' "$work/installed")
[ "$privileged_version" = "$iptables_version" ] ||
  fail "iptables-xtables-privileged '$privileged_version' does not match iptables $iptables_version"
for mode in legacy:legacy nft:nf_tables; do
  backend=${mode#*:}
  mode=${mode%%:*}
  # A bare entrypoint resolves through the image PATH, as proxy-init's lookup does.
  init --network none --entrypoint "iptables-$mode" "$image" --version \
    >"$work/iptables" 2>&1 || fail "iptables-$mode --version failed: $(cat "$work/iptables")"
  grep -Fqx "iptables v$iptables_version ($backend)" "$work/iptables" ||
    fail "iptables-$mode is not the installed iptables $iptables_version: $(cat "$work/iptables")"
done
init --network none --entrypoint "$lib/linkerd2-proxy-init" "$image" --help >"$work/init" 2>&1 ||
  fail "proxy-init --help failed: $(cat "$work/init")"
grep -Fq -- '--firewall-bin-path' "$work/init" || fail 'proxy-init help lacks --firewall-bin-path'

# qemu-user neither applies file capabilities nor runs iptables, so exercise
# them only on the native architecture; the other row checks the xattrs above.
image_arch=$(docker image inspect --format '{{.Architecture}}' "$image")
host_arch=$(docker version --format '{{.Server.Arch}}')
if [ "$image_arch" = "$host_arch" ]; then
  # Without NET_ADMIN in the bounding set the kernel refuses the capability exec.
  if run --entrypoint "$lib/linkerd2-proxy-init" "$image" --help >"$work/neg" 2>&1; then
    fail 'proxy-init ran without NET_ADMIN and NET_RAW in the bounding set'
  fi
  init --entrypoint "$lib/linkerd2-proxy-init" "$image" \
    --firewall-bin-path iptables-nft --firewall-save-bin-path iptables-nft-save --ipv6=false \
    --incoming-proxy-port 4143 --outgoing-proxy-port 4140 --proxy-uid 2102 \
    --inbound-ports-to-ignore 4190,4191 >"$work/init" 2>&1 ||
    fail "proxy-init could not program iptables as 65534: $(cat "$work/init")"
  grep -Fq 'PROXY_INIT_REDIRECT' "$work/init" || fail "proxy-init installed no redirect chain: $(cat "$work/init")"
  grep -Fq -- '--to-ports 4143' "$work/init" || fail 'proxy-init did not redirect inbound to 4143'
else
  printf 'SKIP: capability exec and iptables on non-native %s (host %s)\n' "$image_arch" "$host_arch"
fi

printf 'SMOKE PASS image=%s\n' "$image"

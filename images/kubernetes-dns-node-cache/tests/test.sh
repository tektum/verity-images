#!/bin/sh
# Smoke test for the k8s-dns-node-cache image.
#
# node-cache normally runs privileged on the host network: it creates the
# "nodelocaldns" dummy interface over rtnetlink (RTM_NEWLINK, EPERM without
# CAP_NET_ADMIN) and installs iptables NOTRACK/ACCEPT rules in the raw and
# filter tables (nf_tables netlink, "Permission denied (you must be root)"
# without CAP_NET_ADMIN). Port 53 also needs CAP_NET_BIND_SERVICE.
# With -setupinterface=false -setupiptables=false -skipteardown and a high
# port the cache needs no capability at all. This test:
# - checks the image contract and the upstream runtime tools (iptables-wrapper,
#   ipset, nft, kmod);
# - rejects invalid flags and Corefiles;
# - serves DNS as uid 65532 with every capability dropped from the upstream
#   Corefile template and a kube-dns ConfigMap, forwarding to a mock upstream,
#   and queries it with dig from another container;
# - shows the default mode failing without privileges, then working with only
#   CAP_NET_ADMIN and CAP_NET_BIND_SERVICE in a private network namespace.
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$here/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }

suffix="$$-$(date +%s)"
network="verity-node-cache-test-$suffix"
upstream="verity-node-cache-upstream-$suffix"
cache="verity-node-cache-cache-$suffix"
priv="verity-node-cache-priv-$suffix"
holder="verity-node-cache-netns-$suffix"
full="verity-node-cache-full-$suffix"
reject="verity-node-cache-reject-$suffix"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$cache" "$upstream" "$priv" "$reject" "$full" "$holder" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for c in "$cache" "$upstream" "$priv" "$full"; do
    if docker inspect "$c" >/dev/null 2>&1; then
      printf '%s\n' "--- logs $c" >&2
      docker logs "$c" >&2 2>&1 || true
    fi
  done
  exit 1
}

# DNS client and mock upstream: this project's CoreDNS image (CoreDNS plus
# bind-tools dig), pinned by index digest and pulled by its per-platform child.
coredns_index=ghcr.io/tektum/coredns@sha256:efa6111f5e1daabd2c273812638c4ea6a3dbfc2466c76ec31d915e0d94541b1e
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
# On the non-native arch the image runs under qemu-user, where iptables cannot
# talk to netfilter: it exits 1 without printing anything, so permission and
# rule-installation checks only hold on the native arch.
case "$(uname -m)" in
  x86_64) host_arch=amd64 ;;
  aarch64 | arm64) host_arch=arm64 ;;
  *) host_arch=$(uname -m) ;;
esac
emulated=false
[ "$image_arch" = "$host_arch" ] || emulated=true
pull_child() {
  raw=$(docker buildx imagetools inspect --raw "$1") || fail "cannot inspect $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] ||
    fail "index digest mismatch for $1"
  child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail "cannot resolve a child of $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $1" ;;
  esac
  docker pull --quiet --platform "linux/$image_arch" "${1%%@*}@$child" >/dev/null ||
    fail "cannot pull ${1%%@*}@$child"
  printf '%s' "${1%%@*}@$child"
}

# dig from another container that shares the cache's network namespace, as a
# hostNetwork client on the node would reach the link-local listen address.
dig_at() {
  server=$1
  shift
  docker run --rm --network "container:$cache" --user 65532:65532 --cap-drop=ALL \
    --read-only --security-opt no-new-privileges --entrypoint dig "$coredns_image" \
    -p 5353 "@$server" +time=2 +tries=1 "$@"
}

# lookup NAME: prints the A records the cache answers with.
lookup() {
  dig_at 127.0.0.1 +short "$1" A 2>&1
}

# ---------------------------------------------------------------- image contract
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/node-cache"]' ||
  fail 'entrypoint is not ["/node-cache"]'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = 'null' ||
  fail 'image must not set a default command'
user=$(docker image inspect --format '{{.Config.User}}' "$image")
case "$user" in
  0 | 0:0 | root | '') ;;
  *) fail "image user is $user, upstream runs as root" ;;
esac

# Runtime tools the upstream distroless-iptables base ships. The version check uses
# iptables-legacy: iptables-wrapper probes the host netfilter backend first, and that
# probe fails without a kernel backend (nft under qemu-user on the non-native arch).
docker run --rm --network none --entrypoint iptables-legacy "$image" --version >"$work/ipt" 2>&1 ||
  fail "iptables-legacy --version failed: $(cat "$work/ipt")"
grep -Eq '^iptables v1\.[0-9]+' "$work/ipt" || fail "unexpected iptables version: $(cat "$work/ipt")"
for tool in iptables ip6tables iptables-save iptables-restore ip6tables-save ip6tables-restore; do
  target=$(docker run --rm --network none --entrypoint /bin/busybox "$image" readlink "/usr/bin/$tool") ||
    fail "$tool is missing"
  [ "$target" = iptables-wrapper ] || fail "$tool points to $target, not iptables-wrapper"
done
# ipset and nft open netlink even for their version output, which fails under qemu-user
# on the non-native arch, so these are presence checks only (as in images/flannel).
for tool in iptables-legacy iptables-nft ip6tables-legacy ip6tables-nft iptables-legacy-save iptables-nft-save \
  ipset nft; do
  docker run --rm --network none --entrypoint /bin/sh "$image" -c "command -v $tool" >/dev/null ||
    fail "$tool is missing"
done
docker run --rm --network none --entrypoint kmod "$image" --version 2>&1 | grep -q '^kmod version' ||
  fail 'kmod is missing'

docker run --rm --network none "$image" -help >"$work/help" 2>&1 || fail "-help failed: $(cat "$work/help")"
for flag in -localip -setupinterface -setupiptables -skipteardown -basecorefile -kubednscm -conf -dns.port; do
  grep -Fq -- "$flag" "$work/help" || fail "-help does not list $flag"
done
grep -Fq 'as a nodelocal cache' "$work/help" || fail '-help lacks the node-cache usage line'

# --------------------------------------------------- invalid flags and config
# Run the image with no capabilities as a non-root user on a read-only root.
run_unprivileged() {
  docker run --user 65532:65532 --cap-drop=ALL --read-only --security-opt no-new-privileges "$@"
}

# Flags that turn off every privileged operation: no dummy interface, no
# iptables rules, nothing to tear down, and no node-cache Corefile template.
# They are spelled out on each command so the arguments stay quoted.

expect_reject() {
  name=$1 pattern=$2
  shift 2
  rc=0
  # A config that is wrongly accepted keeps serving; bound the wait so the
  # test fails instead of hanging.
  timeout 60 docker run --rm --name "$reject" --network none --user 65532:65532 --cap-drop=ALL \
    --read-only --security-opt no-new-privileges "$@" >"$work/reject" 2>&1 || rc=$?
  docker rm -f "$reject" >/dev/null 2>&1 || true
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] || fail "$name was accepted (exit $rc)"
  grep -Eq -- "$pattern" "$work/reject" || fail "$name: missing '$pattern' in: $(cat "$work/reject")"
}

expect_reject 'invalid -localip' 'invalid localip specified - "not-an-ip"' \
  "$image" -skipteardown -setupinterface=false -setupiptables=false \
    -basecorefile /nonexistent/Corefile.base -localip not-an-ip
expect_reject 'mixed IP families' 'unexpected IP Family' \
  "$image" -skipteardown -setupinterface=false -setupiptables=false \
    -basecorefile /nonexistent/Corefile.base -localip 127.0.0.1,::1
expect_reject 'non-numeric -health-port' 'invalid healthcheck port' \
  "$image" -skipteardown -setupinterface=false -setupiptables=false \
    -basecorefile /nonexistent/Corefile.base -localip 127.0.0.1 -health-port http

cat >"$work/bad-directive" <<'EOF'
.:5353 {
    bind 127.0.0.1
    definitely-not-a-plugin
}
EOF
cat >"$work/bad-plugin" <<'EOF'
.:5353 {
    bind 127.0.0.1
    kubernetes cluster.local
}
EOF
cat >"$work/bad-syntax" <<'EOF'
.:5353 {
    bind 127.0.0.1
    forward . 192.0.2.1 {
EOF
chmod 644 "$work"/bad-*
expect_reject 'unknown Corefile directive' 'Unknown directive .definitely-not-a-plugin' \
  -v "$work/bad-directive:/etc/Corefile:ro" "$image" -skipteardown -setupinterface=false -setupiptables=false \
    -basecorefile /nonexistent/Corefile.base -localip 127.0.0.1 -conf /etc/Corefile
# node-cache compiles in only the plugins upstream lists in cmd/node-cache/main.go.
expect_reject 'plugin not built into node-cache' 'no action found for directive .kubernetes.' \
  -v "$work/bad-plugin:/etc/Corefile:ro" "$image" -skipteardown -setupinterface=false -setupiptables=false \
    -basecorefile /nonexistent/Corefile.base -localip 127.0.0.1 -conf /etc/Corefile
expect_reject 'unterminated Corefile block' 'Unexpected EOF' \
  -v "$work/bad-syntax:/etc/Corefile:ro" "$image" -skipteardown -setupinterface=false -setupiptables=false \
    -basecorefile /nonexistent/Corefile.base -localip 127.0.0.1 -conf /etc/Corefile
expect_reject 'missing Corefile' 'no such file or directory' \
  "$image" -skipteardown -setupinterface=false -setupiptables=false \
    -basecorefile /nonexistent/Corefile.base -localip 127.0.0.1 -conf /nonexistent/Corefile

# ------------------------------------------------------------ mock upstream
coredns_image=$(pull_child "$coredns_index")
docker network create "$network" >/dev/null

mkdir -p "$work/upstream" "$work/coredns" "$work/kube-dns"
cat >"$work/upstream/Corefile" <<'EOF'
cluster.local:1053 {
    log
    hosts {
        192.0.2.10 svc.ns.svc.cluster.local
    }
}
stub.test:1053 {
    log
    hosts {
        192.0.2.20 host.stub.test
    }
}
www.example.test:1053 {
    log
    template IN A {
        answer "{{ .Name }} 60 IN A 192.0.2.30"
    }
}
.:1053 {
    log
    template ANY ANY {
        rcode NXDOMAIN
    }
}
EOF
chmod -R a+rX "$work"
# The CoreDNS binary carries a cap_net_bind_service file capability, so it
# cannot exec with every capability dropped; it keeps Docker's defaults.
docker run -d --name "$upstream" --network "$network" --read-only \
  -v "$work/upstream/Corefile:/Corefile:ro" "$coredns_image" -conf /Corefile >/dev/null
upstream_ip=$(docker inspect --format "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" "$upstream")
[ -n "$upstream_ip" ] || fail 'mock upstream has no IP address'
i=0
until docker logs "$upstream" 2>&1 | grep -q '^CoreDNS-'; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'mock upstream never started'
  [ "$(docker inspect --format '{{.State.Running}}' "$upstream")" = true ] || fail 'mock upstream exited'
  sleep 1
done

# --------------------------------------------- node-cache, unprivileged
# Base Corefile in the shape of upstream's nodelocaldns.yaml template; node-cache
# substitutes the __PILLAR__ variables, takes upstream servers and stub domains
# from the kube-dns ConfigMap directory, and writes the effective Corefile.
cat >"$work/coredns/Corefile.base" <<'EOF'
cluster.local:5353 {
    errors
    cache {
        success 9984 30
        denial 9984 5
    }
    reload
    loop
    bind __PILLAR__LOCAL__DNS__ __PILLAR__DNS__SERVER__
    forward . __PILLAR__CLUSTER__DNS__:1053 {
        force_tcp
    }
    prometheus 127.0.0.1:9253
    health 127.0.0.1:8080
}
.:5353 {
    errors
    cache 30
    reload
    loop
    bind __PILLAR__LOCAL__DNS__ __PILLAR__DNS__SERVER__
    forward . __PILLAR__UPSTREAM__SERVERS__ {
            force_tcp
    }
    prometheus 127.0.0.1:9253
}
EOF
printf '["%s:1053"]\n' "$upstream_ip" >"$work/kube-dns/upstreamNameservers"
printf '{"stub.test": ["%s:1053"]}\n' "$upstream_ip" >"$work/kube-dns/stubDomains"
chmod -R a+rX "$work"

run_unprivileged -d --name "$cache" --network "$network" \
  --tmpfs /run/node-cache:uid=65532,gid=65532,mode=0755 \
  -e KUBE_DNS_SERVICE_HOST="$upstream_ip" \
  -v "$work/coredns:/etc/coredns:ro" -v "$work/kube-dns:/etc/kube-dns:ro" \
  "$image" -skipteardown -setupinterface=false -setupiptables=false \
  -localip 127.0.0.1 -dns.port 5353 -health-port 8080 \
  -metrics-listen-address 127.0.0.1:9353 \
  -basecorefile /etc/coredns/Corefile.base -kubednscm /etc/kube-dns \
  -conf /run/node-cache/Corefile >/dev/null

ready=0
i=0
while [ "$i" -lt 30 ]; do
  [ "$(docker inspect --format '{{.State.Running}}' "$cache")" = true ] || fail 'node-cache exited'
  if docker logs "$cache" 2>&1 | grep -q '^CoreDNS-'; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$ready" = 1 ] || fail 'node-cache never started CoreDNS'

docker logs "$cache" >"$work/cache.log" 2>&1
grep -Fq "Starting node-cache image: $expected_version" "$work/cache.log" ||
  fail "startup log does not report version $expected_version"
if grep -E '\[(ERROR|FATAL)\]' "$work/cache.log" >"$work/errors"; then
  fail "node-cache logged errors: $(cat "$work/errors")"
fi

# Rendered Corefile: variables substituted, upstreams switched to kube-dns
# upstreamNameservers over UDP, stub domain block appended.
docker exec "$cache" /bin/busybox cat /run/node-cache/Corefile >"$work/rendered" ||
  fail 'rendered Corefile missing'
if grep -q __PILLAR__ "$work/rendered"; then fail "unsubstituted variables: $(cat "$work/rendered")"; fi
grep -Fq "forward . $upstream_ip:1053 {" "$work/rendered" || fail 'cluster DNS IP not substituted'
grep -Fxq "    forward . $upstream_ip:1053" "$work/rendered" || fail 'upstreamNameservers not rendered as UDP forward'
grep -Fxq 'stub.test:5353 {' "$work/rendered" || fail 'stub domain block missing'
grep -Fxq '    bind 127.0.0.1' "$work/rendered" || fail 'stub domain not bound to -localip'

# The running node-cache process is uid 65532 with no effective capabilities.
docker exec "$cache" /bin/busybox cat /proc/1/status >"$work/status"
[ "$(awk '/^CapEff:/ { print $2 }' "$work/status")" = 0000000000000000 ] ||
  fail "node-cache has capabilities: $(grep ^Cap "$work/status")"
[ "$(awk '/^Uid:/ { print $3 }' "$work/status")" = 65532 ] || fail 'node-cache is not running as uid 65532'

# ------------------------------------------------------------- DNS answers
i=0
until [ "$(lookup svc.ns.svc.cluster.local)" = 192.0.2.10 ]; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || fail "cluster.local answer was '$(lookup svc.ns.svc.cluster.local)'"
  sleep 1
done
answer=$(lookup host.stub.test)
[ "$answer" = 192.0.2.20 ] || fail "stub domain answer was '$answer'"
answer=$(lookup www.example.test)
[ "$answer" = 192.0.2.30 ] || fail "upstream answer was '$answer'"
dig_at 127.0.0.1 missing.example.test A >"$work/nx" 2>&1 || true
grep -Fq 'status: NXDOMAIN' "$work/nx" || fail "missing name did not return NXDOMAIN: $(cat "$work/nx")"
# The cache only listens on -localip: the container's network address is closed.
cache_ip=$(docker inspect --format "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" "$cache")
if dig_at "$cache_ip" +short svc.ns.svc.cluster.local A >"$work/other" 2>&1 &&
  grep -q 192.0.2.10 "$work/other"; then
  fail "node-cache answered on $cache_ip, outside -localip"
fi

# A repeated query is served from the cache, not forwarded again.
answer=$(lookup svc.ns.svc.cluster.local)
[ "$answer" = 192.0.2.10 ] || fail "cached cluster.local answer was '$answer'"
forwarded=$(docker logs "$upstream" 2>&1 | grep -c '"A IN svc.ns.svc.cluster.local. tcp ' || true)
[ "$forwarded" = 1 ] || fail "upstream saw $forwarded TCP A queries for the cached name, want 1"
# Upstream servers from the kube-dns ConfigMap are used over UDP.
docker logs "$upstream" 2>&1 | grep -q '"A IN www.example.test. udp ' ||
  fail 'www.example.test was not forwarded over UDP'

docker stop "$cache" >/dev/null
rc=$(docker inspect --format '{{.State.ExitCode}}' "$cache")
[ "$rc" = 0 ] || fail "node-cache exited $rc on SIGTERM"

# ------------------------------- default (privileged) mode without privileges
# Without CAP_NET_ADMIN the default flags fail exactly where upstream needs
# privileges: rtnetlink RTM_NEWLINK for the dummy interface returns EPERM and
# iptables cannot open its tables. node-cache logs and counts the errors.
run_unprivileged -d --name "$priv" --network none \
  -v "$work/upstream/Corefile:/etc/Corefile:ro" \
  "$image" -localip 169.254.20.10 -syncinterval 1ns -basecorefile /nonexistent/Corefile.base \
  -metrics-listen-address 127.0.0.1:9353 -conf /etc/Corefile >/dev/null
i=0
until docker logs "$priv" 2>&1 | grep -q 'Error checking/adding iptables rule'; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'unprivileged default mode did not report the iptables failure'
  [ "$(docker inspect --format '{{.State.Running}}' "$priv")" = true ] ||
    fail 'unprivileged default mode exited instead of logging setup errors'
  sleep 1
done
docker logs "$priv" >"$work/priv.log" 2>&1
grep -Eq 'Failed to add non-existent interface nodelocaldns: operation not permitted' "$work/priv.log" ||
  fail 'unprivileged default mode did not report EPERM for the dummy interface'
if [ "$emulated" = true ]; then
  # qemu-user: iptables exits 1 silently, so node-cache only reports the status.
  grep -Eq 'Permission denied|you must be root|error checking rule: exit status 1' "$work/priv.log" ||
    fail 'iptables failure was neither a permission error nor the qemu-user exit status'
else
  grep -Eq 'Permission denied|you must be root' "$work/priv.log" ||
    fail 'iptables failure was not a permission error'
fi

docker rm -f "$priv" >/dev/null

# ------------------------- default mode with CAP_NET_ADMIN in a private netns
# The upstream contract: on a private network namespace with only
# CAP_NET_ADMIN (interface and iptables) and CAP_NET_BIND_SERVICE (port 53),
# node-cache creates the nodelocaldns dummy interface holding -localip,
# installs its NOTRACK/ACCEPT rules through iptables-wrapper, serves on
# 169.254.20.10:53, and removes both again on SIGTERM. A holder container owns
# the namespace so the teardown can be observed after node-cache exits.
cat >"$work/full-Corefile" <<'EOF'
.:53 {
    bind 169.254.20.10
    template IN A probe.test {
        answer "{{ .Name }} 60 IN A 192.0.2.99"
    }
}
EOF
chmod 644 "$work/full-Corefile"
docker run -d --name "$holder" --network none --read-only --cap-drop=ALL --cap-add NET_ADMIN \
  --entrypoint /bin/busybox "$image" sleep 600 >/dev/null
docker run -d --name "$full" --network "container:$holder" --read-only --cap-drop=ALL \
  --cap-add NET_ADMIN --cap-add NET_BIND_SERVICE -v "$work/full-Corefile:/etc/Corefile:ro" \
  "$image" -localip 169.254.20.10 -syncinterval 1ns -conf /etc/Corefile \
  -basecorefile /nonexistent/Corefile.base >/dev/null
rules() {
  docker exec "$holder" iptables-save | grep -c 'NodeLocal DNS Cache' || true
}
i=0
# Under qemu-user iptables cannot install rules (see emulated above); the
# interface, serving and teardown checks still run there.
until [ "$emulated" = true ] || [ "$(rules)" -ge 12 ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail "node-cache installed $(rules) iptables rules, want 12"
  [ "$(docker inspect --format '{{.State.Running}}' "$full")" = true ] || fail 'privileged node-cache exited'
  sleep 1
done
i=0
until docker exec "$holder" /bin/busybox test -e /sys/class/net/nodelocaldns; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'nodelocaldns interface was not created'
  sleep 1
done
if [ "$emulated" = false ]; then
  docker exec "$holder" iptables-save -t raw >"$work/raw"
  grep -Eq -- '-A PREROUTING -d 169.254.20.10/32 -p udp .*--dport 53 .*-j NOTRACK' "$work/raw" ||
    fail "raw PREROUTING NOTRACK rule missing: $(cat "$work/raw")"
fi
answer=$(docker run --rm --network "container:$holder" --user 65532:65532 --cap-drop=ALL --read-only \
  --entrypoint dig "$coredns_image" @169.254.20.10 +time=2 +tries=3 +short probe.test A 2>&1) || true
[ "$answer" = 192.0.2.99 ] || fail "privileged node-cache answer was '$answer'"
docker logs "$full" >"$work/full.log" 2>&1
setup_errors='iptables|dummy device|interface nodelocaldns'
[ "$emulated" = false ] || setup_errors='dummy device|interface nodelocaldns'
if grep -E "$setup_errors" "$work/full.log" | grep -q ERROR; then
  fail "privileged node-cache reported setup errors: $(grep ERROR "$work/full.log")"
fi
docker stop "$full" >/dev/null
[ "$emulated" = true ] || [ "$(rules)" = 0 ] || fail "$(rules) iptables rules left after teardown"
if docker exec "$holder" /bin/busybox test -e /sys/class/net/nodelocaldns; then
  fail 'nodelocaldns interface left after teardown'
fi

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"

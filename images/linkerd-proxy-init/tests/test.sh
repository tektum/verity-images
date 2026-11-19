#!/bin/sh
# Smoke test for the linkerd-proxy-init image.
#
# proxy-init is the Linkerd init container: it installs nat-table rules that
# redirect a pod's TCP traffic to the proxy. Like upstream
# cr.l5d.io/linkerd/proxy-init it runs as uid 65534, and /usr/local/bin/proxy-init,
# xtables-legacy-multi and xtables-nft-multi carry cap_net_admin,cap_net_raw+eip.
# The kernel refuses to execute such a file (EPERM) unless both capabilities are
# in the bounding set, so without NET_ADMIN and NET_RAW the container does not
# start at all. This test:
# - checks the image contract and the iptables/ip6tables legacy and nft tools;
# - checks --help and --simulate, and rejects invalid flag values;
# - shows the redirect setup failing with every capability dropped (on the
#   entrypoint, and on a capability-free copy of proxy-init where the iptables
#   step itself is refused);
# - installs the redirect rules with only NET_ADMIN and NET_RAW, as uid 65534
#   with no-new-privileges, in a private container network namespace (legacy
#   and nft), and reads them back with iptables-save.
# The privileged host path (a real pod or node network namespace) is not
# exercised.
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$here/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }

suffix="$$-$(date +%s)"
holder="verity-proxy-init-netns-$suffix"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$holder" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# On the non-native arch the image runs under qemu-user, where iptables cannot
# talk to netfilter and file capabilities depend on the binfmt credentials
# flag, so rule installation and the exact permission errors only hold natively.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
case "$(uname -m)" in
  x86_64) host_arch=amd64 ;;
  aarch64 | arm64) host_arch=arm64 ;;
  *) host_arch=$(uname -m) ;;
esac
emulated=false
[ "$image_arch" = "$host_arch" ] || emulated=true

# The capabilities proxy-init needs: CAP_NET_ADMIN and CAP_NET_RAW, as the
# Linkerd injector grants them, with no-new-privileges
# (allowPrivilegeEscalation: false) and a read-only root.
run_capable() {
  docker run --rm --cap-drop=ALL --cap-add NET_ADMIN --cap-add NET_RAW \
    --security-opt no-new-privileges --read-only "$@"
}

# ---------------------------------------------------------------- image contract
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/local/bin/proxy-init"]' ||
  fail 'entrypoint is not ["/usr/local/bin/proxy-init"]'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = 'null' ||
  fail 'image must not set a default command'
user=$(docker image inspect --format '{{.Config.User}}' "$image")
case "$user" in
  65534 | 65534:65534) ;;
  *) fail "image user is '$user', upstream runs as 65534" ;;
esac
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' >/dev/null ||
  fail 'PATH differs from upstream'

sh_in() {
  docker run --rm --network none --entrypoint /bin/sh "$image" -c "$1"
}
[ "$(sh_in 'id -u'):$(sh_in 'id -g')" = 65534:65534 ] || fail 'default user is not 65534:65534'
# iptables-legacy takes /run/xtables.lock, which uid 65534 cannot create.
[ "$(sh_in 'stat -c %a:%u:%g /run/xtables.lock')" = 666:0:0 ] ||
  fail "/run/xtables.lock is not root-owned mode 666: $(sh_in 'ls -l /run/xtables.lock' 2>&1)"
# proxy-init runs these by name: iptables-mode legacy (the default), nft and
# plain, each for IPv4 and IPv6, plus sysctl and nsenter.
for tool in iptables iptables-save ip6tables ip6tables-save \
  iptables-legacy iptables-legacy-save ip6tables-legacy ip6tables-legacy-save \
  iptables-nft iptables-nft-save ip6tables-nft ip6tables-nft-save sysctl nsenter; do
  sh_in "command -v $tool" >/dev/null || fail "$tool is missing"
done
for tool in iptables-legacy iptables-nft ip6tables-legacy ip6tables-nft; do
  case $tool in
    *-legacy) variant=legacy ;;
    *) variant=nf_tables ;;
  esac
  # The nft backend opens a netlink socket even for --version, which
  # qemu-user does not emulate ("Protocol not supported").
  if [ "$emulated" = true ] && [ "$variant" = nf_tables ]; then
    printf 'SKIP: %s --version under qemu-user (%s image on %s host)\n' "$tool" "$image_arch" "$host_arch"
    continue
  fi
  run_capable --network none --entrypoint "$tool" "$image" --version >"$work/version" 2>&1 ||
    fail "$tool --version failed: $(cat "$work/version")"
  grep -Eq "^ip6?tables v1\.[0-9.]+ \($variant\)" "$work/version" ||
    fail "unexpected $tool version: $(cat "$work/version")"
done

# ------------------------------------------------------------- help and flags
run_capable --network none "$image" --help >"$work/help" 2>&1 || fail "--help failed: $(cat "$work/help")"
grep -Fq 'proxy-init adds a Kubernetes pod to the Linkerd service mesh' "$work/help" ||
  fail "--help lacks the proxy-init description: $(cat "$work/help")"
for flag in --incoming-proxy-port --outgoing-proxy-port --proxy-uid --proxy-gid --ports-to-redirect \
  --inbound-ports-to-ignore --outbound-ports-to-ignore --subnets-to-ignore --simulate --netns \
  --use-wait-flag --timeout-close-wait-secs --log-format --log-level --iptables-mode --ipv6 \
  --firewall-bin-path --firewall-save-bin-path; do
  grep -Fq -- "$flag" "$work/help" || fail "--help does not list $flag"
done

# --simulate prints the iptables commands without running them.
run_capable --network none "$image" --simulate -p 4143 -o 4140 -u 2102 --ipv6=false \
  --inbound-ports-to-ignore 4190,4191 >"$work/simulate" 2>&1 || fail "--simulate failed: $(cat "$work/simulate")"
for cmd in 'iptables-legacy-save -t nat' 'iptables-legacy -t nat -N PROXY_INIT_REDIRECT' \
  'iptables-legacy -t nat -A PREROUTING -j PROXY_INIT_REDIRECT' \
  'iptables-legacy -t nat -A PROXY_INIT_OUTPUT -p tcp -j REDIRECT --to-port 4140'; do
  grep -Fq "$cmd" "$work/simulate" || fail "--simulate does not print '$cmd': $(cat "$work/simulate")"
done

# ----------------------------------------------------------- invalid flag values
expect_reject() {
  name=$1 pattern=$2
  shift 2
  rc=0
  run_capable --network none "$image" "$@" >"$work/reject" 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "$name: want exit 1, got $rc: $(cat "$work/reject")"
  grep -Fq -- "$pattern" "$work/reject" || fail "$name: missing '$pattern' in: $(cat "$work/reject")"
  # proxy-init logs every iptables command (level=info) before it runs it.
  if grep -Fq 'level=info' "$work/reject"; then
    fail "$name: iptables ran before the flag was rejected: $(cat "$work/reject")"
  fi
}
expect_reject 'unknown --iptables-mode' '--iptables-mode valid values are only "legacy", "nft" and "plain"' \
  -p 4143 -o 4140 --iptables-mode bogus
expect_reject 'unknown --firewall-bin-path' '--firewall-bin-path valid values are only' \
  -p 4143 -o 4140 --firewall-bin-path /bin/false
expect_reject 'out-of-range --incoming-proxy-port' '--incoming-proxy-port must be a valid TCP port number' \
  -p 70000 -o 4140
expect_reject 'missing --outgoing-proxy-port' '--outgoing-proxy-port must be a valid TCP port number' \
  -p 4143
expect_reject 'non-numeric --ports-to-redirect' 'invalid argument "http" for "-r, --ports-to-redirect"' \
  -p 4143 -o 4140 --ports-to-redirect http
expect_reject 'invalid --subnets-to-ignore' '10.0.0.0/33 is not a valid CIDR address' \
  -p 4143 -o 4140 --subnets-to-ignore 10.0.0.0/33
expect_reject 'unknown --log-level' 'not a valid logrus Level: "bogus"' \
  -p 4143 -o 4140 --log-level bogus

# An invalid port range in an ignore list is logged and dropped, as upstream
# does, while the valid entries are still applied.
run_capable --network none "$image" --simulate -p 4143 -o 4140 --ipv6=false \
  --inbound-ports-to-ignore 4190,200-100 --outbound-ports-to-ignore 443,9-x >"$work/range" 2>&1 ||
  fail "--simulate with an invalid range failed: $(cat "$work/range")"
grep -Fq 'invalid port configuration of \"200-100\"' "$work/range" ||
  fail "reversed inbound range was not reported: $(cat "$work/range")"
grep -Fq 'invalid port configuration of \"9-x\"' "$work/range" ||
  fail "non-numeric outbound range was not reported: $(cat "$work/range")"
grep -Fq -- '--dports 4190 -j RETURN' "$work/range" || fail "valid inbound port was dropped: $(cat "$work/range")"
grep -Fq -- '--dports 443 -j RETURN' "$work/range" || fail "valid outbound port was dropped: $(cat "$work/range")"
if grep -Eq -- '--dports ([^ ]*,)?(200|100|9)([,: ]|$)' "$work/range"; then
  fail "an invalid range reached iptables: $(cat "$work/range")"
fi

# ----------------------------------------- redirect setup without capabilities
# A real redirect setup as the default user with every capability dropped. The
# entrypoint's file capabilities make execve fail before proxy-init runs, as
# with upstream.
setup='-p 4143 -o 4140 -u 2102 --ipv6=false --inbound-ports-to-ignore 4190,4191'
expect_unprivileged() {
  name=$1
  shift
  rc=0
  # shellcheck disable=SC2086 # $setup is a list of flags
  docker run --rm --network none "$@" "$image" $setup >"$work/unpriv" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "$name: redirect setup succeeded without capabilities"
  if [ "$emulated" = true ]; then
    grep -Eq 'operation not permitted|Permission denied|you must be root|exit status' "$work/unpriv" ||
      fail "$name: no permission error: $(cat "$work/unpriv")"
  else
    grep -Fq 'exec /usr/local/bin/proxy-init: operation not permitted' "$work/unpriv" ||
      fail "$name: want EPERM from exec: $(cat "$work/unpriv")"
  fi
}
expect_unprivileged '--cap-drop=ALL' --cap-drop=ALL
expect_unprivileged '--cap-drop=ALL with no-new-privileges' --cap-drop=ALL --security-opt no-new-privileges
expect_unprivileged 'NET_ADMIN without NET_RAW' --cap-drop=ALL --cap-add NET_ADMIN

# A copy of proxy-init has no file capabilities, so it starts, and the iptables
# step is refused: the capability-bearing iptables-legacy-save cannot run and
# proxy-init aborts before installing anything.
rc=0
# shellcheck disable=SC2086 # $setup is a list of flags
docker run --rm --network none --cap-drop=ALL --security-opt no-new-privileges --read-only \
  --tmpfs /tmp:exec --entrypoint /bin/sh "$image" \
  -c 'cp /usr/local/bin/proxy-init /tmp/proxy-init && exec /tmp/proxy-init "$@"' sh $setup \
  >"$work/nocaps" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "capability-free proxy-init: want exit 1, got $rc: $(cat "$work/nocaps")"
grep -Fq 'aborting firewall configuration' "$work/nocaps" ||
  fail "capability-free proxy-init did not abort: $(cat "$work/nocaps")"
if [ "$emulated" = true ]; then
  grep -Eq 'operation not permitted|Permission denied|you must be root|exit status' "$work/nocaps" ||
    fail "capability-free proxy-init: no permission error: $(cat "$work/nocaps")"
else
  grep -Eq 'Error: fork/exec /usr/s?bin/iptables-legacy-save: operation not permitted' "$work/nocaps" ||
    fail "capability-free proxy-init: want EPERM for iptables-legacy-save: $(cat "$work/nocaps")"
fi
if grep -Fq -- '-N PROXY_INIT' "$work/nocaps"; then
  fail "capability-free proxy-init went on to create chains: $(cat "$work/nocaps")"
fi

# ------------------------ redirect setup with NET_ADMIN and NET_RAW, private netns
# A holder container owns a fresh network namespace (no host networking), so
# the rules can be read back after proxy-init exits.
if [ "$emulated" = true ]; then
  printf 'SKIP: rule installation under qemu-user (%s image on %s host)\n' "$image_arch" "$host_arch"
  printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
  exit 0
fi

# setup_in MODE FLAGS SAVE... runs proxy-init with --iptables-mode MODE and
# FLAGS in a new holder namespace and stores the nat table of each
# iptables-save variant in $work/<save>.
setup_in() {
  mode=$1 flags=$2
  shift 2
  docker rm -f "$holder" >/dev/null 2>&1 || true
  docker run -d --name "$holder" --network none --cap-drop=ALL --cap-add NET_ADMIN --cap-add NET_RAW \
    --security-opt no-new-privileges --read-only --entrypoint /bin/sleep "$image" 600 >/dev/null
  rc=0
  # shellcheck disable=SC2086 # $flags is a list of flags
  run_capable --network "container:$holder" "$image" --iptables-mode "$mode" \
    -p 4143 -o 4140 -u 2102 -g 2103 -r 8080,9090 --inbound-ports-to-ignore 4190,4191,200-100 \
    --outbound-ports-to-ignore 443,5000-5010 $flags >"$work/setup-$mode" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "proxy-init --iptables-mode $mode exited $rc: $(cat "$work/setup-$mode")"
  # The only error is the dropped 200-100 range, once per address family.
  if grep 'level=error' "$work/setup-$mode" | grep -Fvq 'invalid port configuration of \"200-100\"'; then
    fail "proxy-init --iptables-mode $mode logged errors: $(grep 'level=error' "$work/setup-$mode")"
  fi
  for save in "$@"; do
    docker exec "$holder" "$save" -t nat >"$work/$save" 2>&1 ||
      fail "$save failed: $(cat "$work/$save")"
  done
}

# check_nat SAVE [RULE...]: the nat-table contract proxy-init installs, plus
# any extra RULE.
check_nat() {
  save=$1
  shift
  for rule in \
    ':PROXY_INIT_REDIRECT - ' \
    ':PROXY_INIT_OUTPUT - ' \
    '-A PREROUTING -m comment --comment "proxy-init/install-proxy-init-prerouting" -j PROXY_INIT_REDIRECT' \
    '-A OUTPUT -m comment --comment "proxy-init/install-proxy-init-output" -j PROXY_INIT_OUTPUT' \
    '-A PROXY_INIT_REDIRECT -p tcp -m multiport --dports 4190,4191 -m comment --comment "proxy-init/ignore-port-4190,4191" -j RETURN' \
    '-A PROXY_INIT_REDIRECT -p tcp -m tcp --dport 8080 -m comment --comment "proxy-init/redirect-port-8080-to-proxy-port" -j REDIRECT --to-ports 4143' \
    '-A PROXY_INIT_REDIRECT -p tcp -m tcp --dport 9090 -m comment --comment "proxy-init/redirect-port-9090-to-proxy-port" -j REDIRECT --to-ports 4143' \
    '-A PROXY_INIT_OUTPUT -m owner --uid-owner 2102 -m comment --comment "proxy-init/ignore-proxy-user-id" -j RETURN' \
    '-A PROXY_INIT_OUTPUT -m owner --gid-owner 2103 -m comment --comment "proxy-init/ignore-proxy-group-id" -j RETURN' \
    '-A PROXY_INIT_OUTPUT -o lo -m comment --comment "proxy-init/ignore-loopback" -j RETURN' \
    '-A PROXY_INIT_OUTPUT -p tcp -m multiport --dports 443,5000:5010 -m comment --comment "proxy-init/ignore-port-443,5000:5010" -j RETURN' \
    '-A PROXY_INIT_OUTPUT -p tcp -m comment --comment "proxy-init/redirect-all-outgoing-to-proxy-port" -j REDIRECT --to-ports 4140' \
    "$@"; do
    grep -Fq -- "$rule" "$work/$save" ||
      fail "$save lacks '$rule': $(cat "$work/$save")"
  done
  if grep -Eq -- '--dports ([^ ]*,)?(200|100)([,: ]|$)' "$work/$save"; then
    fail "$save holds the invalid 200-100 range: $(cat "$work/$save")"
  fi
}

# Legacy, the default mode. IPv6 is off: legacy ip6tables needs ip6table_nat
# loaded on the host, which a container cannot modprobe. The ignored subnet is
# IPv4, so it is only valid without IPv6.
setup_in legacy '--ipv6=false --subnets-to-ignore 10.1.0.0/16' iptables-legacy-save
check_nat iptables-legacy-save \
  '-A PROXY_INIT_REDIRECT -s 10.1.0.0/16 -m comment --comment "proxy-init/ignore-subnet-10.1.0.0/16" -j RETURN'

# Re-running in the same namespace flushes and refills the chains instead of
# adding a second jump.
rc=0
run_capable --network "container:$holder" "$image" -p 4143 -o 4140 -u 2102 --ipv6=false \
  >"$work/rerun" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "re-running proxy-init exited $rc: $(cat "$work/rerun")"
docker exec "$holder" iptables-legacy-save -t nat >"$work/rerun-save"
[ "$(grep -c -- '-j PROXY_INIT_REDIRECT' "$work/rerun-save")" = 1 ] ||
  fail "re-run duplicated the PREROUTING jump: $(cat "$work/rerun-save")"
[ "$(grep -c -- '-j PROXY_INIT_OUTPUT' "$work/rerun-save")" = 1 ] ||
  fail "re-run duplicated the OUTPUT jump: $(cat "$work/rerun-save")"
if grep -Fq 'ignore-port-4190,4191' "$work/rerun-save"; then
  fail "re-run kept the previous chain contents: $(cat "$work/rerun-save")"
fi
grep -Fq -- '-A PROXY_INIT_REDIRECT -p tcp -m comment --comment "proxy-init/redirect-all-incoming-to-proxy-port" -j REDIRECT --to-ports 4143' \
  "$work/rerun-save" || fail "re-run did not redirect all incoming traffic: $(cat "$work/rerun-save")"

# nft, for IPv4 and IPv6 (the default --ipv6=true).
setup_in nft '' iptables-nft-save ip6tables-nft-save
check_nat iptables-nft-save
check_nat ip6tables-nft-save
# The legacy tables of that namespace stay empty.
docker exec "$holder" iptables-legacy-save -t nat >"$work/legacy-after-nft" 2>&1 || true
if grep -Fq PROXY_INIT "$work/legacy-after-nft"; then
  fail "--iptables-mode nft wrote legacy rules: $(cat "$work/legacy-after-nft")"
fi

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
python_index=ghcr.io/tektum/python@sha256:d059268a2e4f0ef0cc82bb50c847e69e16e174736758013a153cb36311fa6dd6
container="verity-postfix-test-$$"
spool="verity-postfix-spool-$$"
mail="verity-postfix-mail-$$"
fixture=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$spool" "$mail" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
# Pulling the index itself for a second platform fails with "cannot overwrite digest".
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
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
python_image=$(pull_child "$python_index")

dump_logs() {
  docker logs "$container" >&2 2>&1 || true
}

# smtp MODE: run an SMTP client from the catalog Python image in the server's
# network namespace and print one line per server reply.
smtp() {
  docker run --rm --cpus 2 --network "container:$container" \
    -v "$fixture/smtp_client.py:/smtp_client.py:ro" \
    "$python_image" /smtp_client.py "$1"
}

wait_ready() {
  i=0
  until smtp ready 2>/dev/null | grep -q '^banner 220 mail\.verity\.test ESMTP'; do
    [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || {
      dump_logs
      fail 'postfix exited before accepting SMTP connections'
    }
    i=$((i + 1))
    [ "$i" -lt 30 ] || {
      dump_logs
      fail 'postfix did not accept SMTP connections on port 25'
    }
    sleep 1
  done
}

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/sbin/postfix"]' ] ||
  fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["start-fg"]' ] ||
  fail 'unexpected image command'
[ "$(docker image inspect --format '{{json .Config.Volumes}}' "$image" | grep -Fc '"/var/spool/postfix"')" -eq 1 ] ||
  fail 'missing queue volume'
[ "$(docker image inspect --format '{{json .Config.Volumes}}' "$image" | grep -Fc '"/var/mail"')" -eq 1 ] ||
  fail 'missing mailbox volume'

version=$(docker run --rm --cpus 2 --entrypoint /usr/sbin/postconf "$image" -h mail_version)
case "$version" in
  3.11.*) ;;
  *) fail "unexpected postfix version: $version" ;;
esac
docker run --rm --cpus 2 --entrypoint /usr/sbin/postconf "$image" -m | grep -qx lmdb ||
  fail 'lmdb lookup table support is missing'
# Local submission needs setgid postdrop on postdrop and postqueue.
for tool in postdrop postqueue; do
  mode=$(docker run --rm --cpus 2 --entrypoint /bin/stat "$image" -c '%a %U %G' "/usr/sbin/$tool")
  [ "$mode" = '2755 root postdrop' ] || fail "/usr/sbin/$tool is $mode, not 2755 root postdrop"
done

# Negative: an unknown postfix command is rejected with a usage error.
if docker run --rm --cpus 2 "$image" no-such-command >"$fixture/bad.out" 2>&1; then
  fail 'unknown postfix command unexpectedly succeeded'
fi
grep -q 'unknown command' "$fixture/bad.out" || {
  cat "$fixture/bad.out" >&2
  fail 'unknown postfix command did not report a readable error'
}

# Local delivery needs a recipient account; supply one the way an operator
# would, by extending the image's own account database.
docker run --rm --cpus 2 --entrypoint /bin/cat "$image" /etc/passwd >"$fixture/passwd"
docker run --rm --cpus 2 --entrypoint /bin/cat "$image" /etc/group >"$fixture/group"
printf 'smoke:x:1500:1500:Smoke test mailbox:/home/smoke:/sbin/nologin\n' >>"$fixture/passwd"
printf 'smoke:x:1500:\n' >>"$fixture/group"
# mynetworks is TEST-NET-1, so the 127.0.0.1 test client is untrusted and the
# relay check exercises reject_unauth_destination rather than permit_mynetworks.
cat >"$fixture/main.cf" <<'EOF'
compatibility_level = 3.11
maillog_file = /dev/stdout
myhostname = mail.verity.test
mydomain = verity.test
myorigin = $mydomain
mydestination = $myhostname, $mydomain, localhost
inet_interfaces = all
inet_protocols = ipv4
mynetworks = 192.0.2.0/24
alias_maps =
alias_database =
local_recipient_maps = unix:passwd.byname
mail_spool_directory = /var/mail/
smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination
smtpd_recipient_restrictions = reject_unauth_destination
smtpd_banner = $myhostname ESMTP
EOF
chmod 0644 "$fixture/passwd" "$fixture/group" "$fixture/main.cf"
cat >"$fixture/smtp_client.py" <<'EOF'
import smtplib
import socket
import sys

mode = sys.argv[1]


def reply(label, result):
    code, text = result
    print(label, code, text.decode().replace("\n", " "), flush=True)


client = smtplib.SMTP(timeout=10)
try:
    reply("banner", client.connect("127.0.0.1", 25))
except (OSError, smtplib.SMTPException) as error:
    print("connect-failed", error)
    sys.exit(1)
if mode == "ready":
    client.quit()
    sys.exit(0)
reply("ehlo", client.ehlo("client.verity.test"))
reply("mail", client.mail("sender@client.verity.test"))
if mode == "accept":
    reply("rcpt", client.rcpt("smoke@verity.test"))
    message = (
        "From: sender@client.verity.test\r\n"
        "To: smoke@verity.test\r\n"
        "Subject: verity postfix smoke\r\n"
        "\r\n"
        "verity-postfix-delivery-token\r\n"
    )
    reply("data", client.data(message))
elif mode == "reject":
    reply("rcpt-local", client.rcpt("nobody-here@verity.test"))
    reply("rcpt-relay", client.rcpt("victim@example.com"))
else:
    sys.exit("unknown mode " + mode)
client.quit()
EOF
chmod 0644 "$fixture/smtp_client.py"

docker run --name "$container" --cpus 2 -d \
  --hostname mail.verity.test \
  -v "$fixture/main.cf:/etc/postfix/main.cf:ro" \
  -v "$fixture/passwd:/etc/passwd:ro" \
  -v "$fixture/group:/etc/group:ro" \
  -v "$spool:/var/spool/postfix" \
  -v "$mail:/var/mail" \
  "$image" >/dev/null
wait_ready

docker exec "$container" ps -o user,args >"$fixture/ps.out"
# Under emulation (arm64 on amd64 CI) args are prefixed with the qemu binary.
grep -Eq '^root +(\S*qemu-\S+ +)?/usr/libexec/postfix/master' "$fixture/ps.out" || {
  cat "$fixture/ps.out" >&2
  fail 'postfix master is not running'
}
grep -Eq '^postfix +(\S*qemu-\S+ +/usr/libexec/postfix/qmgr +)?qmgr' "$fixture/ps.out" || {
  cat "$fixture/ps.out" >&2
  fail 'queue manager does not run as the unprivileged postfix user'
}

smtp accept >"$fixture/accept.out"
grep -q '^ehlo 250 mail\.verity\.test' "$fixture/accept.out" || {
  cat "$fixture/accept.out" >&2
  fail 'EHLO was not accepted'
}
grep -q '^data 250 2\.0\.0 Ok: queued as ' "$fixture/accept.out" || {
  cat "$fixture/accept.out" >&2
  dump_logs
  fail 'message was not queued'
}

i=0
until docker exec "$container" /bin/sh -c 'grep -rl verity-postfix-delivery-token /var/mail/smoke/new' >"$fixture/delivered" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || {
    dump_logs
    fail 'message was not delivered to the local maildir'
  }
  sleep 1
done
# mail_spool_directory ends in "/", which Postfix local(8) treats as Maildir.
[ "$(wc -l <"$fixture/delivered")" -eq 1 ] || fail 'message was not delivered exactly once'
delivered=$(head -n 1 "$fixture/delivered")
docker exec "$container" /bin/sh -c "stat -c '%u' '$delivered'" | grep -qx 1500 ||
  fail 'delivered message is not owned by the recipient'
docker exec "$container" /bin/cat "$delivered" >"$fixture/message"
grep -q '^Subject: verity postfix smoke' "$fixture/message" || fail 'delivered message lost its subject'
grep -q '^Delivered-To: smoke@verity.test' "$fixture/message" || fail 'local delivery header missing'
docker logs "$container" 2>&1 | grep -Eq 'postfix/local\[[0-9]+\]: .*to=<smoke@verity.test>.*status=sent' ||
  fail 'local delivery was not logged'

# Negative: unknown local users and relaying to foreign domains are refused.
smtp reject >"$fixture/reject.out"
grep -q '^rcpt-local 550 5\.1\.1 <nobody-here@verity\.test>: Recipient address rejected' "$fixture/reject.out" || {
  cat "$fixture/reject.out" >&2
  fail 'unknown local recipient was not rejected'
}
grep -q '^rcpt-relay 554 5\.7\.1 <victim@example\.com>: Relay access denied' "$fixture/reject.out" || {
  cat "$fixture/reject.out" >&2
  fail 'relay to a foreign domain was not denied'
}

docker kill --signal TERM "$container" >/dev/null
i=0
while [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ]; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || fail 'postfix did not stop after SIGTERM'
  sleep 1
done
status=$(docker inspect --format '{{.State.ExitCode}}' "$container")
[ "$status" -eq 0 ] || {
  dump_logs
  fail "postfix exited with status $status after SIGTERM"
}

printf 'postfix %s smoke test passed\n' "$version"

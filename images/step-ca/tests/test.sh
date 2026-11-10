#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
name="step-ca-smoke-$$"

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run --rm -v "$work:/x" --entrypoint /bin/sh "$image" -c 'rm -rf /x/* /x/.[!.]*' >/dev/null 2>&1 || true
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$name" >&2 2>&1 || true
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/step-ca"]' || fail 'unexpected entrypoint'

docker run --rm --network none --read-only "$image" version | grep -F 'Smallstep CA/' >/dev/null ||
  fail 'step-ca version output is missing'
docker run --rm --network none --read-only --entrypoint /usr/bin/step "$image" version |
  grep -F 'Smallstep CLI/' >/dev/null || fail 'step version output is missing'

# Initialize a CA non-interactively, then start it with the same image.
chmod 777 "$work"
printf 'smoke-password\n' >"$work/password"
chmod 644 "$work/password"
docker run --rm --network none --user 1000:1000 -v "$work:/home/step" \
  --entrypoint /usr/bin/step "$image" ca init \
  --deployment-type standalone --name Smoke --dns localhost \
  --address :9000 --provisioner smoke@example.com \
  --password-file /home/step/password >"$work/init.log" 2>&1 ||
  { cat "$work/init.log" >&2; fail 'step ca init failed'; }

docker run -d --name "$name" --label verity.smoke=step-ca --user 1000:1000 \
  -v "$work:/home/step" "$image" \
  /home/step/config/ca.json --password-file /home/step/password >/dev/null

i=0
until docker exec "$name" /usr/bin/step ca health --ca-url https://localhost:9000 \
  --root /home/step/certs/root_ca.crt >"$work/health" 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'step-ca did not become healthy'
  sleep 1
done
grep -Fx 'ok' "$work/health" >/dev/null || fail 'health did not report ok'

# Issue a certificate with the bundled CLI and verify its subject.
docker exec "$name" /usr/bin/step ca certificate smoke.local /home/step/smoke.crt /home/step/smoke.key \
  --ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt \
  --provisioner smoke@example.com --provisioner-password-file /home/step/password >/dev/null 2>&1 ||
  fail 'step ca certificate failed'
docker exec "$name" /usr/bin/step certificate inspect /home/step/smoke.crt --short >"$work/inspect" 2>&1
grep -F 'smoke.local' "$work/inspect" >/dev/null || fail 'issued certificate subject is wrong'
docker exec "$name" /usr/bin/step certificate verify /home/step/smoke.crt \
  --roots /home/step/certs/root_ca.crt >/dev/null 2>&1 || fail 'issued certificate does not verify'

printf 'SMOKE PASS image=%s\n' "$image"

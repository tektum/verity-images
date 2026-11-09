#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
signer="flux-kustomize-controller-smoke-signer-$$"
decryptor="flux-kustomize-controller-smoke-decryptor-$$"
repo="flux-kustomize-controller-smoke-git-$$"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker volume rm -f "$signer" "$decryptor" "$repo" >/dev/null 2>&1 || true
}
trap cleanup EXIT

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65534 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/tini","--","/manager"]' ] \
  || fail 'unexpected entrypoint'
case $(docker image inspect -f '{{json .Config.Cmd}}' "$image") in null|'[]') ;; *) fail 'unexpected image command' ;; esac
docker image inspect -f '{{json .Config.Env}}' "$image" | grep -F '"GNUPGHOME=/tmp"' >/dev/null \
  || fail 'GNUPGHOME is not /tmp'

help_output=$(docker run --rm --network none --user 65534 --cpus 4 --memory 1g --pids-limit 256 \
  "$image" --help 2>&1) || fail '/manager safe help path failed'
for flag in '--sops-age-secret string' '--no-remote-bases' '--sops-vault-configmap string'; do
  printf '%s\n' "$help_output" | grep -F -- "$flag" >/dev/null || fail "help is missing $flag"
done

if output=$(docker run --rm --network none --user 65534 --cpus 4 --memory 1g --pids-limit 256 \
  -e KUBECONFIG=/tmp/missing "$image" 2>&1); then
  fail 'missing Kubernetes credentials unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'unable to get kubeconfig' >/dev/null \
  || fail 'missing Kubernetes credentials did not report a kubeconfig error'

if output=$(docker run --rm --network none --user 65534 --cpus 4 --memory 1g --pids-limit 256 \
  "$image" --not-a-real-flag 2>&1); then
  fail 'invalid flag unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F -- '--not-a-real-flag' >/dev/null \
  || fail 'invalid flag diagnostic missing'

# SOPS PGP decryption shells out to gpg with GNUPGHOME=/tmp. Import a private
# key into an empty home as the controller does and decrypt with it as the
# runtime user. Each volume starts as a copy of the image's /tmp.
docker volume create "$signer" >/dev/null || fail 'signer volume creation failed'
docker volume create "$decryptor" >/dev/null || fail 'decryptor volume creation failed'
gpg_run() {
  home=$1
  shift
  docker run --rm -i --network none --user 65534 --cpus 4 --memory 1g --pids-limit 256 \
    -v "$home:/tmp" --entrypoint /usr/bin/gpg "$image" --batch --no-tty "$@"
}
gpg_run "$signer" --pinentry-mode loopback --passphrase '' \
  --quick-gen-key 'smoke <smoke@example.invalid>' default default never </dev/null >/dev/null 2>&1 \
  || fail 'gpg key generation failed'
key=$(gpg_run "$signer" --armor --export-secret-keys smoke@example.invalid </dev/null 2>/dev/null) \
  || fail 'gpg secret key export failed'
printf '%s\n' "$key" | grep -F 'BEGIN PGP PRIVATE KEY BLOCK' >/dev/null || fail 'exported key is not armored'
printf '%s\n' "$key" | gpg_run "$decryptor" --import >/dev/null 2>&1 \
  || fail 'gpg --batch --import into an empty GNUPGHOME failed'
ciphertext=$(printf 'verity-sops-pgp\n' | gpg_run "$signer" --trust-model always --armor \
  --encrypt --recipient smoke@example.invalid 2>/dev/null) || fail 'gpg encryption failed'
plaintext=$(printf '%s\n' "$ciphertext" | gpg_run "$decryptor" --decrypt 2>/dev/null) \
  || fail 'gpg decryption with the imported key failed'
[ "$plaintext" = verity-sops-pgp ] || fail 'gpg decrypted unexpected plaintext'

# Kustomize fetches remote Git bases by running git, and ssh for ssh:// URLs.
# Clone a local repository as the runtime user to prove the git CLI works.
docker volume create "$repo" >/dev/null || fail 'git volume creation failed'
git_run() {
  docker run --rm --network none --user 65534 --cpus 4 --memory 1g --pids-limit 256 \
    -e HOME=/tmp -v "$repo:/tmp" --entrypoint /usr/bin/git "$image" \
    -c user.name=smoke -c user.email=smoke@example.invalid -c init.defaultBranch=main "$@"
}
git_run init -q /tmp/src >/dev/null 2>&1 || fail 'git init failed'
git_run -C /tmp/src commit -q --allow-empty -m verity-remote-base >/dev/null 2>&1 \
  || fail 'git commit failed'
git_run clone -q --depth 1 file:///tmp/src /tmp/dst >/dev/null 2>&1 || fail 'git clone of a file:// base failed'
[ "$(git_run -C /tmp/dst log -1 --format=%s 2>/dev/null)" = verity-remote-base ] \
  || fail 'cloned base has unexpected history'
ssh_output=$(docker run --rm --network none --user 65534 --entrypoint /usr/bin/ssh "$image" -V 2>&1) \
  || fail 'ssh client is not runnable'
printf '%s\n' "$ssh_output" | grep -F OpenSSH >/dev/null || fail 'ssh client is not OpenSSH'

printf 'SMOKE PASS image=%s\n' "$image"

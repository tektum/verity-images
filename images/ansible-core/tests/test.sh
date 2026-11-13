#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*- py3\.13-ansible-core=\([0-9.]*\)-r[0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'ansible-core package pin not found' >&2; exit 1; }
tmp=$(mktemp -d)

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ] ||
  fail 'unexpected image config: User'
[ "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/ansible-playbook"]' ] ||
  fail 'unexpected image config: Entrypoint'
[ "$(docker image inspect "$image" --format '{{.Config.WorkingDir}}')" = /home/nonroot ] ||
  fail 'unexpected image config: WorkingDir'

docker run --rm "$image" --version >"$tmp/version.txt" || fail 'ansible-playbook --version failed'
head -n 1 "$tmp/version.txt" | grep -Fx "ansible-playbook [core $expected_version]" >/dev/null || {
  cat "$tmp/version.txt" >&2
  fail "unexpected version, want $expected_version"
}
for tool in ansible ansible-config ansible-doc ansible-galaxy ansible-inventory ansible-vault ssh; do
  docker run --rm --entrypoint sh "$image" -c "command -v $tool" >/dev/null ||
    fail "missing tool: $tool"
done

# Ad hoc module run on the implicit localhost.
docker run --rm --entrypoint ansible "$image" localhost -m ping -c local \
  >"$tmp/ping.txt" 2>&1 || { cat "$tmp/ping.txt" >&2; fail 'ansible ping failed'; }
grep -F '"ping": "pong"' "$tmp/ping.txt" >/dev/null || {
  cat "$tmp/ping.txt" >&2
  fail 'ansible ping did not return pong'
}

# A playbook that gathers facts, templates a file with Jinja2 and reads it back,
# on a read-only root filesystem with only HOME and /tmp writable.
chmod 755 "$tmp"
cat >"$tmp/site.yaml" <<'EOF'
- hosts: localhost
  connection: local
  gather_facts: true
  vars:
    greeting: verity
  tasks:
    - name: Render a file
      ansible.builtin.copy:
        dest: /home/nonroot/out.txt
        content: "{{ greeting | upper }} {{ ansible_facts.user_uid }}\n"
        mode: "0644"
    - name: Read it back
      ansible.builtin.slurp:
        src: /home/nonroot/out.txt
      register: rendered
    - name: Assert content
      ansible.builtin.assert:
        that:
          - (rendered.content | b64decode) == "VERITY 65532\n"
EOF
chmod 644 "$tmp/site.yaml"
docker run --rm --read-only --tmpfs /home/nonroot:uid=65532,gid=65532 --tmpfs /tmp \
  -v "$tmp/site.yaml:/work/site.yaml:ro" "$image" /work/site.yaml \
  >"$tmp/play.txt" 2>&1 || { cat "$tmp/play.txt" >&2; fail 'playbook run failed'; }
grep -E 'localhost +: ok=[0-9]+ +changed=1 +unreachable=0 +failed=0' "$tmp/play.txt" >/dev/null || {
  cat "$tmp/play.txt" >&2
  fail 'unexpected playbook recap'
}

# Vault round trip exercises the cryptography dependency.
printf '%s\n' 'vault-password-for-smoke' >"$tmp/vault-pass"
printf '%s\n' 'secret-value' >"$tmp/plain.txt"
chmod 644 "$tmp/vault-pass" "$tmp/plain.txt"
docker run --rm --entrypoint sh -v "$tmp:/work:ro" "$image" -c \
  'cp /work/plain.txt /tmp/s.txt &&
   ansible-vault encrypt --vault-password-file /work/vault-pass /tmp/s.txt >/dev/null &&
   head -n 1 /tmp/s.txt &&
   ansible-vault view --vault-password-file /work/vault-pass /tmp/s.txt' \
  >"$tmp/vault.txt" 2>&1 || { cat "$tmp/vault.txt" >&2; fail 'ansible-vault round trip failed'; }
grep -F "\$ANSIBLE_VAULT;1.1;AES256" "$tmp/vault.txt" >/dev/null || fail 'vault header missing'
grep -Fx 'secret-value' "$tmp/vault.txt" >/dev/null || fail 'vault did not decrypt'

# Negative cases: an unknown module and an unknown option.
printf '%s\n' '- hosts: localhost' '  tasks:' '    - name: broken' '      no_such_module_xyz: {}' \
  >"$tmp/invalid.yaml"
chmod 644 "$tmp/invalid.yaml"
if docker run --rm -v "$tmp/invalid.yaml:/work/invalid.yaml:ro" "$image" \
  --syntax-check /work/invalid.yaml >"$tmp/invalid.log" 2>&1; then
  fail 'invalid playbook unexpectedly passed --syntax-check'
fi
grep -F 'no_such_module_xyz' "$tmp/invalid.log" >/dev/null || {
  cat "$tmp/invalid.log" >&2
  fail 'syntax error is not readable'
}
if docker run --rm "$image" --no-such-option site.yaml >"$tmp/option.log" 2>&1; then
  fail 'unknown option unexpectedly succeeded'
fi
grep -F 'unrecognized arguments' "$tmp/option.log" >/dev/null || {
  cat "$tmp/option.log" >&2
  fail 'unknown option error is not readable'
}

printf 'SMOKE PASS image=%s\n' "$image"

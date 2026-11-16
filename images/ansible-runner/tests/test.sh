#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
expected_runner=$(sed -n 's/^[[:space:]]*- py3\.13-ansible-runner=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
expected_core=$(sed -n 's/^[[:space:]]*- py3\.13-ansible-core=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
[ -n "$expected_runner" ] || { printf '%s\n' 'ansible-runner package pin not found' >&2; exit 1; }
[ -n "$expected_core" ] || { printf '%s\n' 'ansible-core package pin not found' >&2; exit 1; }
tmp=$(mktemp -d)

cleanup() {
  # The container writes artifacts as UID 65532; remove them from inside.
  docker run --rm --user 0 --entrypoint rm -v "$tmp:/work" "$image" -rf /work/ok /work/bad /work/stream \
    >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# Artifacts are written by UID 65532 with private modes; make them readable on
# the host without changing what the runner wrote.
expose() {
  docker run --rm --user 0 --entrypoint chmod -v "$tmp:/work" "$image" -R a+rX "/work/$1" ||
    fail "could not expose artifacts in $1"
}

show() {
  for file in "$@"; do
    [ -f "$file" ] && { printf '==> %s\n' "$file" >&2; cat "$file" >&2; }
  done
  return 0
}

[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ] ||
  fail 'unexpected image config: User'
[ "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/ansible-runner"]' ] ||
  fail 'unexpected image config: Entrypoint'
[ "$(docker image inspect "$image" --format '{{.Config.WorkingDir}}')" = /home/nonroot ] ||
  fail 'unexpected image config: WorkingDir'

docker run --rm "$image" --version >"$tmp/version.txt" 2>&1 || { show "$tmp/version.txt"; fail 'ansible-runner --version failed'; }
grep -Fx "$expected_runner" "$tmp/version.txt" >/dev/null || {
  show "$tmp/version.txt"
  fail "ansible-runner version is not $expected_runner"
}
docker run --rm --entrypoint ansible-playbook "$image" --version >"$tmp/core.txt" 2>&1 ||
  { show "$tmp/core.txt"; fail 'ansible-playbook --version failed'; }
head -n 1 "$tmp/core.txt" | grep -Fx "ansible-playbook [core $expected_core]" >/dev/null || {
  show "$tmp/core.txt"
  fail "ansible-core version is not $expected_core"
}

# A private data directory in the layout ansible-runner documents: inventory,
# env/extravars, env/envvars and project/. The runner writes artifacts into it,
# so the directory is owned by the image user's UID.
make_pdd() {
  dir=$1
  mkdir -p "$dir/inventory" "$dir/env" "$dir/project"
  cat >"$dir/inventory/hosts.yml" <<'EOF'
local:
  hosts:
    localhost:
      ansible_connection: local
      ansible_python_interpreter: "{{ ansible_playbook_python }}"
EOF
  printf '%s\n' 'greeting: hello-from-extravars' >"$dir/env/extravars"
  printf '%s\n' 'RUNNER_SMOKE_ENV: from-envvars' >"$dir/env/envvars"
}

make_pdd "$tmp/ok"
cat >"$tmp/ok/project/site.yml" <<'EOF'
- hosts: local
  gather_facts: true
  tasks:
    - name: write marker
      ansible.builtin.copy:
        dest: /tmp/runner-marker.txt
        content: "{{ greeting }} {{ lookup('ansible.builtin.env', 'RUNNER_SMOKE_ENV') }} on {{ ansible_facts.system }}\n"
    - name: read marker
      ansible.builtin.slurp:
        src: /tmp/runner-marker.txt
      register: marker
    - name: report marker
      ansible.builtin.debug:
        msg: "MARKER={{ marker.content | b64decode | trim }}"
EOF

make_pdd "$tmp/bad"
cat >"$tmp/bad/project/site.yml" <<'EOF'
- hosts: local
  gather_facts: false
  tasks:
    - name: deliberate failure
      ansible.builtin.fail:
        msg: deliberate-runner-failure
    - name: never reached
      ansible.builtin.debug:
        msg: SHOULD-NOT-RUN
EOF

mkdir -p "$tmp/stream"
chmod -R a+rX "$tmp"
docker run --rm --user 0 --entrypoint chown -v "$tmp:/work" "$image" -R 65532:65532 /work/ok /work/bad /work/stream ||
  fail 'could not hand private data directories to UID 65532'

# Successful run on a read-only root filesystem: only the private data
# directory, HOME and /tmp are writable.
if ! docker run --rm --read-only --tmpfs /home/nonroot:uid=65532,gid=65532 --tmpfs /tmp \
  -v "$tmp/ok:/runner" "$image" run /runner -p site.yml --ident ok-run \
  >"$tmp/ok.log" 2>&1; then
  show "$tmp/ok.log"
  fail 'ansible-runner run of a passing playbook failed'
fi
expose ok
art="$tmp/ok/artifacts/ok-run"
[ -d "$art" ] || { show "$tmp/ok.log"; fail 'artifact directory artifacts/ok-run missing'; }
[ "$(cat "$art/status")" = successful ] || { show "$art/status" "$art/stdout"; fail 'status is not successful'; }
[ "$(cat "$art/rc")" = 0 ] || { show "$art/rc" "$art/stdout"; fail 'rc is not 0'; }
grep -F 'MARKER=hello-from-extravars from-envvars on Linux' "$tmp/ok.log" >/dev/null ||
  { show "$tmp/ok.log"; fail 'runner stdout lacks the templated marker'; }
grep -F 'MARKER=hello-from-extravars from-envvars on Linux' "$art/stdout" >/dev/null ||
  { show "$art/stdout"; fail 'artifacts stdout lacks the templated marker'; }
grep -E 'localhost +: ok=4 +changed=1 +unreachable=0 +failed=0' "$art/stdout" >/dev/null ||
  { show "$art/stdout"; fail 'play recap is not ok=4 changed=1 failed=0'; }
jq -e '.command[0] == "ansible-playbook" and .command[-1] == "site.yml" and .cwd == "/runner/project"
  and (.command | index(["-e", "@/runner/env/extravars"]) != null)' "$art/command" >/dev/null ||
  { show "$art/command"; fail 'command artifact does not record the playbook invocation'; }

events="$tmp/ok-events.json"
jq -s '.' "$art"/job_events/*.json >"$events" || fail 'job_events are not valid JSON'
jq -e 'any(.[]; .event == "playbook_on_start")' "$events" >/dev/null || fail 'no playbook_on_start event'
jq -e 'any(.[]; .event == "runner_on_ok" and .event_data.task == "write marker"
  and .event_data.host == "localhost" and .event_data.res.changed == true)' "$events" >/dev/null ||
  fail 'no changed runner_on_ok event for "write marker"'
jq -e 'any(.[]; .event == "runner_on_ok" and .event_data.task == "report marker"
  and .event_data.res.msg == "MARKER=hello-from-extravars from-envvars on Linux")' "$events" >/dev/null ||
  fail 'no runner_on_ok event carrying the debug message'
jq -e 'any(.[]; .event == "playbook_on_stats" and .event_data.ok.localhost == 4
  and .event_data.changed.localhost == 1 and (.event_data.failures | length) == 0)' "$events" >/dev/null ||
  fail 'playbook_on_stats event does not report ok=4 changed=1 and no failures'
jq -e 'all(.[]; .event != "runner_on_failed")' "$events" >/dev/null || fail 'unexpected runner_on_failed event'
jq -e '[.[].counter] | sort | . == ([range(1; length + 1)])' "$events" >/dev/null ||
  fail 'job event counters are not a contiguous sequence'

# Failing playbook: the runner exits with the playbook rc and records failure.
set +e
docker run --rm -v "$tmp/bad:/runner" "$image" run /runner -p site.yml --ident bad-run \
  >"$tmp/bad.log" 2>&1
bad_rc=$?
set -e
expose bad
[ "$bad_rc" -eq 2 ] || { show "$tmp/bad.log"; fail "failing playbook exited $bad_rc, expected 2"; }
art="$tmp/bad/artifacts/bad-run"
[ "$(cat "$art/status")" = failed ] || { show "$art/status" "$art/stdout"; fail 'status is not failed'; }
[ "$(cat "$art/rc")" = 2 ] || { show "$art/rc" "$art/stdout"; fail 'rc is not 2'; }
grep -F 'deliberate-runner-failure' "$art/stdout" >/dev/null || { show "$art/stdout"; fail 'failure message not in stdout'; }
! grep -F 'SHOULD-NOT-RUN' "$art/stdout" >/dev/null || fail 'task after failure ran'
events="$tmp/bad-events.json"
jq -s '.' "$art"/job_events/*.json >"$events" || fail 'failing job_events are not valid JSON'
jq -e 'any(.[]; .event == "runner_on_failed" and .event_data.task == "deliberate failure"
  and .event_data.res.msg == "deliberate-runner-failure")' "$events" >/dev/null ||
  fail 'no runner_on_failed event carrying the failure message'
jq -e 'any(.[]; .event == "playbook_on_stats" and .event_data.failures.localhost == 1)' "$events" >/dev/null ||
  fail 'playbook_on_stats does not record the failure'

# Missing playbook: the runner refuses before starting ansible.
set +e
docker run --rm -v "$tmp/bad:/runner" "$image" run /runner -p no-such-playbook.yml --ident missing \
  >"$tmp/missing.log" 2>&1
missing_rc=$?
set -e
expose bad
[ "$missing_rc" -ne 0 ] || { show "$tmp/missing.log"; fail 'missing playbook unexpectedly succeeded'; }
grep -F 'no-such-playbook.yml could not be found' "$tmp/missing.log" >/dev/null ||
  { show "$tmp/missing.log"; fail 'missing playbook error not reported'; }
if [ -f "$tmp/bad/artifacts/missing/status" ] && [ "$(cat "$tmp/bad/artifacts/missing/status")" = successful ]; then
  fail 'missing playbook recorded a successful status'
fi

# Remote-execution pipeline: transmit packs the private data directory, worker
# runs it, and process replays the event stream into a fresh artifact tree.
docker run --rm -v "$tmp/ok:/runner:ro" "$image" transmit /runner -p site.yml --ident streamed \
  >"$tmp/transmit.bin" 2>"$tmp/transmit.err" || { show "$tmp/transmit.err"; fail 'ansible-runner transmit failed'; }
docker run --rm -i "$image" worker <"$tmp/transmit.bin" >"$tmp/worker.bin" 2>"$tmp/worker.err" ||
  { show "$tmp/worker.err"; fail 'ansible-runner worker failed'; }
grep -F '{"eof": true}' "$tmp/worker.bin" >/dev/null || { show "$tmp/worker.err"; fail 'worker stream has no eof marker'; }
docker run --rm -i -v "$tmp/stream:/out" "$image" process /out --ident streamed \
  <"$tmp/worker.bin" >"$tmp/stream.log" 2>&1 || { show "$tmp/stream.log"; fail 'ansible-runner process failed'; }
expose stream
art="$tmp/stream/artifacts/streamed"
[ "$(cat "$art/status")" = successful ] || { show "$tmp/stream.log" "$art/status"; fail 'streamed status is not successful'; }
[ "$(cat "$art/rc")" = 0 ] || { show "$art/rc"; fail 'streamed rc is not 0'; }
jq -s -e 'any(.[]; .event == "runner_on_ok" and .event_data.res.msg == "MARKER=hello-from-extravars from-envvars on Linux")' \
  "$art"/job_events/*.json >/dev/null || fail 'streamed events lack the debug message'

if docker run --rm "$image" run >"$tmp/usage.log" 2>&1; then
  fail 'run without a private data directory unexpectedly succeeded'
fi
grep -F 'the following arguments are required' "$tmp/usage.log" >/dev/null ||
  { show "$tmp/usage.log"; fail 'missing argument error not reported'; }

printf 'SMOKE PASS image=%s\n' "$image"

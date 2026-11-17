#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_sigterm_exit2_panic_check.py
#
# A Go binary with no SIGTERM handler exits 2 when it runs as PID 1, but 2 is
# also what the Go runtime uses for a panic or fatal error. Any image smoke test
# that accepts exit 2 after `docker stop` / SIGTERM must therefore also check
# the container log for a Go crash (`panic: `, `fatal error: `, goroutine
# traces) so a crash on shutdown cannot pass as a clean stop.

import re
import sys
from pathlib import Path
from typing import Final

ROOT: Final = Path(__file__).resolve().parents[1]
WINDOW: Final = 15

STOP: Final = re.compile(r"docker\s+(stop|kill)\b|SIGTERM|kill\s+-(TERM|15)\b")
# A case arm accepting 2 (`2) ;;`, `0|2|143) ;;`) or a direct `= 2 ]` / `-eq 2`.
ACCEPT_2: Final = re.compile(
    r"^\s*(?:[0-9]+\s*\|\s*)*2(?:\s*\|\s*[0-9]+)*\s*\)\s*;;"
    r"|(?:=|==|-eq)\s*\"?2\"?\s*\]"
)
PANIC_CHECK: Final = re.compile(r"panic: .*fatal error: |fatal error: .*panic: ")
# The 2 must be the container's exit status, not e.g. a SQL value.
EXIT_SOURCE: Final = re.compile(r"ExitCode|docker\s+wait|\$\?")


def violations(text: str) -> list[int]:
    """Return 1-based line numbers that accept exit 2 after SIGTERM unchecked."""
    lines = text.splitlines()
    found: list[int] = []
    for i, line in enumerate(lines):
        if line.lstrip().startswith("#") or not STOP.search(line):
            continue
        for j in range(i + 1, min(i + 1 + WINDOW, len(lines))):
            if lines[j].lstrip().startswith("#"):
                continue
            if ACCEPT_2.search(lines[j]):
                if EXIT_SOURCE.search("\n".join(lines[i : j + 1])):
                    after = "\n".join(lines[j : j + 1 + WINDOW])
                    if not PANIC_CHECK.search(after) and j + 1 not in found:
                        found.append(j + 1)
                break
    return found


GOOD: Final = """\
docker stop --time 10 "$c" >/dev/null
case $(docker inspect --format '{{.State.ExitCode}}' "$c") in
  0 | 2 | 143) ;;
  *) fail 'did not stop' ;;
esac
if docker logs "$c" 2>&1 | grep -Eq '^(panic: |fatal error: |goroutine [0-9]+ \\[)'; then
  fail 'crashed'
fi
"""

BAD_CASE: Final = """\
docker stop --time 10 "$c" >/dev/null
case $(docker inspect --format '{{.State.ExitCode}}' "$c") in
  2|143) ;;
  *) fail 'did not stop' ;;
esac
"""

BAD_EQ: Final = """\
docker stop -t 10 "$c" >/dev/null
[ "$(docker inspect "$c" --format '{{.State.ExitCode}}')" = 2 ] ||
  fail 'not the SIGTERM path'
"""

UNRELATED: Final = """\
docker run --rm "$image" --bogus || status=$?
[ "$status" = 2 ] || fail 'usage error'
docker stop "$c" >/dev/null
[ "$(docker inspect "$c" --format '{{.State.ExitCode}}')" = 143 ] || fail 'x'
"""


def check_fixtures() -> None:
    assert violations(GOOD) == [], violations(GOOD)
    assert violations(BAD_CASE) == [3], violations(BAD_CASE)
    assert violations(BAD_EQ) == [2], violations(BAD_EQ)
    assert violations(UNRELATED) == [], violations(UNRELATED)


def check_repository() -> None:
    bad = []
    for path in sorted(ROOT.glob("images/**/tests/test.sh")):
        for line in violations(path.read_text()):
            bad.append(f"{path.relative_to(ROOT)}:{line}")
    if bad:
        sys.exit(
            "test.sh accepts exit 2 after SIGTERM without rejecting Go panics "
            "(grep the container log for 'panic: ', 'fatal error: ' and goroutine traces):\n  "
            + "\n  ".join(bad)
        )


def main() -> None:
    check_fixtures()
    check_repository()
    print("ok")


if __name__ == "__main__":
    main()

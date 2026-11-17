#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   python3 scripts/test_sigterm_exit2_panic_check.py
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

STOP: Final = re.compile(
    r"docker\s+(?:container\s+)?(?:stop|kill)\b|SIGTERM|kill\s+-(?:TERM|15)\b"
)
# A case arm accepting 2, with or without a body (`2) ;;`, `0|2|143) echo ok ;;`),
# or a direct `= 2 ]` / `-eq 2`.
ACCEPT_2: Final = re.compile(
    r"^\s*(?:[0-9]+\s*\|\s*)*2(?:\s*\|\s*[0-9]+)*\s*\)"
    r"|(?:=|==|-eq)\s*\"?2\"?\s*\]"
)
# The 2 must be the container's exit status, not e.g. a SQL value.
EXIT_SOURCE: Final = re.compile(r"ExitCode|docker\s+(?:container\s+)?wait|\$\?")
# A crash check reads the container log and greps it for each Go crash marker;
# the markers may sit in one grep or in separate ones.
LOG_READ: Final = re.compile(r"docker\s+(?:container\s+)?logs\b")
GREP: Final = re.compile(r"\bgrep\b")
MARKERS: Final = ("panic: ", "fatal error: ")


def code_lines(lines: list[str]) -> list[str]:
    return [line for line in lines if not line.lstrip().startswith("#")]


def has_panic_check(lines: list[str]) -> bool:
    code = code_lines(lines)
    greps = [line for line in code if GREP.search(line)]
    return any(LOG_READ.search(line) for line in code) and all(
        any(marker in line for line in greps) for marker in MARKERS
    )


def violations(text: str) -> list[int]:
    """Return 1-based line numbers that accept exit 2 after SIGTERM unchecked."""
    lines = text.splitlines()
    found: list[int] = []
    for i, line in enumerate(lines):
        if line.lstrip().startswith("#") or not STOP.search(line):
            continue
        for j in range(i + 1, min(i + 1 + WINDOW, len(lines))):
            if lines[j].lstrip().startswith("#") or not ACCEPT_2.search(lines[j]):
                continue
            # Skip comparisons with 2 that are not the container's exit status.
            if not EXIT_SOURCE.search("\n".join(code_lines(lines[i : j + 1]))):
                continue
            if not has_panic_check(lines[j : j + 1 + WINDOW]) and j + 1 not in found:
                found.append(j + 1)
            break
    return found


CASE: Final = """\
docker stop --time 10 "$c" >/dev/null
case $(docker inspect --format '{{.State.ExitCode}}' "$c") in
  0 | 2 | 143) ;;
  *) fail 'did not stop' ;;
esac
"""

GOOD: Final = (
    CASE
    + """\
log=$(docker logs "$c" 2>&1) || fail 'no log'
if printf '%s\\n' "$log" | grep -Eq '^(panic: |fatal error: |goroutine [0-9]+ \\\\[)'; then
  fail 'crashed'
fi
"""
)

GOOD_SPLIT: Final = (
    CASE
    + """\
docker logs "$c" >"$tmp/log" 2>&1 || fail 'no log'
! grep -q '^panic: ' "$tmp/log" || fail 'panicked'
! grep -q '^fatal error: ' "$tmp/log" || fail 'fatal error'
"""
)

BAD_COMMENTED: Final = (
    CASE
    + """\
# log=$(docker logs "$c" 2>&1) || fail 'no log'
# printf '%s\\n' "$log" | grep -Eq '^(panic: |fatal error: )' && fail 'crashed'
"""
)

BAD_TEXT_ONLY: Final = (
    CASE
    + """\
docker logs "$c" >/dev/null || fail 'no log'
echo 'checked for panic: and fatal error: elsewhere'
"""
)

BAD_CASE: Final = """\
docker stop --time 10 "$c" >/dev/null
case $(docker inspect --format '{{.State.ExitCode}}' "$c") in
  2|143) ;;
  *) fail 'did not stop' ;;
esac
"""

BAD_ARM_BODY: Final = """\
docker container stop "$c" >/dev/null
case $(docker container wait "$c") in
  0 | 2) echo 'clean stop' ;;
  *) fail 'did not stop' ;;
esac
"""

BAD_AFTER_SQL: Final = """\
docker stop --time 10 "$c" >/dev/null
[ "$sql_value" = 2 ] || fail 'row changed'
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
    cases = {
        "GOOD": (GOOD, []),
        "GOOD_SPLIT": (GOOD_SPLIT, []),
        "BAD_COMMENTED": (BAD_COMMENTED, [3]),
        "BAD_TEXT_ONLY": (BAD_TEXT_ONLY, [3]),
        "BAD_CASE": (BAD_CASE, [3]),
        "BAD_ARM_BODY": (BAD_ARM_BODY, [3]),
        "BAD_AFTER_SQL": (BAD_AFTER_SQL, [4]),
        "BAD_EQ": (BAD_EQ, [2]),
        "UNRELATED": (UNRELATED, []),
    }
    for name, (text, want) in cases.items():
        got = violations(text)
        assert got == want, f"{name}: got {got}, want {want}"


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

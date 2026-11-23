#!/usr/bin/env python3
# How to run:
#   python3 scripts/untagged_go_modules.py SATISFIED_JSON SCAN...
#
# Shared by scripts/evaluate_scan_gate.sh and scripts/build_monitor_sarif.py.
# A Go module listed in pipelines/go/untagged-release-modules.json has no semver
# module versions, so dependents select v0.0.0 pseudo-versions while advisories
# name its release tags. A fixable Grype match on such a module counts as fixed
# only when every fixed release, after the policy's advisory corrections,
# resolves through the module proxy to a pseudo-version at or below the
# installed one. Every other case, including a module outside the allowlist,
# an unknown tag or a proxy error, stays fixable. pipelines/go/remediate.yaml
# applies the same rule at build time from the same file.

from __future__ import annotations

import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Final

ROOT: Final = Path(__file__).resolve().parents[1]
POLICY_PATH: Final = ROOT / "pipelines/go/untagged-release-modules.json"
DEFAULT_PROXY: Final = "https://proxy.golang.org"
UNTAGGED_PSEUDO: Final = re.compile(r"^v0\.0\.0-[0-9]{14}-[0-9a-f]{12}$")
MODULE: Final = re.compile(r"^(?=.{1,255}$)[A-Za-z0-9][A-Za-z0-9._~-]*(?:/[A-Za-z0-9._~+-]+)+$")
RELEASE: Final = re.compile(r"^v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$")
RETRIES: Final = 5
RETRY_DELAY: Final = 5.0
TIMEOUT: Final = 30.0
PROXY_INFO_LIMIT: Final = 64 * 1024


class PolicyError(ValueError):
    pass


class Policy:
    def __init__(self, document: object) -> None:
        modules = document.get("modules") if isinstance(document, dict) else None
        if not isinstance(modules, dict):
            raise PolicyError("untagged Go module policy: modules must be an object")
        self.corrections: dict[str, dict[tuple[str, str], str]] = {}
        for module, entry in modules.items():
            if not isinstance(module, str) or MODULE.fullmatch(module) is None or not isinstance(entry, dict):
                raise PolicyError(f"untagged Go module policy: invalid module {module!r}")
            fixes = entry.get("fix-corrections", [])
            if not isinstance(fixes, list):
                raise PolicyError(f"untagged Go module policy: invalid fix corrections for {module}")
            corrections: dict[tuple[str, str], str] = {}
            for fix in fixes:
                values = [fix.get(name) if isinstance(fix, dict) else None for name in ("advisory", "published", "fixed")]
                if any(not isinstance(value, str) or not value for value in values):
                    raise PolicyError(f"untagged Go module policy: invalid fix correction for {module}")
                advisory, published, fixed = values
                if RELEASE.fullmatch(published) is None or RELEASE.fullmatch(fixed) is None:
                    raise PolicyError(f"untagged Go module policy: invalid fix correction for {module}")
                corrections[advisory, published.removeprefix("v")] = fixed.removeprefix("v")
            self.corrections[module] = corrections

    @classmethod
    def load(cls, path: Path = POLICY_PATH) -> Policy:
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise PolicyError(f"untagged Go module policy: cannot read {path}: {error}") from error
        return cls(document)

    def allows(self, module: str) -> bool:
        return module in self.corrections

    def corrected(self, module: str, identifiers: list[str], fixed: str) -> str:
        published = fixed.removeprefix("v")
        corrections = self.corrections.get(module, {})
        for identifier in identifiers:
            if (identifier, published) in corrections:
                return corrections[identifier, published]
        return published


def escape_path(value: str) -> str:
    # Module proxy case encoding: an upper-case letter becomes '!' and its lower case.
    return re.sub(r"[A-Z]", lambda letter: "!" + letter.group(0).lower(), value)


class ReleaseResolver:
    def __init__(
        self,
        proxy: str | None = None,
        retries: int = RETRIES,
        delay: float = RETRY_DELAY,
        timeout: float = TIMEOUT,
    ) -> None:
        self.proxy = (proxy or os.environ.get("GO_MODULE_PROXY") or DEFAULT_PROXY).rstrip("/")
        self.retries = retries
        self.delay = delay
        self.timeout = timeout
        self.cache: dict[tuple[str, str], str | None] = {}

    def fetch(self, url: str) -> tuple[int, bytes]:
        request = urllib.request.Request(url, headers={"User-Agent": "verity-untagged-go-modules/1"})
        for attempt in range(self.retries + 1):
            try:
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    length = response.headers.get("Content-Length")
                    try:
                        if length is not None and int(length) > PROXY_INFO_LIMIT:
                            return response.status, b""
                    except ValueError:
                        return response.status, b""
                    body = response.read(PROXY_INFO_LIMIT + 1)
                    return response.status, body if len(body) <= PROXY_INFO_LIMIT else b""
            except urllib.error.HTTPError as error:
                if error.code < 500 and error.code not in (408, 429):
                    return error.code, b""
                status = error.code
            except (OSError, TimeoutError, http.client.HTTPException):
                status = 0
            if attempt < self.retries:
                time.sleep(self.delay)
        return status, b""

    def resolve(self, module: str, fixed: str) -> str | None:
        # Try the semver form first, then the bare release tag (Istio tags omit the
        # v prefix). Only a 404 or 410 moves on; anything else leaves it unresolved.
        key = (module, fixed.removeprefix("v"))
        if key not in self.cache:
            self.cache[key] = None
            for query in (f"v{key[1]}", key[1]):
                url = f"{self.proxy}/{escape_path(module)}/@v/{urllib.parse.quote(escape_path(query))}.info"
                status, body = self.fetch(url)
                if status in (404, 410):
                    continue
                if status == 200:
                    try:
                        version = json.loads(body).get("Version")
                    except (ValueError, AttributeError):
                        version = None
                    if isinstance(version, str) and version:
                        self.cache[key] = version
                break
        return self.cache[key]


class UntaggedFixes:
    def __init__(self, policy: Policy | None = None, resolver: ReleaseResolver | None = None) -> None:
        self.policy = Policy.load() if policy is None else policy
        self.resolver = ReleaseResolver() if resolver is None else resolver

    def check(self, match: dict) -> tuple[bool, str] | None:
        """Return None when the policy does not apply, else (included, annotation)."""
        artifact = match.get("artifact") or {}
        vulnerability = match.get("vulnerability") or {}
        module = str(artifact.get("name") or "")
        installed = str(artifact.get("version") or "")
        fixes = [str(version) for version in (vulnerability.get("fix") or {}).get("versions") or [] if version]
        if (
            not fixes
            or artifact.get("type") != "go-module"
            or not self.policy.allows(module)
            or UNTAGGED_PSEUDO.fullmatch(installed) is None
        ):
            return None
        advisory = str(vulnerability.get("id") or "")
        identifiers = [advisory, *(str(related.get("id")) for related in match.get("relatedVulnerabilities") or [])]
        details = []
        for published in fixes:
            fixed = self.policy.corrected(module, identifiers, published)
            release = self.resolver.resolve(module, fixed)
            if release is None:
                return False, (
                    f"::warning title=Unresolved release fix::{advisory} in {module} {installed}: "
                    f"fixed release {fixed} is not a published module version or release tag"
                )
            # A release with a real module version sorts above any v0.0.0 pseudo-version;
            # pseudo-versions order by commit time, then hash, as in go/remediate.
            if UNTAGGED_PSEUDO.fullmatch(release) is None or release > installed:
                return False, ""
            details.append(f"{fixed} ({release})")
        return True, (
            f"::notice title=Untagged Go module includes fix::{advisory} in {module} {installed} "
            f"includes fixed release {' '.join(details)}"
        )

    def included(self, match: dict) -> bool:
        decision = self.check(match)
        return decision is not None and decision[0]


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit("usage: untagged_go_modules.py SATISFIED_JSON SCAN...")
    output, *scans = sys.argv[1:]
    try:
        fixes = UntaggedFixes()
    except PolicyError as error:
        raise SystemExit(f"error: {error}") from error
    satisfied: list[list[str]] = []
    seen: set[tuple[str, str, str]] = set()
    for scan in scans:
        for match in json.loads(Path(scan).read_text(encoding="utf-8")).get("matches") or []:
            key = (str(match["vulnerability"]["id"]), str(match["artifact"]["name"]), str(match["artifact"]["version"]))
            if key in seen:
                continue
            seen.add(key)
            decision = fixes.check(match)
            if decision is None:
                continue
            included, annotation = decision
            if annotation:
                print(annotation, flush=True)
            if included:
                satisfied.append(list(key))
    Path(output).write_text(json.dumps(satisfied) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()

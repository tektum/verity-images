#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import go_proxy_fixture  # noqa: E402
import untagged_go_modules as untagged  # noqa: E402

ISTIO = "istio.io/istio"
NEW = "v0.0.0-20260528141032-c51394391cf5"
OLD = "v0.0.0-20220101000000-0123456789ab"
RELEASE_1_12_8 = "v0.0.0-20220606151702-83a7f5f171c0"


def match(advisory: str, module: str, installed: str, *fixes: str, related: str = "CVE-2022-31045",
          kind: str = "go-module") -> dict:
    return {
        "artifact": {"name": module, "version": installed, "type": kind},
        "vulnerability": {"id": advisory, "severity": "High", "fix": {"versions": list(fixes)}},
        "relatedVulnerabilities": [{"id": related}],
    }


def write_info(root: Path, module: str, query: str, version: str) -> None:
    path = root / untagged.escape_path(module) / "@v" / f"{query}.info"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"Version": version}) + "\n", encoding="utf-8")


def requests(root: Path) -> list[str]:
    log = root / "requests.log"
    lines = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
    log.unlink(missing_ok=True)
    return lines


def assert_policy_error(document: object, message: str) -> None:
    try:
        untagged.Policy(document)
    except untagged.PolicyError as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError(f"accepted invalid policy: {document!r}")


def test_policy() -> None:
    policy = untagged.Policy.load()
    assert set(policy.corrections) == {ISTIO}
    assert policy.corrected(ISTIO, ["GHSA-xwx5-5c9g-x68x"], "1.12.18") == "1.12.8"
    assert policy.corrected(ISTIO, ["CVE-2022-31045", "GHSA-xwx5-5c9g-x68x"], "v1.12.18") == "1.12.8"
    assert policy.corrected(ISTIO, ["GHSA-other"], "1.12.18") == "1.12.18"
    assert policy.corrected(ISTIO, ["GHSA-xwx5-5c9g-x68x"], "1.13.5") == "1.13.5"
    assert not policy.allows("example.com/untagged")
    for document, message in (
        ({"modules": []}, "modules must be an object"),
        ({"modules": {"not a module": {}}}, "invalid module"),
        ({"modules": {"example.com/m": []}}, "invalid module"),
        ({"modules": {"example.com/m": {"fix-corrections": {}}}}, "invalid fix corrections"),
        ({"modules": {"example.com/m": {"fix-corrections": [{"advisory": "A", "published": "1.0.0"}]}}},
         "invalid fix correction"),
        ({"modules": {"example.com/m": {"fix-corrections": [{"advisory": "A", "published": "x", "fixed": "1.0.0"}]}}},
         "invalid fix correction"),
    ):
        assert_policy_error(document, message)
    assert untagged.escape_path("github.com/Azure/Go") == "github.com/!azure/!go"
    # Allowlist changes relax the gate and need security review.
    owners = (untagged.ROOT / ".github/CODEOWNERS").read_text(encoding="utf-8").splitlines()
    assert any(line.split()[:1] == ["/pipelines/go/untagged-release-modules.json"] and len(line.split()) > 1
               for line in owners)


def test_resolver(root: Path, proxy: str) -> None:
    write_info(root, ISTIO, "1.12.8", RELEASE_1_12_8)
    write_info(root, "example.com/tagged", "v1.2.0", "v1.2.0")
    resolver = untagged.ReleaseResolver(proxy, retries=2, delay=0)

    # The semver form first, the bare tag after a 404, and each fix only once.
    assert resolver.resolve(ISTIO, "1.12.8") == RELEASE_1_12_8
    assert resolver.resolve(ISTIO, "v1.12.8") == RELEASE_1_12_8
    assert requests(root) == ["/istio.io/istio/@v/v1.12.8.info", "/istio.io/istio/@v/1.12.8.info"]
    assert resolver.resolve("example.com/tagged", "1.2.0") == "v1.2.0"
    assert requests(root) == ["/example.com/tagged/@v/v1.2.0.info"]
    assert resolver.resolve(ISTIO, "1.12.18") is None

    # A server error is retried, then left unresolved instead of trying the bare tag.
    status = root / ISTIO / "@v" / "v1.13.5.info.status"
    status.write_text("500", encoding="utf-8")
    write_info(root, ISTIO, "1.13.5", RELEASE_1_12_8)
    requests(root)
    assert resolver.resolve(ISTIO, "1.13.5") is None
    assert requests(root) == ["/istio.io/istio/@v/v1.13.5.info"] * 3

    # An unreachable proxy is unresolved, not an error.
    assert untagged.ReleaseResolver("http://127.0.0.1:9", retries=0, delay=0).resolve(ISTIO, "1.12.8") is None


def test_untagged_fixes(root: Path, proxy: str) -> None:
    write_info(root, ISTIO, "1.12.8", RELEASE_1_12_8)
    write_info(root, "example.com/untagged", "1.0.0", "v0.0.0-20200101000000-0123456789ab")
    write_info(root, ISTIO, "1.20.0", "v1.20.0")
    resolver = untagged.ReleaseResolver(proxy, retries=0, delay=0)
    fixes = untagged.UntaggedFixes(untagged.Policy.load(), resolver)

    included, note = fixes.check(match("GHSA-xwx5-5c9g-x68x", ISTIO, NEW, "1.12.18"))
    assert included
    assert note == (
        "::notice title=Untagged Go module includes fix::GHSA-xwx5-5c9g-x68x in istio.io/istio "
        f"{NEW} includes fixed release 1.12.8 ({RELEASE_1_12_8})"
    )
    assert fixes.included(match("CVE-2022-31045", ISTIO, NEW, "1.12.18", related="GHSA-xwx5-5c9g-x68x"))

    # Every listed fix must be included.
    assert not fixes.included(match("GHSA-xwx5-5c9g-x68x", ISTIO, OLD, "1.12.18"))
    assert fixes.check(match("GHSA-xwx5-5c9g-x68x", ISTIO, OLD, "1.12.18")) == (False, "")
    assert not fixes.included(match("GHSA-two", ISTIO, NEW, "1.12.8", "1.20.0"))

    # Unresolvable fixes stay fixable and are reported.
    included, warning = fixes.check(match("GHSA-other", ISTIO, NEW, "1.12.18"))
    assert not included
    assert "fixed release 1.12.18 is not a published module version or release tag" in warning

    # Outside the allowlist, tagged selections, other ecosystems and unfixed findings are out of scope.
    for out_of_scope in (
        match("GHSA-untagged", "example.com/untagged", NEW, "1.0.0"),
        match("GHSA-xwx5-5c9g-x68x", ISTIO, "v1.12.0", "1.12.18"),
        match("GHSA-xwx5-5c9g-x68x", ISTIO, NEW, "1.12.18", kind="binary"),
        match("GHSA-xwx5-5c9g-x68x", ISTIO, NEW),
    ):
        assert fixes.check(out_of_scope) is None
        assert not fixes.included(out_of_scope)


class ProxyResponse:
    def __init__(self, body: bytes, length: str | None = None) -> None:
        self.status = 200
        self.headers = {} if length is None else {"Content-Length": length}
        self.body = body
        self.reads: list[int] = []

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def read(self, limit: int) -> bytes:
        self.reads.append(limit)
        return self.body


def test_bounded_proxy_response() -> None:
    resolver = untagged.ReleaseResolver("https://proxy.invalid", retries=0, delay=0)
    for body, length, read in (
        (b"ignored", str(untagged.PROXY_INFO_LIMIT + 1), False),
        (b"ignored", "invalid", False),
        (b"x" * (untagged.PROXY_INFO_LIMIT + 1), None, True),
    ):
        response = ProxyResponse(body, length)
        with patch.object(untagged.urllib.request, "urlopen", return_value=response):
            assert resolver.fetch("https://proxy.invalid/module/@v/v1.info") == (200, b"")
        assert response.reads == ([untagged.PROXY_INFO_LIMIT + 1] if read else [])

    response = ProxyResponse(b'{"Version":"v1.2.3"}', "20")
    with patch.object(untagged.urllib.request, "urlopen", return_value=response):
        assert resolver.fetch("https://proxy.invalid/module/@v/v1.info") == (200, b'{"Version":"v1.2.3"}')
    assert response.reads == [untagged.PROXY_INFO_LIMIT + 1]


def main() -> None:
    test_policy()
    test_bounded_proxy_response()
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        with go_proxy_fixture.serve(root) as proxy:
            test_resolver(root, proxy)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        with go_proxy_fixture.serve(root) as proxy:
            test_untagged_fixes(root, proxy)
    print("passed scripts/test_untagged_go_modules.py")


if __name__ == "__main__":
    main()

#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run (the publish-image action calls this once, before the scans and the attestation):
#   uv run scripts/trim_sbom.py SBOM [SBOM ...]
"""Drop per-file entries from an SPDX SBOM that is too large for Rekor, in place.

`cosign attest` records every SBOM in the public Rekor log. Rekor rejects a request body
above 24 MiB (25,165,824 bytes, measured against rekor.sigstore.dev), and the DSSE
envelope base64-encodes the SBOM, so the request is about 4/3 of its size. A 26 MB SBOM
(google-cloud-sdk, 32,822 file entries) failed with "giving up after 2 attempt(s)".

An SBOM at or under MAX_SBOM_BYTES is left byte-for-byte untouched. A larger one loses
its `files` array and every relationship, `hasFiles` entry, and `documentDescribes` entry
that names one of those files. Every package, CPE, purl, package-to-package relationship,
and the document metadata stay, so a scan of the trimmed SBOM matches the full one: Grype
matches packages, never file entries. The document gains a `comment` that records the
trim and the original file count. An SBOM that is still too large after the trim fails
closed here, with a clear message, instead of failing later inside Rekor.

Before the size check, every SBOM of an opted-in pure APKO image gains its declared
scan-identity packages (scan_identity.apply_apko). This is the one step every image runs
between Syft and the gate scan, and it is not part of any image's input digest, so a
pure APKO image opts in through its own metadata.yaml without changing other images.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Final

import scan_identity

# Rekor's request-body limit is 24 MiB, and the DSSE payload is base64, so an SBOM of
# 18 MiB is the largest that can be attested. Trimming above 12 MiB leaves a 4/3 request
# of 16 MiB, one third of the limit in headroom, and sits above every SBOM attested
# without trimming (the largest is 8.6 MB), so only oversized SBOMs are ever rewritten.
MAX_SBOM_BYTES: Final = 12 * 1024 * 1024
TRIM_COMMENT: Final = (
    "Per-file entries were removed for size before attestation: {files} file entries and "
    "{relationships} relationships that name them. Packages and package relationships "
    "are complete."
)


class TrimError(Exception):
    """The SBOM cannot be brought under the attestation size limit."""


def trim(document: dict) -> dict:
    """Remove per-file entries from a parsed SPDX document and record the removal."""
    files = document.get("files", [])
    removed = {file["SPDXID"] for file in files}
    relationships = [
        relationship
        for relationship in document.get("relationships", [])
        if relationship["spdxElementId"] not in removed and relationship["relatedSpdxElement"] not in removed
    ]
    dropped = len(document.get("relationships", [])) - len(relationships)

    trimmed = {key: value for key, value in document.items() if key not in {"files", "snippets"}}
    trimmed["relationships"] = relationships
    if "documentDescribes" in trimmed:
        trimmed["documentDescribes"] = [spdx_id for spdx_id in trimmed["documentDescribes"] if spdx_id not in removed]
    packages = []
    for package in document.get("packages", []):
        if "hasFiles" in package:
            package = {**package, "hasFiles": [spdx_id for spdx_id in package["hasFiles"] if spdx_id not in removed]}
            if not package["hasFiles"]:
                del package["hasFiles"]
        packages.append(package)
    trimmed["packages"] = packages

    note = TRIM_COMMENT.format(files=len(files), relationships=dropped)
    trimmed["comment"] = f"{document['comment']} {note}" if document.get("comment") else note
    return trimmed


def trim_file(path: Path, limit: int = MAX_SBOM_BYTES) -> str:
    """Trim one SBOM in place when it exceeds limit; return a one-line log message."""
    size = path.stat().st_size
    if size <= limit:
        return f"{path}: {size} bytes, within the {limit} byte attestation limit, unchanged"
    document = json.loads(path.read_text(encoding="utf-8"))
    if "files" not in document:
        raise TrimError(f"{path}: {size} bytes exceeds the {limit} byte limit and has no file entries to remove")
    count = len(document["files"])
    payload = json.dumps(trim(document), indent=2, ensure_ascii=False) + "\n"
    if len(payload.encode("utf-8")) > limit:
        raise TrimError(f"{path}: still over the {limit} byte limit after removing {count} file entries")
    handle, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(payload)
        os.replace(temporary, path)
    except BaseException:
        os.unlink(temporary)
        raise
    return f"{path}: trimmed {size} to {path.stat().st_size} bytes, removed {count} file entries"


def main(arguments: list[str]) -> int:
    if not arguments:
        print("usage: trim_sbom.py SBOM [SBOM ...]", file=sys.stderr)
        return 2
    try:
        for argument in arguments:
            if status := scan_identity.apply_apko(Path(argument)):
                print(status)
            print(trim_file(Path(argument)))
    except scan_identity.CoverageError as error:
        print(f"::error title=Scan coverage::{error}", file=sys.stderr)
        return 1
    except TrimError as error:
        print(f"::error title=SBOM too large to attest::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

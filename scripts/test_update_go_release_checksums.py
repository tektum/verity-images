#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import io
import json
import tempfile
from http.client import IncompleteRead
from pathlib import Path

import update_go_release_checksums


RECIPE = '''package:
  name: verity-go-1.25
  version: "1.25.14"
pipeline:
  - runs: |
      case "${{build.arch}}" in
        x86_64)
          archive=go${{package.version}}.linux-amd64.tar.gz
          sha256={amd64}
          ;;
        aarch64)
          archive=go${{package.version}}.linux-arm64.tar.gz
          sha256={arm64}
          ;;
      esac
'''


def response(payload: object):
    def open_url(_url: str, *, timeout: int):
        assert timeout == 30
        return io.BytesIO(json.dumps(payload).encode())

    return open_url


def main() -> None:
    old = "a" * 64
    amd64 = "b" * 64
    arm64 = "c" * 64
    payload = [{
        "version": "go1.25.14",
        "stable": True,
        "files": [
            {"os": "linux", "arch": "amd64", "filename": "go1.25.14.linux-amd64.tar.gz", "sha256": amd64},
            {"os": "linux", "arch": "arm64", "filename": "go1.25.14.linux-arm64.tar.gz", "sha256": arm64},
        ],
    }]
    with tempfile.TemporaryDirectory() as temporary:
        recipe = Path(temporary) / "melange.yaml"
        recipe.write_text(RECIPE.replace("{amd64}", old).replace("{arm64}", old), encoding="utf-8")
        assert update_go_release_checksums.update(recipe, response(payload)) == {
            "amd64": amd64,
            "arm64": arm64,
        }
        updated = recipe.read_text(encoding="utf-8")
        assert f"sha256={amd64}" in updated
        assert f"sha256={arm64}" in updated
        assert old not in updated
        invalid = [{
            **payload[0],
            "files": [
                {**payload[0]["files"][0], "sha256": "bad"},
                payload[0]["files"][1],
            ],
        }]
        try:
            update_go_release_checksums.update(recipe, response(invalid))
        except update_go_release_checksums.GoChecksumError:
            pass
        else:
            raise AssertionError("malformed upstream digest was accepted")
        assert recipe.read_text(encoding="utf-8") == updated

        class Truncated(io.BytesIO):
            def read(self, *_args, **_kwargs):
                raise IncompleteRead(b"partial")

        def incomplete(_url: str, *, timeout: int):
            assert timeout == 30
            return Truncated(b"[")

        original_opener = update_go_release_checksums.urllib.request.urlopen
        original_argv = update_go_release_checksums.sys.argv
        update_go_release_checksums.urllib.request.urlopen = incomplete
        update_go_release_checksums.sys.argv = ["update-go-checksums", str(recipe)]
        error = io.StringIO()
        try:
            with contextlib.redirect_stderr(error):
                assert update_go_release_checksums.main() == 1
            assert error.getvalue().startswith("error: ")
            assert recipe.read_text(encoding="utf-8") == updated
        finally:
            update_go_release_checksums.urllib.request.urlopen = original_opener
            update_go_release_checksums.sys.argv = original_argv
    print("passed scripts/test_update_go_release_checksums.py")


if __name__ == "__main__":
    main()

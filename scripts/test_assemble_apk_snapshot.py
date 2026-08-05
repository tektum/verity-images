from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

import apk_archive
from test_compose_apk_inputs import A, ARCHITECTURES, ASSEMBLE, B, compose


def fingerprint(key: Path) -> str:
    public = subprocess.run(
        ["openssl", "pkey", "-in", str(key), "-pubout", "-outform", "DER"],
        check=True,
        capture_output=True,
    ).stdout
    return hashlib.sha256(public).hexdigest()


def melange_shim(root: Path, *, hang: bool = False) -> tuple[Path, Path]:
    real = shutil.which("melange")
    assert real is not None
    real_mv = shutil.which("mv")
    assert real_mv is not None
    binary = root / "bin"
    binary.mkdir(parents=True, exist_ok=True)
    log = root / "melange.log"
    script = binary / "melange"
    script.write_text(
        "#!/bin/bash\n"
        "set -euo pipefail\n"
        f"printf '%s\\n' \"$*\" >> {log!s}\n"
        "[[ $1 != build && $1 != sign ]]\n"
        + ("sleep 30\n" if hang else "")
        + f"exec {real} \"$@\"\n",
        encoding="utf-8",
    )
    script.chmod(0o755)
    move = binary / "mv"
    move.write_text(
        "#!/bin/bash\n"
        "set -euo pipefail\n"
        f"{real_mv} \"$@\"\n"
        "[[ \"${APK_ASSEMBLE_INTERRUPT_AFTER:-}\" != \"$2\" ]] || kill -TERM \"$PPID\"\n",
        encoding="utf-8",
    )
    move.chmod(0o755)
    return binary, log


def assemble(
    staged: Path,
    output: Path,
    archive: Path,
    key: Path,
    binary: Path,
    *,
    timeout_seconds: str = "30",
    interrupt_after: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(ASSEMBLE), str(staged), str(staged / "metadata.json"), str(output), str(archive), str(key), fingerprint(key)],
        check=False,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "PATH": f"{binary}:{os.environ['PATH']}",
            "SOURCE_DATE_EPOCH": "0",
            "MELANGE_TIMEOUT_SECONDS": timeout_seconds,
            "APK_ASSEMBLE_INTERRUPT_AFTER": "" if interrupt_after is None else str(interrupt_after),
        },
    )


def staged_snapshot(root: Path) -> tuple[Path, Path]:
    base, staged, _ = compose(root)
    metadata = json.loads((staged / "metadata.json").read_text())
    metadata["fingerprint"] = fingerprint(base / "fixture.rsa")
    (staged / "metadata.json").write_text(json.dumps(metadata, sort_keys=True), encoding="utf-8")
    return base, staged


def deterministic_repository() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        base, staged = staged_snapshot(root)
        key = base / "fixture.rsa"
        binary, log = melange_shim(root)
        first = root / "first"
        first_archive = root / "first.tar.zst"
        second = root / "second"
        second_archive = root / "second.tar.zst"
        first_result = assemble(staged, first, first_archive, key, binary)
        assert first_result.returncode == 0, first_result.stderr
        second_result = assemble(staged, second, second_archive, key, binary)
        assert second_result.returncode == 0, second_result.stderr
        assert first_archive.read_bytes() == second_archive.read_bytes()
        for architecture in ARCHITECTURES:
            records = apk_archive.index_records((first / architecture / "APKINDEX.tar.gz").read_bytes())
            assert {record.name for record in records} == {A, B}
            reused = f"{architecture}/{B}-3.1.2-r3.apk"
            assert (base / reused).read_bytes() == (first / reused).read_bytes()
            bundle = f"bundles/{B}/{architecture}.json"
            assert (base / bundle).read_bytes() == (first / bundle).read_bytes()
        manifest = json.loads((first / "manifest.json").read_text())
        assert manifest["schemaVersion"] == 2
        commands = log.read_text().splitlines()
        assert commands and all(command.startswith("index ") for command in commands)
        assert all(A in command and B in command for command in commands)
        members = subprocess.run(
            ["tar", "--zstd", "-tf", str(first_archive)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        assert f"apk/bundles/{B}/x86_64.json" in members


def rejected_inputs_leave_no_output() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        base, staged = staged_snapshot(root)
        key = base / "fixture.rsa"
        binary, _ = melange_shim(root)
        cases = (
            lambda path: (path / "x86_64" / "undeclared-C.apk").write_bytes(b"C"),
            lambda path: (path / "bundles" / B / "x86_64.json").unlink(),
            lambda path: (path / "metadata.json").write_text("{", encoding="utf-8"),
        )
        for index, mutate in enumerate(cases):
            candidate = root / f"candidate-{index}"
            shutil.copytree(staged, candidate)
            mutate(candidate)
            output = root / f"output-{index}"
            archive = root / f"output-{index}.tar.zst"
            assert assemble(candidate, output, archive, key, binary).returncode != 0
            assert not output.exists() and not archive.exists()


def stale_and_hung_outputs_fail_closed() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        base, staged = staged_snapshot(root)
        key = base / "fixture.rsa"
        binary, _ = melange_shim(root)
        output = root / "output"
        archive = root / "output.tar.zst"
        output.mkdir()
        sentinel = output / "sentinel"
        sentinel.write_text("stale", encoding="utf-8")
        archive.write_text("stale", encoding="utf-8")
        assert assemble(staged, output, archive, key, binary).returncode != 0
        assert sentinel.read_text() == "stale" and archive.read_text() == "stale"

        output = root / "hung"
        archive = root / "hung.tar.zst"
        hanging_binary, _ = melange_shim(root / "hanging", hang=True)
        assert assemble(staged, output, archive, key, hanging_binary, timeout_seconds="1").returncode != 0
        assert not output.exists() and not archive.exists()


def repeated_interruptions_leave_no_output() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        base, staged = staged_snapshot(root)
        key = base / "fixture.rsa"
        binary, log = melange_shim(root, hang=True)
        for attempt in range(3):
            output = root / f"interrupted-{attempt}"
            archive = root / f"interrupted-{attempt}.tar.zst"
            previous = len(log.read_text().splitlines()) if log.exists() else 0
            process = subprocess.Popen(
                [str(ASSEMBLE), str(staged), str(staged / "metadata.json"), str(output), str(archive), str(key), fingerprint(key)],
                env={
                    **os.environ,
                    "PATH": f"{binary}:{os.environ['PATH']}",
                    "SOURCE_DATE_EPOCH": "0",
                    "MELANGE_TIMEOUT_SECONDS": "60",
                },
            )
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                current = len(log.read_text().splitlines()) if log.exists() else 0
                if current > previous:
                    break
                time.sleep(0.01)
            else:
                process.kill()
                raise AssertionError("assembler did not start index command")
            process.terminate()
            process.wait(timeout=5)
            assert process.returncode != 0
            assert not output.exists() and not archive.exists()


def interruption_after_output_publication_cleans_artifacts() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        base, staged = staged_snapshot(root)
        key = base / "fixture.rsa"
        binary, _ = melange_shim(root)
        output = root / "output"
        archive = root / "output.tar.zst"
        result = assemble(staged, output, archive, key, binary, interrupt_after=output)
        assert result.returncode == 130, result.stderr
        assert not output.exists() and not archive.exists()
        assert not list(root.glob(".assemble-apk.*"))


def interruption_after_archive_publication_cleans_artifacts() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        base, staged = staged_snapshot(root)
        key = base / "fixture.rsa"
        binary, _ = melange_shim(root)
        output = root / "output"
        archive = root / "output.tar.zst"
        result = assemble(staged, output, archive, key, binary, interrupt_after=archive)
        assert result.returncode == 130, result.stderr
        assert not output.exists() and not archive.exists()
        assert not list(root.glob(".assemble-apk.*"))


def main() -> None:
    deterministic_repository()
    rejected_inputs_leave_no_output()
    stale_and_hung_outputs_fail_closed()
    repeated_interruptions_leave_no_output()
    interruption_after_output_publication_cleans_artifacts()
    interruption_after_archive_publication_cleans_artifacts()


if __name__ == "__main__":
    main()

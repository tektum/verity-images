#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///

from __future__ import annotations

import serialize_workflow_dispatches


def main() -> None:
    pages = [
        {"workflow_runs": [
            {"id": 41, "status": "completed"},
            {"id": 42, "status": "in_progress"},
            {"id": 44, "status": "queued"},
        ]},
        {"workflow_runs": [
            {"id": 39, "status": "waiting"},
            {"id": 40, "status": "completed"},
            {"id": 42, "status": "in_progress"},
        ]},
    ]
    assert serialize_workflow_dispatches.older_active_runs(pages, 44) == [39, 42]
    assert serialize_workflow_dispatches.older_active_runs(pages, 39) == []
    for invalid in ([{"workflow_runs": [{}]}], [{"workflow_runs": "bad"}]):
        try:
            serialize_workflow_dispatches.older_active_runs(invalid, 44)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid workflow run response was accepted")
    print("passed scripts/test_serialize_workflow_dispatches.py")


if __name__ == "__main__":
    main()

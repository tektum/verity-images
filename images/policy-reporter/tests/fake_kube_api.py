"""Minimal Kubernetes API stub for the policy-reporter smoke test.

policy-reporter refuses to start unless API discovery finds a PolicyReport
group, then list-watches report metadata and fetches each full report. This
stub serves only the wgpolicyk8s.io/v1alpha2 group with one namespaced
PolicyReport and one ClusterPolicyReport, empty Namespace and Secret lists, and
logs every request path so a failing smoke test shows what the client asked for.
"""

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

GROUP = "wgpolicyk8s.io/v1alpha2"
PREFIX = "/apis/" + GROUP

POLICY_REPORT = {
    "apiVersion": GROUP,
    "kind": "PolicyReport",
    "metadata": {
        "name": "smoke-polr",
        "namespace": "smoke",
        "uid": "6d1f9a7e-1f38-4a51-9c0c-7d3b1b0e5a01",
        "resourceVersion": "11",
        "creationTimestamp": "2026-01-01T00:00:00Z",
    },
    "summary": {"pass": 1, "fail": 1, "warn": 0, "error": 0, "skip": 0},
    "results": [
        {
            "policy": "require-run-as-non-root",
            "rule": "run-as-non-root",
            "result": "fail",
            "severity": "high",
            "category": "Pod Security",
            "source": "smoke-source",
            "message": "smoke failing result",
            "timestamp": {"seconds": 1767225600, "nanos": 0},
            "resources": [
                {
                    "apiVersion": "v1",
                    "kind": "Pod",
                    "name": "smoke-pod",
                    "namespace": "smoke",
                    "uid": "0b8e2c64-0d3a-4c8e-8f53-2f6f4f6d2a11",
                }
            ],
        },
        {
            "policy": "disallow-latest-tag",
            "rule": "validate-image-tag",
            "result": "pass",
            "severity": "medium",
            "category": "Best Practices",
            "source": "smoke-source",
            "message": "smoke passing result",
            "timestamp": {"seconds": 1767225600, "nanos": 0},
            "resources": [
                {
                    "apiVersion": "v1",
                    "kind": "Pod",
                    "name": "smoke-pod",
                    "namespace": "smoke",
                    "uid": "0b8e2c64-0d3a-4c8e-8f53-2f6f4f6d2a11",
                }
            ],
        },
    ],
}

CLUSTER_POLICY_REPORT = {
    "apiVersion": GROUP,
    "kind": "ClusterPolicyReport",
    "metadata": {
        "name": "smoke-cpolr",
        "uid": "2c4a8f0e-5b7d-4e19-a3c6-9e1d2f3b4c22",
        "resourceVersion": "12",
        "creationTimestamp": "2026-01-01T00:00:00Z",
    },
    "summary": {"pass": 0, "fail": 0, "warn": 1, "error": 0, "skip": 0},
    "results": [
        {
            "policy": "require-namespace-labels",
            "rule": "check-team-label",
            "result": "warn",
            "severity": "low",
            "category": "Multi-Tenancy",
            "source": "smoke-source",
            "message": "smoke cluster warning",
            "timestamp": {"seconds": 1767225600, "nanos": 0},
            "resources": [
                {
                    "apiVersion": "v1",
                    "kind": "Namespace",
                    "name": "smoke",
                    "uid": "7a9b1c2d-3e4f-4a5b-8c6d-1e2f3a4b5c33",
                }
            ],
        }
    ],
}

DISCOVERY = {
    "kind": "APIResourceList",
    "apiVersion": "v1",
    "groupVersion": GROUP,
    "resources": [
        {
            "name": "policyreports",
            "singularName": "policyreport",
            "namespaced": True,
            "kind": "PolicyReport",
            "shortNames": ["polr"],
            "verbs": ["get", "list", "watch"],
        },
        {
            "name": "clusterpolicyreports",
            "singularName": "clusterpolicyreport",
            "namespaced": False,
            "kind": "ClusterPolicyReport",
            "shortNames": ["cpolr"],
            "verbs": ["get", "list", "watch"],
        },
    ],
}


def metadata_list(items):
    return {
        "kind": "PartialObjectMetadataList",
        "apiVersion": "meta.k8s.io/v1",
        "metadata": {"resourceVersion": "100"},
        "items": [
            {
                "kind": "PartialObjectMetadata",
                "apiVersion": "meta.k8s.io/v1",
                "metadata": item["metadata"],
            }
            for item in items
        ],
    }


def core_list(kind):
    return {"kind": kind, "apiVersion": "v1", "metadata": {"resourceVersion": "100"}, "items": []}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def chunk(self, data):
        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
        self.wfile.flush()

    def hold_watch(self, initial):
        # client-go list-watches through a streaming watch-list request: send
        # each existing object as ADDED and finish the initial state with the
        # initial-events-end bookmark, then keep the stream open and idle.
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            for item in metadata_list(initial)["items"]:
                self.chunk(json.dumps({"type": "ADDED", "object": item}).encode() + b"\n")
            bookmark = {
                "kind": "PartialObjectMetadata",
                "apiVersion": "meta.k8s.io/v1",
                "metadata": {
                    "resourceVersion": "100",
                    "annotations": {"k8s.io/initial-events-end": "true"},
                },
            }
            self.chunk(json.dumps({"type": "BOOKMARK", "object": bookmark}).encode() + b"\n")
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline and not STOP.is_set():
                time.sleep(0.5)
            self.wfile.write(b"0\r\n\r\n")
        except OSError:
            pass
        self.close_connection = True

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        path = url.path
        with open(LOG, "a", encoding="utf-8") as log:
            log.write(f"GET {self.path}\n")
        if query.get("watch") in (["true"], ["1"]):
            initial = []
            if query.get("sendInitialEvents") == ["true"]:
                initial = INITIAL.get(path, [])
            self.hold_watch(initial)
            return

        if path == PREFIX:
            self.send_json(200, DISCOVERY)
        elif path == PREFIX + "/policyreports":
            self.send_json(200, metadata_list([POLICY_REPORT]))
        elif path == PREFIX + "/clusterpolicyreports":
            self.send_json(200, metadata_list([CLUSTER_POLICY_REPORT]))
        elif path == PREFIX + "/namespaces/smoke/policyreports/smoke-polr":
            self.send_json(200, POLICY_REPORT)
        elif path == PREFIX + "/clusterpolicyreports/smoke-cpolr":
            self.send_json(200, CLUSTER_POLICY_REPORT)
        elif path == "/api/v1/namespaces":
            self.send_json(200, core_list("NamespaceList"))
        elif path.startswith("/api/v1/") and path.endswith("/secrets"):
            self.send_json(200, metadata_list([]))
        else:
            self.send_json(
                404,
                {
                    "kind": "Status",
                    "apiVersion": "v1",
                    "status": "Failure",
                    "reason": "NotFound",
                    "code": 404,
                    "message": "the server could not find the requested resource",
                },
            )


STOP = threading.Event()
LOG = sys.argv[2]
INITIAL = {
    PREFIX + "/policyreports": [POLICY_REPORT],
    PREFIX + "/clusterpolicyreports": [CLUSTER_POLICY_REPORT],
}

if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
    server.daemon_threads = True
    try:
        server.serve_forever()
    finally:
        STOP.set()

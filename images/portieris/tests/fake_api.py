"""Minimal Kubernetes API stub serving Portieris policy lists for the smoke test.

Namespace "trusted" has one ImagePolicy that allows registry.example/allowed/*
without signature checks. Every other namespace, and the cluster scope, has no
policies. Each request path is appended to the log file so the test can prove
Portieris consulted the API.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GROUP = "/apis/portieris.cloud.ibm.com/v1"
TRUSTED = {
    "apiVersion": "portieris.cloud.ibm.com/v1",
    "kind": "ImagePolicy",
    "metadata": {"name": "allow-example", "namespace": "trusted"},
    "spec": {"repositories": [{"name": "registry.example/allowed/*", "policy": {}}]},
}


def policy_list(kind, items):
    return {
        "apiVersion": "portieris.cloud.ibm.com/v1",
        "kind": kind,
        "metadata": {"resourceVersion": "1"},
        "items": items,
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        with open(sys.argv[2], "a", encoding="utf-8") as log:
            log.write(path + "\n")
        if path == "/healthz":
            body = {"status": "ok"}
        elif path == GROUP + "/namespaces/trusted/imagepolicies":
            body = policy_list("ImagePolicyList", [TRUSTED])
        elif path.startswith(GROUP + "/namespaces/") and path.endswith("/imagepolicies"):
            body = policy_list("ImagePolicyList", [])
        elif path == GROUP + "/clusterimagepolicies":
            body = policy_list("ClusterImagePolicyList", [])
        else:
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"kind":"Status","apiVersion":"v1","status":"Failure","code":404}')
            return
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1])), Handler).serve_forever()

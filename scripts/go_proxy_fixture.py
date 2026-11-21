#!/usr/bin/env python3
# How to run:
#   python3 scripts/go_proxy_fixture.py ROOT URL_FILE
#
# Test-only Go module proxy for scripts/untagged_go_modules.py. A file under ROOT
# answers 200 with its content, ROOT/<path>.status answers the code it holds, and
# anything else answers 404. Requested paths are appended to ROOT/requests.log.
# The CLI writes the base URL to URL_FILE and serves until killed.

from __future__ import annotations

import contextlib
import sys
import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def handler_for(root: Path) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            with (root / "requests.log").open("a", encoding="utf-8") as log:
                log.write(self.path + "\n")
            path = root / self.path.lstrip("/")
            status_path = path.with_name(path.name + ".status")
            if path.is_file():
                body = path.read_bytes()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            status = int(status_path.read_text(encoding="utf-8")) if status_path.is_file() else 404
            self.send_response(status)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *_args: object) -> None:
            pass

    return Handler


@contextlib.contextmanager
def serve(root: Path) -> Iterator[str]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(root))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}"
    finally:
        server.shutdown()
        server.server_close()


def main() -> None:
    root, url_file = (Path(argument) for argument in sys.argv[1:3])
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(root))
    url_file.write_text(f"http://127.0.0.1:{server.server_address[1]}\n", encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()

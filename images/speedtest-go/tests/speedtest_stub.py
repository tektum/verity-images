"""Local speedtest.net-compatible stub used only by the speedtest-go smoke test.

It answers the client's user-info request on HTTPS (aliased as
www.speedtest.net on an internal Docker network) and the custom server's
latency, download, and upload endpoints on plain HTTP.
"""
import http.server
import re
import ssl
import sys
import threading

CONFIG = (
    b'<?xml version="1.0" encoding="UTF-8"?><settings>'
    b'<client ip="10.250.0.2" lat="0.0" lon="0.0" isp="Verity Local Stub" country="ZZ"/>'
    b"</settings>"
)
CHUNK = b"\0" * (1024 * 1024)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("REQ %s\n" % (fmt % args))
        sys.stderr.flush()

    def reply(self, body, ctype="text/plain"):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        try:
            if path.endswith("/speedtest-config.php"):
                self.reply(CONFIG, "text/xml")
            elif path.endswith("/latency.txt"):
                self.reply(b"test=test\n")
            elif re.search(r"/random\d+x\d+\.jpg$", path):
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(CHUNK) * 2))
                self.end_headers()
                self.wfile.write(CHUNK)
                self.wfile.write(CHUNK)
            else:
                self.send_error(404)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

    def do_POST(self):
        try:
            remaining = int(self.headers.get("Content-Length") or 0)
            while remaining > 0:
                data = self.rfile.read(min(remaining, 65536))
                if not data:
                    return
                remaining -= len(data)
            self.reply(b"size=ok")
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass


tls = http.server.ThreadingHTTPServer(("", 443), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/certs/server.pem", "/certs/server.key")
tls.socket = ctx.wrap_socket(tls.socket, server_side=True)
threading.Thread(target=tls.serve_forever, daemon=True).start()
sys.stderr.write("STUB READY\n")
sys.stderr.flush()
http.server.ThreadingHTTPServer(("", 8080), Handler).serve_forever()

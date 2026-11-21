# Minimal stand-in for the configurable-http-proxy REST API the hub calls. It
# runs in a second container of the image under test, keeps routes in memory
# and logs each request so the smoke test can assert what the hub sent.
import json
import os

from tornado import ioloop, web

TOKEN = os.environ["CONFIGPROXY_AUTH_TOKEN"]
ROUTES = {}


class Routes(web.RequestHandler):
    def prepare(self):
        print(
            "proxy-api",
            self.request.method,
            self.request.path,
            "user-agent=" + self.request.headers.get("User-Agent", ""),
            self.request.body.decode() or "-",
            flush=True,
        )
        if self.request.headers.get("Authorization") != "token " + TOKEN:
            raise web.HTTPError(403)

    def get(self, spec=None):
        self.write(ROUTES)

    def post(self, spec):
        ROUTES[spec] = json.loads(self.request.body)
        self.set_status(201)

    def delete(self, spec):
        ROUTES.pop(spec, None)
        self.set_status(204)


web.Application([(r"/api/routes(/.*)?", Routes)]).listen(8001)
print("proxy-api listening", flush=True)
ioloop.IOLoop.current().start()

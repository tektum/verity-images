# Smoke-test hub configuration, mounted where the chart mounts its own.
import os

from tornado.httpclient import AsyncHTTPClient

# The chart's configuration routes the hub's HTTP client through pycurl.
AsyncHTTPClient.configure("tornado.curl_httpclient.CurlAsyncHTTPClient")

c.JupyterHub.authenticator_class = "dummy"
c.JupyterHub.spawner_class = "kubespawner.KubeSpawner"

# As in the chart, the proxy runs elsewhere: the hub only calls its REST API.
c.ConfigurableHTTPProxy.should_start = False
c.ConfigurableHTTPProxy.api_url = "http://proxy-api:8001"
c.JupyterHub.hub_bind_url = "http://:8081"
c.JupyterHub.hub_connect_url = "http://hub:8081"

c.JupyterHub.db_url = "sqlite:////srv/jupyterhub/jupyterhub.sqlite"
c.JupyterHub.cookie_secret_file = "/srv/jupyterhub/jupyterhub_cookie_secret"

c.Authenticator.admin_users = {"admin"}
c.JupyterHub.services = [{"name": "smoke", "api_token": os.environ["SMOKE_API_TOKEN"]}]
c.JupyterHub.load_roles = [{"name": "smoke", "scopes": ["admin:users"], "services": ["smoke"]}]

#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
api_pid=
container=

cleanup() {
  if [ -n "$container" ]; then
    docker rm -f "$container" >/dev/null 2>&1 || true
  fi
  if [ -n "$api_pid" ]; then
    kill "$api_pid" >/dev/null 2>&1 || true
    wait "$api_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

docker run --rm --network none "$image" version --client-only 2>&1 |
  grep -F 'v1.18.2' >/dev/null || fail 'Velero client version mismatch'
docker run --rm --network none --entrypoint /velero "$image" --help >/dev/null ||
  fail '/velero is not executable'
docker run --rm --network none --entrypoint /usr/bin/restic "$image" version >/dev/null ||
  fail 'restic is not executable'
container=$(docker create "$image")
docker cp "$container:/plugins" - >/dev/null || fail 'plugin directory is missing'
docker cp "$container:/usr/share/zoneinfo/UTC" - >/dev/null || fail 'timezone data is missing'
docker rm "$container" >/dev/null
container=

cat > "$work/api.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

V1 = {
    "backups": "Backup",
    "restores": "Restore",
    "schedules": "Schedule",
    "downloadrequests": "DownloadRequest",
    "deletebackuprequests": "DeleteBackupRequest",
    "podvolumebackups": "PodVolumeBackup",
    "podvolumerestores": "PodVolumeRestore",
    "backuprepositories": "BackupRepository",
    "backupstoragelocations": "BackupStorageLocation",
    "volumesnapshotlocations": "VolumeSnapshotLocation",
    "serverstatusrequests": "ServerStatusRequest",
}
V2 = {"datauploads": "DataUpload", "datadownloads": "DataDownload"}


def resource_list(group, resources):
    return {
        "apiVersion": "v1",
        "groupVersion": group,
        "kind": "APIResourceList",
        "resources": [
            {
                "kind": kind,
                "name": name,
                "namespaced": True,
                "singularName": "",
                "verbs": ["create", "delete", "get", "list", "patch", "update", "watch"],
            }
            for name, kind in resources.items()
        ],
    }


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api":
            return self.send_json(200, {"apiVersion": "v1", "kind": "APIVersions", "serverAddressByClientCIDRs": [], "versions": ["v1"]})
        if path == "/api/v1":
            return self.send_json(200, resource_list("v1", {}))
        if path == "/apis":
            versions = [{"groupVersion": "velero.io/v1", "version": "v1"}, {"groupVersion": "velero.io/v2alpha1", "version": "v2alpha1"}]
            return self.send_json(200, {"apiVersion": "v1", "kind": "APIGroupList", "groups": [{"name": "velero.io", "preferredVersion": versions[0], "versions": versions}]})
        if path == "/apis/velero.io/v1":
            return self.send_json(200, resource_list("velero.io/v1", V1))
        if path == "/apis/velero.io/v2alpha1":
            return self.send_json(200, resource_list("velero.io/v2alpha1", V2))
        if path == "/version":
            return self.send_json(200, {"gitVersion": "v1.28.0", "major": "1", "minor": "28"})
        if path == "/api/v1/namespaces/velero":
            return self.send_json(200, {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "velero"}, "status": {"phase": "Active"}})
        if path.endswith("/backupstoragelocations/default") or path.endswith("/secrets/velero-repo-credentials"):
            return self.send_json(404, {"apiVersion": "v1", "code": 404, "kind": "Status", "reason": "NotFound", "status": "Failure"})
        resource = path.rstrip("/").split("/")[-1]
        kinds = {**V1, **V2, "secrets": "Secret"}
        kind = kinds.get(resource)
        api_version = "velero.io/v2alpha1" if path.startswith("/apis/velero.io/v2alpha1/") else "velero.io/v1" if path.startswith("/apis/velero.io/v1/") else "v1"
        return self.send_json(200, {"apiVersion": api_version, "items": [], "kind": f"{kind}List" if kind else "List", "metadata": {"resourceVersion": "1"}})

    def do_POST(self):
        self.send_json(201, {"apiVersion": "v1", "data": {"repository-password": "c3RhdGljLXBhc3N3MHJk"}, "kind": "Secret", "metadata": {"name": "velero-repo-credentials", "namespace": "velero"}, "type": "Opaque"})

    do_DELETE = do_POST
    do_PATCH = do_POST
    do_PUT = do_POST

    def log_message(self, _format, *_args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY

python3 "$work/api.py" "$work/port" &
api_pid=$!
while [ ! -s "$work/port" ]; do
  kill -0 "$api_pid" 2>/dev/null || fail 'fake Kubernetes API failed to start'
done
port=$(cat "$work/port")

cat > "$work/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: smoke
    cluster:
      server: http://127.0.0.1:$port
contexts:
  - name: smoke
    context:
      cluster: smoke
      namespace: velero
      user: smoke
current-context: smoke
users:
  - name: smoke
    user:
      token: smoke
EOF

container=$(docker run --rm -d --network host \
  -e VELERO_NAMESPACE=velero \
  -v "$work/kubeconfig:/tmp/kubeconfig:ro" \
  "$image" server --kubeconfig=/tmp/kubeconfig --metrics-address=:8085)

deadline=$(( $(date +%s) + 30 ))
until curl -fsS http://127.0.0.1:8085/metrics > "$work/metrics" 2>/dev/null; do
  if ! docker inspect "$container" >/dev/null 2>&1; then
    docker logs "$container" >&2 || true
    fail 'Velero server exited before metrics became ready'
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    docker logs "$container" >&2 || true
    fail 'Velero metrics did not become ready'
  fi
done
grep -q '^go_goroutines ' "$work/metrics" || fail 'Velero metrics payload is invalid'

if invalid_output=$(docker run --rm --network none "$image" server --client-qps=-1 2>&1); then
  fail 'invalid server configuration unexpectedly succeeded'
fi
case "$invalid_output" in
  *"client-qps must be positive"*) ;;
  *)
    printf '%s\n' "$invalid_output" >&2
    fail 'invalid server configuration diagnostic missing'
    ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"

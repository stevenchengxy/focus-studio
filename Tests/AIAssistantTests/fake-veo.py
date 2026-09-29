#!/usr/bin/env python3
"""Offline Gemini Veo predictLongRunning/poll/download fixture.

Environment: FAKE_VEO_KEY, FAKE_VEO_LOG, FAKE_VEO_VIDEO.
No external network and no real account or billing.
"""
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import unquote

KEY = os.environ.get("FAKE_VEO_KEY", "FAKE-GOOGLE-KEY")
LOG = os.environ["FAKE_VEO_LOG"]
VIDEO = os.environ["FAKE_VEO_VIDEO"]
state = {"count": 0, "polls": {}}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def _json(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _log(self, body=None):
        with lock, open(LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "method": self.command, "path": unquote(self.path),
                "auth_ok": self.headers.get("x-goog-api-key") == KEY,
                "body": body,
            }) + "\n")

    def _auth(self):
        if self.headers.get("x-goog-api-key") == KEY:
            return True
        self._json(401, {"error": {"code": 401, "message": "Invalid key " + (self.headers.get("x-goog-api-key") or "")}})
        return False

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = json.loads(raw.decode()) if raw else {}
        self._log(body)
        if not self._auth():
            return
        path = unquote(self.path)
        if not path.startswith("/v1beta/models/veo-3.1-") or not path.endswith(":predictLongRunning"):
            self._json(404, {"error": {"message": "unknown endpoint"}})
            return
        instances = body.get("instances", [])
        params = body.get("parameters", {})
        if len(instances) != 1 or not instances[0].get("prompt") or params.get("durationSeconds") not in ("4", "6", "8"):
            self._json(400, {"error": {"message": "invalid Veo request"}})
            return
        with lock:
            state["count"] += 1
            name = "operations/veo-%d" % state["count"]
            state["polls"][name] = [0, "poll" in instances[0]["prompt"]]
        self._json(200, {"name": name})

    def do_GET(self):
        self._log()
        if not self._auth():
            return
        path = unquote(self.path)
        if path == "/v1beta/files/video.mp4":
            with open(VIDEO, "rb") as fh:
                data = fh.read()
            self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        prefix = "/v1beta/"
        name = path[len(prefix):] if path.startswith(prefix) else ""
        with lock:
            entry = state["polls"].get(name)
            if entry is not None:
                entry[0] += 1
                count, slow = entry
        if entry is None:
            self._json(404, {"error": {"message": "operation not found"}})
            return
        if slow and count == 1:
            self._json(200, {"name": name, "done": False})
            return
        host, port = self.server.server_address[:2]
        self._json(200, {
            "name": name, "done": True,
            "response": {"generateVideoResponse": {"generatedSamples": [{
                "video": {"uri": "http://%s:%d/v1beta/files/video.mp4" % (host, port)}
            }]}}
        })


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print("PORT %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

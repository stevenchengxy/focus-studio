#!/usr/bin/env python3
"""Local Volcengine Ark fixture: answers /images/generations and
/contents/generations/tasks like the real API so the Swift client and the
assistant tools can be exercised offline. No network, no real credentials.

Environment:
  FAKE_ARK_KEY    expected bearer token (default FAKE-TEST-KEY)
  FAKE_ARK_LOG    JSONL file that receives every request (method, path, auth, body)
  FAKE_ARK_IMAGE  file served at /files/image.jpg
  FAKE_ARK_VIDEO  file served at /files/video.mp4
Prints "PORT <n>" on stdout once listening.
"""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

KEY = os.environ.get("FAKE_ARK_KEY", "FAKE-TEST-KEY")
LOG = os.environ.get("FAKE_ARK_LOG")
IMAGE = os.environ.get("FAKE_ARK_IMAGE")
VIDEO = os.environ.get("FAKE_ARK_VIDEO")

state = {"tasks": {}, "counter": 0}
lock = threading.Lock()


def log_request(method, path, auth_ok, body):
    if not LOG:
        return
    with lock, open(LOG, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"method": method, "path": path, "auth_ok": auth_ok, "body": body}) + "\n")


class Handler(BaseHTTPRequestHandler):
    server_version = "fake-ark/1.0"

    def log_message(self, *_args):  # keep the test output quiet
        pass

    def _json(self, status, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _error(self, status, code, message):
        self._json(status, {"error": {"code": code, "message": message}})

    def _file(self, path, content_type):
        if not path or not os.path.isfile(path):
            self._error(404, "NotFound", "fixture file missing")
            return
        with open(path, "rb") as fh:
            data = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self):
        return self.headers.get("Authorization") == "Bearer " + KEY

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            return {"_invalid": raw.decode("utf-8", "replace")}

    def _origin(self):
        host, port = self.server.server_address[:2]
        return "http://%s:%d" % (host, port)

    def do_POST(self):
        body = self._body()
        auth_ok = self._authorized()
        log_request("POST", self.path, auth_ok, body)
        if not auth_ok:
            self._error(401, "AuthenticationError", "The API key in the request is missing or invalid. Bearer " + (self.headers.get("Authorization") or "")[7:])
            return
        if self.path == "/api/v3/images/generations":
            model = body.get("model", "")
            if model == "doubao-seedream-not-open":
                self._error(404, "ModelNotOpen", "The model or endpoint %s is not open" % model)
                return
            if "fail" in body.get("prompt", ""):
                self._error(400, "InvalidParameter", "prompt rejected by fixture")
                return
            self._json(200, {
                "model": model, "created": 1758500000,
                "data": [{"url": self._origin() + "/files/image.jpg", "size": body.get("size", "2560x1440")}],
                "usage": {"generated_images": 1, "output_tokens": 4096, "total_tokens": 4096},
            })
            return
        if self.path == "/api/v3/contents/generations/tasks":
            content = body.get("content") or []
            if not content or content[0].get("type") != "text" or not content[0].get("text"):
                self._error(400, "InvalidParameter", "content[0] must be the text prompt")
                return
            for item in content[1:]:
                kind = item.get("type")
                url = (item.get(kind) or {}).get("url", "") if kind else ""
                if kind not in ("image_url", "video_url", "audio_url") or not url:
                    self._error(400, "InvalidParameter", "bad content item %s" % json.dumps(item)[:80])
                    return
            with lock:
                state["counter"] += 1
                task_id = "cgt-fixture-%d" % state["counter"]
                polls_before_success = 2 if "slow" in content[0]["text"] else 0
                state["tasks"][task_id] = {"polls": 0, "before": polls_before_success, "cancelled": False}
            self._json(200, {"id": task_id})
            return
        self._error(404, "NotFound", "unknown route " + self.path)

    def do_GET(self):
        log_request("GET", self.path, self._authorized(), None)
        if self.path == "/files/image.jpg":
            self._file(IMAGE, "image/jpeg")
            return
        if self.path == "/files/video.mp4":
            self._file(VIDEO, "video/mp4")
            return
        if not self._authorized():
            self._error(401, "AuthenticationError", "The API key in the request is missing or invalid.")
            return
        prefix = "/api/v3/contents/generations/tasks/"
        if self.path.startswith(prefix):
            task_id = self.path[len(prefix):]
            with lock:
                task = state["tasks"].get(task_id)
                if task is None:
                    self._error(404, "NotFound", "task not found")
                    return
                task["polls"] += 1
                if task["cancelled"]:
                    status = "cancelled"
                elif task["polls"] <= task["before"]:
                    status = "queued" if task["polls"] == 1 else "running"
                else:
                    status = "succeeded"
            payload = {"id": task_id, "model": "doubao-seedance-2-0-mini-260615", "status": status,
                       "created_at": 1758500000, "updated_at": 1758500100}
            if status == "succeeded":
                payload["content"] = {"video_url": self._origin() + "/files/video.mp4"}
                payload["usage"] = {"completion_tokens": 123456, "total_tokens": 123456}
            self._json(200, payload)
            return
        self._error(404, "NotFound", "unknown route " + self.path)

    def do_DELETE(self):
        log_request("DELETE", self.path, self._authorized(), None)
        prefix = "/api/v3/contents/generations/tasks/"
        if self.path.startswith(prefix):
            task_id = self.path[len(prefix):]
            with lock:
                task = state["tasks"].get(task_id)
                if task is not None:
                    task["cancelled"] = True
            self._json(200, {"id": task_id, "status": "cancelled"})
            return
        self._error(404, "NotFound", "unknown route " + self.path)


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print("PORT %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

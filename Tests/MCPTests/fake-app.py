#!/usr/bin/env python3
"""A fake Focus Studio.app for focus-studio-mcp tests: serves the control
channel on a Unix socket the way the app's ControlServer does (JSON-RPC 2.0,
one message per line, hello before call) and logs every message it receives.
No real app, library, preferences or network are touched. Standard library only.

usage: fake-app.py SOCKET LOG [--protocol N] [--hello-delay SECONDS] [--app-path PATH]

LOG receives one JSON object per line: {"event": "accept"|"close", "connection": n}
or {"event": "message", "connection": n, "message": {...}}. A line "ready" on
stdout says the socket is listening. SIGTERM removes the socket and exits;
SIGKILL leaves a stale socket file behind, as a crashed app would. It also
exits when the process that started it goes away.

Calls by tool name:
- export_project: progress 0.25, 0.5 and 1 of 1 (only when the call carried
  progress_token), then a result;
- start_recording: runs until the helper cancels it (-32800);
- stop_recording: closes the connection without answering (the app quitting);
- list_assets: an unknown tool (-32602 with data.tool);
- anything else: a result with structuredContent echoing the tool, its
  arguments and working directory.
"""
import argparse
import json
import os
import signal
import socket
import sys
import threading
import time


class Log:
    def __init__(self, path):
        self.file = open(path, "a", encoding="utf-8", buffering=1)
        self.lock = threading.Lock()

    def write(self, **entry):
        with self.lock:
            self.file.write(json.dumps(entry) + "\n")


class Connection:
    def __init__(self, sock, number, options, log):
        self.sock = sock
        self.number = number
        self.options = options
        self.log = log
        self.write_lock = threading.Lock()
        self.greeted = False
        self.running = {}  # id (as JSON text) -> threading.Event
        self.closed = False

    def send(self, message):
        data = json.dumps(message).encode("utf-8") + b"\n"
        with self.write_lock:
            if self.closed:
                return
            try:
                self.sock.sendall(data)
            except OSError:
                pass

    def close(self):
        with self.write_lock:
            if self.closed:
                return
            self.closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()

    def serve(self):
        buffer = b""
        try:
            while True:
                chunk = self.sock.recv(65536)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if line.strip():
                        self.handle(json.loads(line))
        except OSError:
            pass
        self.log.write(event="close", connection=self.number)
        for event in self.running.values():
            event.set()
        self.close()

    def handle(self, message):
        self.log.write(event="message", connection=self.number, message=message)
        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params") or {}
        if method == "hello" and request_id is not None:
            def answer():
                time.sleep(self.options.hello_delay)
                self.greeted = True
                self.send({"jsonrpc": "2.0", "id": request_id, "result": {
                    "protocol": self.options.protocol, "app_version": "9.9.9-fake",
                    "app_path": self.options.app_path, "pid": os.getpid()}})
            threading.Thread(target=answer, daemon=True).start()
        elif method == "call" and request_id is not None:
            if not self.greeted:
                self.send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32002, "message": "Send hello before call."}})
            elif self.options.protocol != 1:
                self.send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32003, "message": "protocol mismatch"}})
            else:
                threading.Thread(target=self.call, args=(request_id, params), daemon=True).start()
        elif method == "cancel" and request_id is None:
            event = self.running.get(json.dumps(params.get("id")))
            if event is not None:
                event.set()

    def call(self, request_id, params):
        tool = params.get("tool")
        if tool == "export_project":
            if "progress_token" in params:
                for value in (0.25, 0.5, 1):
                    self.send({"jsonrpc": "2.0", "method": "progress",
                               "params": {"id": request_id, "progress": value, "total": 1, "message": "Exporting"}})
                    time.sleep(0.05)
            self.send({"jsonrpc": "2.0", "id": request_id, "result": {
                "content": [{"type": "text", "text": "Exported to /tmp/fake.mp4."}],
                "structuredContent": {"path": "/tmp/fake.mp4"}, "isError": False}})
        elif tool == "start_recording":
            event = threading.Event()
            self.running[json.dumps(request_id)] = event
            event.wait()
            self.send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32800, "message": "The call was cancelled."}})
        elif tool == "stop_recording":
            self.close()
        elif tool == "list_assets":
            self.send({"jsonrpc": "2.0", "id": request_id,
                       "error": {"code": -32602, "message": f"Unknown tool: {tool}", "data": {"tool": tool}}})
        else:
            self.send({"jsonrpc": "2.0", "id": request_id, "result": {
                "content": [{"type": "text", "text": f"{tool} ran in the fake app."}],
                "structuredContent": {"tool": tool, "arguments": params.get("arguments", {}),
                                      "working_directory": params.get("working_directory"),
                                      "progress_token": "progress_token" in params},
                "isError": False}})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("socket")
    parser.add_argument("log")
    parser.add_argument("--protocol", type=int, default=1)
    parser.add_argument("--hello-delay", type=float, default=0)
    parser.add_argument("--app-path", default="/Applications/Focus Studio Fake.app")
    options = parser.parse_args()
    log = Log(options.log)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(options.socket)
    os.chmod(options.socket, 0o600)
    server.listen(16)

    def stop(*_):
        try:
            os.unlink(options.socket)
        except OSError:
            pass
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)

    # Never outlive the test that started it (a killed or crashed test run).
    parent = os.getppid()

    def watch_parent():
        while os.getppid() == parent:
            time.sleep(0.5)
        stop()

    threading.Thread(target=watch_parent, daemon=True).start()
    print("ready", flush=True)
    number = 0
    while True:
        client, _ = server.accept()
        number += 1
        log.write(event="accept", connection=number)
        threading.Thread(target=Connection(client, number, options, log).serve, daemon=True).start()


if __name__ == "__main__":
    main()

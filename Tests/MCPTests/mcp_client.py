#!/usr/bin/env python3
"""Drives a built focus-studio-mcp over real stdio, the way Claude Code or
Codex would, and checks the protocol. Standard library only.

usage: mcp_client.py HELPER --catalog catalog.json --fixture v1-tools.txt
                     [--expect-version VERSION] [--handshake-only]

catalog.json is written by the Swift tests (MCPTests --dump): the catalog's
descriptors, which tools/list must equal, and the server instructions.
Every line the helper writes to stdout must be a JSON-RPC 2.0 message; the
helper runs in a scratch working directory and must exit 0 soon after its
stdin closes.
"""
import argparse
import ctypes
import fcntl
import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time

VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
NEWEST = VERSIONS[0]
SCHEMA_KEYWORDS = {"type", "description", "properties", "required", "items", "enum",
                   "minimum", "maximum", "minItems", "maxItems", "default"}
SCHEMA_TYPES = {"object", "array", "string", "number", "integer", "boolean"}
UNREACHABLE = "Focus Studio could not be reached"
IDLE_SECONDS = 2
PROJECT_ID = "8C0F4E4A-2B0A-4F3E-9C55-6A1B2C3D4E5F"
EXIT_TIMEOUT = 5


class Failure(Exception):
    pass


def check(condition, message):
    if not condition:
        raise Failure(message)


def is_jsonrpc(message):
    """A single JSON-RPC 2.0 request, notification or response."""
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        return False
    if "method" in message:
        return isinstance(message["method"], str) and ("id" not in message or isinstance(message["id"], (str, int)))
    return "id" in message and (("result" in message) != ("error" in message))


class Helper:
    """One helper process with a JSON-RPC client's helpers."""

    def __init__(self, path, env=None, stdin=subprocess.PIPE):
        self.cwd = tempfile.mkdtemp(prefix="focus-studio-mcp-client-")
        environment = dict(os.environ)
        # The M5 control channel must never launch the app from a test.
        environment["FOCUS_STUDIO_MCP_NO_LAUNCH"] = "1"
        environment.update(env or {})
        self.process = subprocess.Popen([path], stdin=stdin, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, cwd=self.cwd, env=environment)
        self.stdin = self.process.stdin
        self.incoming = queue.Queue()
        self.stderr = b""
        self.notifications = []
        self.pending = {}
        self.next_id = 1
        threading.Thread(target=self._read_stdout, daemon=True).start()
        self.stderr_reader = threading.Thread(target=self._read_stderr, daemon=True)
        self.stderr_reader.start()

    def _read_stdout(self):
        for raw in iter(self.process.stdout.readline, b""):
            self.incoming.put(raw)
        self.incoming.put(None)

    def _read_stderr(self):
        self.stderr = self.process.stderr.read()

    def send(self, message):
        self.send_raw(json.dumps(message).encode("utf-8") + b"\n")

    def send_raw(self, data):
        self.stdin.write(data)
        self.stdin.flush()

    def request(self, method, params=None, request_id=None):
        if request_id is None:
            request_id = self.next_id
            self.next_id += 1
        message = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)
        return request_id

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)

    def _read(self, deadline):
        remaining = max(0.0, deadline - time.monotonic())
        try:
            raw = self.incoming.get(timeout=remaining)
        except queue.Empty:
            return None
        if raw is None:
            raise Failure("the helper closed stdout; stderr:\n" + self.stderr.decode("utf-8", "replace"))
        check(raw.endswith(b"\n"), f"stdout line not newline-terminated: {raw[:200]!r}")
        try:
            message = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise Failure(f"stdout carried something that is not JSON: {raw[:200]!r}")
        check(is_jsonrpc(message), f"stdout carried something that is not JSON-RPC 2.0: {message!r:.300}")
        return message

    def response(self, request_id, timeout=10):
        """The response to request_id; notifications seen meanwhile are kept."""
        if request_id in self.pending:
            return self.pending.pop(request_id)
        deadline = time.monotonic() + timeout
        while True:
            message = self._read(deadline)
            if message is None:
                raise Failure(f"no response to request {request_id} within {timeout} s")
            if "method" in message:
                check("id" not in message, f"unexpected request from the helper: {message!r:.300}")
                self.notifications.append(message)
            elif message["id"] == request_id:
                return message
            else:
                self.pending[message["id"]] = message

    def drain(self, seconds):
        """Reads whatever arrives within `seconds`."""
        deadline = time.monotonic() + seconds
        while True:
            message = self._read(deadline)
            if message is None:
                return
            if "method" in message:
                self.notifications.append(message)
            else:
                self.pending[message["id"]] = message

    def call(self, method, params=None, timeout=10):
        return self.response(self.request(method, params), timeout)

    def initialize(self, version=NEWEST, capabilities=None):
        reply = self.call("initialize", {"protocolVersion": version, "capabilities": capabilities or {},
                                         "clientInfo": {"name": "mcp_client.py", "version": "1.0"}})
        self.notify("notifications/initialized")
        return reply

    def finish(self):
        """Closes stdin; the helper must exit 0 within EXIT_TIMEOUT seconds with
        nothing but JSON-RPC on stdout."""
        started = time.monotonic()
        self.stdin.close()
        try:
            status = self.process.wait(timeout=EXIT_TIMEOUT)
        except subprocess.TimeoutExpired:
            self.process.kill()
            raise Failure(f"the helper did not exit within {EXIT_TIMEOUT} s of stdin closing")
        elapsed = time.monotonic() - started
        # The reader thread has seen EOF once the process is gone; validate the rest.
        deadline = time.monotonic() + 2
        while True:
            try:
                message = self._read(deadline)
            except Failure as error:
                if "closed stdout" in str(error):
                    break
                raise
            if message is None:
                break
        self.stderr_reader.join(timeout=2)
        check(status == 0, f"exit status {status}; stderr:\n" + self.stderr.decode("utf-8", "replace"))
        return elapsed


def error_code(reply):
    return (reply.get("error") or {}).get("code")


def result_text(reply):
    content = (reply.get("result") or {}).get("content") or []
    return "\n".join(block.get("text", "") for block in content if block.get("type") == "text")


def schema_problems(schema, path):
    if not isinstance(schema, dict):
        return [f"{path} is not an object"]
    problems = [f"{path} uses {key}" for key in sorted(schema) if key not in SCHEMA_KEYWORDS]
    kind = schema.get("type")
    if not isinstance(kind, str) or kind not in SCHEMA_TYPES:
        return problems + [f"{path} needs exactly one type, has {kind!r}"]

    def matches(value):
        return {
            "string": isinstance(value, str),
            "boolean": isinstance(value, bool),
            "integer": isinstance(value, (int, float)) and not isinstance(value, bool) and float(value).is_integer(),
            "number": isinstance(value, (int, float)) and not isinstance(value, bool),
            "array": isinstance(value, list),
            "object": isinstance(value, dict),
        }[kind]

    if "enum" in schema and not (isinstance(schema["enum"], list) and schema["enum"] and all(map(matches, schema["enum"]))):
        problems.append(f"{path} enum must list {kind} values")
    if "default" in schema and not matches(schema["default"]):
        problems.append(f"{path} default is not a {kind}")
    if kind == "object":
        properties = schema.get("properties")
        if not isinstance(properties, dict):
            return problems + [f"{path} object without properties"]
        for name, child in sorted(properties.items()):
            problems += schema_problems(child, f"{path}.{name}")
        required = schema.get("required", [])
        if not (isinstance(required, list) and len(set(required)) == len(required) and all(name in properties for name in required)):
            problems.append(f"{path} required must name its properties once each")
    elif kind == "array":
        problems += schema_problems(schema.get("items"), f"{path}[]") if "items" in schema else [f"{path} array without items"]
    return problems


# MARK: - Scenarios

def negotiation(path, catalog, expected_version, results):
    for version in VERSIONS + ["2099-01-01", "2024-10-07"]:
        helper = Helper(path)
        reply = helper.initialize(version)
        result = reply.get("result") or {}
        negotiated = result.get("protocolVersion")
        check(negotiated == (version if version in VERSIONS else NEWEST), f"{version} negotiates {negotiated}")
        check(result.get("serverInfo") == {"name": "focus-studio", "title": "Focus Studio", "version": expected_version},
              f"serverInfo: {result.get('serverInfo')}")
        check(result.get("capabilities") == {"tools": {"listChanged": False}}, f"capabilities: {result.get('capabilities')}")
        check(result.get("instructions") == catalog["instructions"], "the catalog's instructions")
        ping = helper.call("ping")
        check(ping.get("result") == {}, f"ping: {ping}")
        call = helper.call("tools/call", {"name": "get_status", "arguments": {}})
        check(call.get("result", {}).get("isError") is True and UNREACHABLE in result_text(call), f"{version} tools/call: {call}")
        check("structuredContent" not in call["result"], "an error carries no structured content")
        helper.finish()
        results.append(f"{version}->{negotiated}")


def tools_list(path, catalog, fixture_names):
    helper = Helper(path)
    helper.initialize()
    reply = helper.call("tools/list")
    tools = (reply.get("result") or {}).get("tools")
    check(isinstance(tools, list), f"tools/list: {reply}")
    check("nextCursor" not in reply["result"], "one page")
    names = [tool.get("name") for tool in tools]
    check(names == fixture_names, f"tools/list names equal v1-tools.txt: {names}")
    expected = {entry["descriptor"]["name"]: entry for entry in catalog["tools"]}
    check(names == [entry["descriptor"]["name"] for entry in catalog["tools"]], "and the catalog's order")
    for tool in tools:
        name = tool["name"]
        entry = expected[name]
        check(tool == entry["descriptor"], f"{name} is listed exactly as the catalog describes it:\n{tool}\nvs\n{entry['descriptor']}")
        check(set(tool) == {"name", "title", "description", "inputSchema", "annotations"}, f"{name} fields: {sorted(tool)}")
        schema = tool["inputSchema"]
        problems = schema_problems(schema, name)
        check(not problems, f"{name} schema: {problems}")
        required = schema.get("required", [])
        check(("project_id" in required) == entry["requiresProjectID"], f"{name}: project_id required {entry['requiresProjectID']}")
        check(("project_id" in schema["properties"]) == entry["acceptsProjectID"], f"{name}: project_id offered {entry['acceptsProjectID']}")
        annotations = tool["annotations"]
        check(annotations.get("title") == tool["title"] and isinstance(annotations.get("readOnlyHint"), bool)
              and annotations.get("openWorldHint") is False, f"{name} annotations: {annotations}")
        if not annotations["readOnlyHint"]:
            check(isinstance(annotations.get("destructiveHint"), bool) and isinstance(annotations.get("idempotentHint"), bool),
                  f"{name} is a writer and says whether it is destructive: {annotations}")
    helper.finish()
    return len(tools)


def tool_calls(path, catalog):
    helper = Helper(path)
    helper.initialize()
    for entry in catalog["tools"]:
        name = entry["descriptor"]["name"]
        arguments = {"project_id": PROJECT_ID} if entry["acceptsProjectID"] else {}
        reply = helper.call("tools/call", {"name": name, "arguments": arguments})
        result = reply.get("result") or {}
        check(result.get("isError") is True, f"{name} answers isError: {reply}")
        check(all(block.get("type") == "text" for block in result.get("content", [])), f"{name}: text only")
        check(UNREACHABLE in result_text(reply) and name in result_text(reply), f"{name} says Focus Studio could not be reached: {reply}")
    # No arguments at all is a call too.
    bare = helper.call("tools/call", {"name": "list_projects"})
    check(bare.get("result", {}).get("isError") is True, f"no arguments: {bare}")
    # Unknown and withheld tools are protocol errors.
    unknown = helper.call("tools/call", {"name": "no_such_tool", "arguments": {}})
    check(error_code(unknown) == -32602 and "Unknown tool" in unknown["error"]["message"], f"unknown tool: {unknown}")
    for name in catalog["withheld"]:
        reply = helper.call("tools/call", {"name": name, "arguments": {}})
        check(error_code(reply) == -32602 and "not available" in reply["error"]["message"], f"{name} is withheld: {reply}")
    # Resources and prompts are not offered.
    for method in ["resources/list", "prompts/list"]:
        reply = helper.call(method)
        check(error_code(reply) == -32601, f"{method}: {reply}")
    # An argument the tool does not take is refused, naming the ones it takes.
    reply = helper.call("tools/call", {"name": "export_project",
                                       "arguments": {"project_id": PROJECT_ID, "frameRate": 60}})
    check(reply.get("result", {}).get("isError") is True and 'does not take "frameRate"' in result_text(reply)
          and '"frame_rate"' in result_text(reply), f"unknown argument: {reply}")
    # Malformed params are invalid params, not internal errors.
    for params in [{"name": "get_status", "arguments": [1, 2]}, {"arguments": {}}, None, {"name": 5}]:
        reply = helper.call("tools/call", params)
        check(error_code(reply) == -32602, f"malformed tools/call {params!r}: {reply}")
    helper.finish()


def batches(path):
    helper = Helper(path)
    helper.initialize("2025-03-26")
    # A batch is refused with -32600 for each request in it; the helper keeps answering.
    helper.send([{"jsonrpc": "2.0", "id": "b1", "method": "tools/call",
                  "params": {"name": "get_status", "arguments": {}}},
                 {"jsonrpc": "2.0", "id": "b2", "method": "ping"}])
    raw = helper.incoming.get(timeout=10)
    check(raw is not None, "the helper answers a batch")
    reply = json.loads(raw)
    check(isinstance(reply, list) and [item.get("id") for item in reply] == ["b1", "b2"]
          and all((item.get("error") or {}).get("code") == -32600 for item in reply), f"batch reply: {reply}")
    ping = helper.call("ping")
    check(ping.get("result") == {}, f"still answering after a batch: {ping}")
    helper.finish()


class RusageInfoV0(ctypes.Structure):
    """struct rusage_info_v0 from <libproc.h>."""
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("user_time", ctypes.c_uint64), ("system_time", ctypes.c_uint64),
                ("pkg_idle_wakeups", ctypes.c_uint64), ("interrupt_wakeups", ctypes.c_uint64),
                ("pageins", ctypes.c_uint64), ("wired_size", ctypes.c_uint64), ("resident_size", ctypes.c_uint64),
                ("phys_footprint", ctypes.c_uint64), ("proc_start_abstime", ctypes.c_uint64),
                ("proc_exit_abstime", ctypes.c_uint64)]


def wakeups(pid):
    """The process's wakeups so far (proc_pid_rusage)."""
    info = RusageInfoV0()
    status = ctypes.CDLL("/usr/lib/libproc.dylib").proc_pid_rusage(pid, 0, ctypes.byref(info))
    check(status == 0, f"proc_pid_rusage failed: {status}")
    return info.pkg_idle_wakeups + info.interrupt_wakeups


def idle_without_polling(path):
    """An idle helper blocks in read(2): it does not wake up to poll (the
    SDK's stdio transport does, about 100 times a second), and it never makes
    the stdin it shares with its client non-blocking."""
    read_end, write_end = os.pipe()
    # This process keeps its copy of the read end: the helper's stdin shares
    # its open file description, so its flags show here.
    helper = Helper(path, stdin=read_end)
    helper.stdin = os.fdopen(write_end, "wb")
    helper.initialize()
    check(helper.call("ping").get("result") == {}, "ping")
    time.sleep(0.3)
    before = wakeups(helper.process.pid)
    time.sleep(IDLE_SECONDS)
    idle = wakeups(helper.process.pid) - before
    check(helper.call("ping").get("result") == {}, "ping after idling")
    nonblocking = fcntl.fcntl(read_end, fcntl.F_GETFL) & os.O_NONBLOCK
    os.close(read_end)
    helper.finish()
    check(not nonblocking, "the helper made its stdin non-blocking")
    check(idle <= 5 * IDLE_SECONDS, f"{idle} wakeups in {IDLE_SECONDS} s idle: the helper polls")
    return idle


def progress_tokens(path):
    helper = Helper(path)
    helper.initialize()
    for token in ["progress-1", 7]:
        reply = helper.call("tools/call", {"name": "export_project", "arguments": {"project_id": PROJECT_ID},
                                           "_meta": {"progressToken": token}})
        check(reply.get("result", {}).get("isError") is True, f"a progress token does not change the answer: {reply}")
    helper.drain(0.2)
    for token in ["progress-1", 7]:
        values = [n["params"]["progress"] for n in helper.notifications
                  if n.get("method") == "notifications/progress" and n["params"].get("progressToken") == token]
        check(all(a < b for a, b in zip(values, values[1:])), f"progress for {token!r} increases: {values}")
    check(all(n.get("method") == "notifications/progress" for n in helper.notifications), f"only progress notifications: {helper.notifications}")
    helper.finish()


def cancellation(path):
    helper = Helper(path)
    helper.initialize()
    # Cancel a call right after sending it: it is answered or not (it may
    # already be done), and the helper carries on.
    call_id = helper.request("tools/call", {"name": "start_recording", "arguments": {"source": "display"}})
    helper.notify("notifications/cancelled", {"requestId": call_id, "reason": "user cancelled"})
    helper.notify("notifications/cancelled", {"requestId": 12345, "reason": "unknown request"})
    helper.notify("notifications/cancelled", {"reason": "no request id"})
    ping = helper.call("ping")
    check(ping.get("result") == {}, f"still answering after cancellations: {ping}")
    helper.drain(0.2)
    if call_id in helper.pending:
        check(helper.pending[call_id].get("result", {}).get("isError") is True, f"cancelled call: {helper.pending[call_id]}")
    helper.finish()


def malformed_input(path):
    helper = Helper(path)
    helper.initialize()
    helper.send_raw(b"this is not json\n")
    helper.send_raw(b"\n")
    ping = helper.call("ping")
    check(ping.get("result") == {}, f"still answering after bad input: {ping}")
    helper.drain(0.2)
    errors = [message for message in helper.pending.values() if "error" in message]
    check(any(message["error"].get("code") == -32700 for message in errors), f"a parse error is reported: {helper.pending}")
    helper.finish()


def logs_go_to_stderr(path):
    helper = Helper(path, env={"FOCUS_STUDIO_MCP_LOG_LEVEL": "trace"})
    helper.initialize()
    helper.call("tools/list")
    helper.call("tools/call", {"name": "get_status", "arguments": {}})
    helper.finish()
    check(b"focus-studio-mcp" in helper.stderr and b"tools/call" in helper.stderr, f"trace logs on stderr: {helper.stderr[:500]!r}")


def end_of_input(path):
    # Idle: stdin closes before anything was sent.
    idle = Helper(path)
    elapsed = idle.finish()
    check(elapsed < EXIT_TIMEOUT, "idle exit")
    # Piped: requests written and stdin closed at once, like `printf … | focus-studio-mcp`;
    # every request read is still answered.
    lines = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": NEWEST, "capabilities": {},
                                                                    "clientInfo": {"name": "pipe", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_status", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 4, "method": "ping"},
    ]
    with tempfile.TemporaryDirectory() as cwd:
        started = time.monotonic()
        completed = subprocess.run([path], input=b"".join(json.dumps(line).encode() + b"\n" for line in lines),
                                   capture_output=True, timeout=EXIT_TIMEOUT + 5, cwd=cwd,
                                   env={**os.environ, "FOCUS_STUDIO_MCP_NO_LAUNCH": "1"})
        piped_elapsed = time.monotonic() - started
    check(completed.returncode == 0, f"piped exit status {completed.returncode}: {completed.stderr!r}")
    raw_lines = completed.stdout.split(b"\n")
    check(raw_lines[-1] == b"", "stdout ends with a newline")
    messages = [json.loads(line) for line in raw_lines[:-1]]
    check(all(is_jsonrpc(message) for message in messages), f"piped stdout is JSON-RPC only: {completed.stdout[:300]!r}")
    answered = sorted(message["id"] for message in messages if "id" in message)
    check(answered == [1, 2, 3, 4], f"every piped request is answered before exit: {answered}")
    piped_call = next(message for message in messages if message.get("id") == 3)
    check(UNREACHABLE in result_text(piped_call), f"the piped call ran before the helper exited: {piped_call}")
    return elapsed, piped_elapsed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("helper")
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--expect-version", default="0.0.0-dev")
    parser.add_argument("--handshake-only", action="store_true")
    options = parser.parse_args()
    with open(options.catalog, encoding="utf-8") as file:
        catalog = json.load(file)
    with open(options.fixture, encoding="utf-8") as file:
        fixture_names = [line.strip() for line in file if line.strip() and not line.startswith("#")]
    helper = os.path.abspath(options.helper)
    step = "start"
    try:
        negotiated = []
        step = "version negotiation"
        negotiation(helper, catalog, options.expect_version, negotiated)
        if options.handshake_only:
            print(f"mcp_client.py: PASS (handshake: {', '.join(negotiated)}, serverInfo.version {options.expect_version})")
            return
        step = "tools/list"
        count = tools_list(helper, catalog, fixture_names)
        step = "tools/call"
        tool_calls(helper, catalog)
        step = "progress tokens"
        progress_tokens(helper)
        step = "cancellation"
        cancellation(helper)
        step = "batches"
        batches(helper)
        step = "malformed input"
        malformed_input(helper)
        step = "idle"
        idle_wakeups = idle_without_polling(helper)
        step = "logs on stderr"
        logs_go_to_stderr(helper)
        step = "end of input"
        idle, piped = end_of_input(helper)
    except (Failure, subprocess.TimeoutExpired, OSError, ValueError, KeyError) as error:
        print(f"mcp_client.py: FAIL ({step}): {error}", file=sys.stderr)
        sys.exit(1)
    print(f"mcp_client.py: PASS (negotiation {', '.join(negotiated)}; ping; tools/list = {count} catalog tools with conservative "
          f"schemas and annotations; every tool answers not reachable; unknown and withheld tools -32602; resources/prompts -32601; "
          f"unknown arguments refused; malformed params -32602; batches -32600; progress tokens; cancellation; parse errors; "
          f"idle without polling ({idle_wakeups} wakeups in {IDLE_SECONDS} s) with stdin left blocking; "
          f"logs on stderr only; stdout JSON-RPC only; exit 0 at end of input (idle {idle:.2f} s, piped {piped:.2f} s))")


if __name__ == "__main__":
    main()

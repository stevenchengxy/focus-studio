#!/usr/bin/env python3
"""Stdio smoke test for a bundled focus-studio-mcp (run by verify-release.sh).

usage: verify-mcp-helper.py HELPER TOOL_NAMES_FILE APP_VERSION [ARCH]

With ARCH (arm64 or x86_64) the helper runs as that slice (arch -ARCH).

Pipes initialize, notifications/initialized and tools/list into the helper
from a scratch working directory, closes stdin and checks that:
- the helper exits 0 within a few seconds;
- every line on stdout is a JSON-RPC 2.0 message, and both requests are answered;
- the negotiated protocol version is the one requested;
- serverInfo is focus-studio with the app's version (Bundle.main is the app);
- tools/list names exactly the tools in TOOL_NAMES_FILE, in order.
Prints one summary line. Standard library only.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

REQUESTED_VERSION = "2025-11-25"


def fail(message):
    print(f"MCP helper smoke test failed: {message}", file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) not in (4, 5):
        fail("usage: verify-mcp-helper.py HELPER TOOL_NAMES_FILE APP_VERSION [ARCH]")
    helper, names_file, app_version, *rest = sys.argv[1:]
    arch = rest[0] if rest else None
    # The helper runs in a scratch directory, so a relative path would not resolve.
    helper = os.path.abspath(helper)
    command = ["/usr/bin/arch", f"-{arch}", helper] if arch else [helper]
    slice_name = f" ({arch})" if arch else ""
    with open(names_file, encoding="utf-8") as file:
        expected = [line.strip() for line in file if line.strip() and not line.startswith("#")]
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": REQUESTED_VERSION, "capabilities": {},
                    "clientInfo": {"name": "verify-release", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    ]
    payload = b"".join(json.dumps(message).encode("utf-8") + b"\n" for message in messages)
    environment = {**os.environ, "FOCUS_STUDIO_MCP_NO_LAUNCH": "1"}
    with tempfile.TemporaryDirectory() as scratch:
        try:
            completed = subprocess.run(command, input=payload, capture_output=True, timeout=15, cwd=scratch, env=environment)
        except subprocess.TimeoutExpired:
            fail(f"the helper{slice_name} did not exit within 15 s of its stdin closing")
        except OSError as error:
            fail(f"could not start the helper{slice_name}: {error}")
    if completed.returncode != 0:
        fail(f"exit status {completed.returncode}{slice_name}: {completed.stderr.decode('utf-8', 'replace')[-500:]}")
    lines = completed.stdout.split(b"\n")
    if lines[-1] != b"":
        fail("stdout does not end with a newline")
    responses = {}
    for line in lines[:-1]:
        try:
            message = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            fail(f"stdout carried a line that is not JSON: {line[:200]!r}")
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            fail(f"stdout carried a line that is not JSON-RPC 2.0: {line[:200]!r}")
        if "method" not in message:
            if "id" not in message or ("result" in message) == ("error" in message):
                fail(f"malformed response: {line[:200]!r}")
            responses[message["id"]] = message
    if sorted(responses) != [1, 2]:
        fail(f"expected answers to requests 1 and 2, got {sorted(responses)}")
    initialize = responses[1].get("result") or {}
    negotiated = initialize.get("protocolVersion")
    if negotiated != REQUESTED_VERSION or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", negotiated or ""):
        fail(f"negotiated protocol version {negotiated!r}, requested {REQUESTED_VERSION}")
    server = initialize.get("serverInfo") or {}
    if server.get("name") != "focus-studio" or server.get("version") != app_version:
        fail(f"serverInfo {server}, expected focus-studio {app_version}")
    if initialize.get("capabilities") != {"tools": {"listChanged": False}}:
        fail(f"capabilities {initialize.get('capabilities')}")
    tools = (responses[2].get("result") or {}).get("tools") or []
    names = [tool.get("name") for tool in tools]
    if names != expected:
        fail(f"tools/list names {names}, expected {expected}")
    print(f"MCP helper{slice_name} answered over stdio: protocol {negotiated}, focus-studio {server['version']}, {len(names)} tools")


if __name__ == "__main__":
    main()

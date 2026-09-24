#!/usr/bin/env python3
"""End to end through the real pieces: this script is the MCP client (as
Claude Code would be), the real focus-studio-mcp binary is the server it
starts over stdio, and Focus Studio's real ControlServer, AutomationBridge
and StudioModel answer on the control socket. The regression harness
(Tests/FocusStudioAppRegression/MCPEndToEndRegression.swift) hosts the app
side on a temporary library and socket, with an approver that allows the
client, and runs this script; nothing real is touched.

usage: mcp_e2e.py HELPER --socket SOCKET --cwd FOLDER --fixture v1-tools.txt

FOLDER is the client's working directory: it holds clip.mp4, which is
imported by a relative path, and receives out/e2e.mp4. The helper runs with
FOCUS_STUDIO_CONTROL_SOCKET=SOCKET and FOCUS_STUDIO_MCP_NO_LAUNCH=1.

Sequence: initialize, tools/list, get_status, import_video, get_project,
add_zoom, update_settings, get_project, export_project (with progress),
rename_project, delete_project, list_projects, end of input. Prints one
PASS line with the project id, which the host checks against the library.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_client import Failure, Helper, check, result_text  # noqa: E402

CLIENT = {"name": "claude-code", "version": "2.1.0-e2e"}


def call(helper, name, arguments, token=None, timeout=120):
    params = {"name": name, "arguments": arguments}
    if token is not None:
        params["_meta"] = {"progressToken": token}
    reply = helper.call("tools/call", params, timeout=timeout)
    result = reply.get("result")
    check(isinstance(result, dict), f"{name}: {reply}")
    check(result.get("isError") is False, f"{name} failed: {result_text(reply)}")
    data = result.get("structuredContent")
    check(isinstance(data, dict), f"{name} has structured content: {reply}")
    return data, result_text(reply)


def progress_for(helper, token):
    return [n["params"] for n in helper.notifications
            if n.get("method") == "notifications/progress" and n["params"].get("progressToken") == token]


def run(options):
    with open(options.fixture, encoding="utf-8") as file:
        names = [line.strip() for line in file if line.strip() and not line.startswith("#")]
    helper = Helper(options.helper, cwd=options.cwd, env={
        "FOCUS_STUDIO_CONTROL_SOCKET": options.socket,
        "FOCUS_STUDIO_MCP_NO_LAUNCH": "1",
    })
    initialized = helper.initialize(client_info=CLIENT)
    check(initialized.get("result", {}).get("serverInfo", {}).get("name") == "focus-studio", f"initialize: {initialized}")

    tools = helper.call("tools/list").get("result", {}).get("tools", [])
    check([tool["name"] for tool in tools] == names, f"tools/list: {[tool['name'] for tool in tools]}")

    status, _ = call(helper, "get_status", {})
    check(status.get("library_count") == 0 and status.get("recording", {}).get("state") == "idle" and status.get("open_project_id") is None,
          f"get_status of an empty library: {status}")

    # A relative path resolves against the client's working directory.
    imported, text = call(helper, "import_video", {"path": "clip.mp4", "title": "E2E clip"}, token="import")
    project_id = imported.get("project_id")
    check(isinstance(project_id, str) and len(project_id) == 36, f"import_video returns the project id: {imported}")

    project, _ = call(helper, "get_project", {"project_id": project_id})
    check(project.get("title") == "E2E clip" and abs(project.get("duration", 0) - 2) < 0.3, f"get_project: {project}")

    zoom, _ = call(helper, "add_zoom", {"project_id": project_id, "start": 0.2, "end": 1.2, "x": 0.25, "y": 0.75, "scale": 1.8})
    check(zoom.get("zoom_count") == 1, f"add_zoom: {zoom}")

    settings, _ = call(helper, "update_settings", {"project_id": project_id, "padding": 24, "cornerRadius": 12, "frameRate": 24})
    after, _ = call(helper, "get_project", {"project_id": project_id})
    zooms = after.get("zooms", [])
    check(len(zooms) == 1 and zooms[0].get("start") == 0.2 and zooms[0].get("end") == 1.2 and zooms[0].get("x") == 0.25,
          f"the zoom is in the project: {zooms}")
    look = after.get("look", {})
    check(look.get("padding") == 24 and look.get("cornerRadius") == 12 and after.get("frame_rate") == 24,
          f"the settings are in the project: {look}, {after.get('frame_rate')} fps (update said {settings.get('changes')})")

    started = time.monotonic()
    exported, _ = call(helper, "export_project", {"project_id": project_id, "path": "out/e2e.mp4", "width": 1280}, token="export")
    output = os.path.join(os.path.realpath(options.cwd), "out", "e2e.mp4")
    check(os.path.realpath(exported.get("path", "")) == output, f"export_project writes into the working directory: {exported}")
    check(os.path.getsize(output) > 1000, f"the MP4 exists: {output}")
    with open(output, "rb") as file:
        check(file.read(12)[4:8] == b"ftyp", "the export is an MP4")
    values = [update["progress"] for update in progress_for(helper, "export")]
    check(len(values) >= 2 and all(a < b for a, b in zip(values, values[1:])), f"export progress increases: {values}")
    export_seconds = time.monotonic() - started

    renamed, _ = call(helper, "rename_project", {"project_id": project_id, "title": "E2E renamed"})
    check(renamed.get("title") == "E2E renamed", f"rename_project: {renamed}")
    listed, _ = call(helper, "list_projects", {})
    check([entry.get("title") for entry in listed.get("projects", [])] == ["E2E renamed"], f"list_projects after the rename: {listed}")

    deleted, text = call(helper, "delete_project", {"project_id": project_id})
    check(deleted.get("moved_to_trash") is True and "Trash" in text, f"delete_project: {deleted}")
    emptied, _ = call(helper, "list_projects", {})
    check(emptied.get("projects") == [], f"the library is empty again: {emptied}")

    helper.finish()
    return project_id, export_seconds, len(values)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("helper")
    parser.add_argument("--socket", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--fixture", required=True)
    options = parser.parse_args()
    options.helper = os.path.abspath(options.helper)
    try:
        project_id, export_seconds, progress_count = run(options)
    except (Failure, OSError, KeyError, ValueError) as error:
        print(f"mcp_e2e.py: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
    print(f"mcp_e2e.py: PASS project {project_id} (initialize, tools/list, get_status, import_video by a relative path, get_project, "
          f"add_zoom, update_settings, export_project to out/e2e.mp4 in {export_seconds:.1f} s with {progress_count} progress "
          f"notifications, rename_project, list_projects, delete_project to the Trash, exit at end of input)")


if __name__ == "__main__":
    main()

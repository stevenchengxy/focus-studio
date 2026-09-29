#!/usr/bin/env python3
"""Local JSONL protocol fixture. No network and no credential files are touched."""
import json
import os
import sys
import time

scenario = os.environ.get("FOCUS_STUDIO_CODEX_FIXTURE", "new-user")
authenticated = scenario in ("existing", "stale-model", "assistant-turn", "routing-recovery")
# assistant-turn: one-shot completions on dedicated threads (see completeText).
assistant_threads = 0
assistant_turns = 0
assistant_instructions = {}
pending_interrupt = None
delayed_completion = None
config_case = os.environ.get("FOCUS_STUDIO_CODEX_CONFIG_CASE", "configured")
config_read_cwd = None
configured_servers = {
    "normal-server": {"command": "/unused", "env": {"TOKEN": "DO_NOT_COPY_CONFIG_SECRET"}},
    "a.b": {"url": "https://fixture.invalid", "http_headers": {"Authorization": "DO_NOT_COPY_CONFIG_SECRET"}},
    'quote"back\\slash\nline': {"command": "/unused"},
    "features.shell_tool": {"command": "/unused", "enabled": False},
}

if len(sys.argv) > 1 and sys.argv[1] == "--version":
    # Version probing happens before any protocol traffic and never reads stdin.
    print("codex-cli 9.9.9")
    sys.exit(0)


# Discovery in the first server stays failed until the client launches a fresh
# process. The counter is test-only, outside any real credential directory.
launch_number = 0
if scenario == "routing-recovery":
    state_path = os.environ["FOCUS_STUDIO_CODEX_RECONNECT_STATE"]
    assert "CodexDirectorTests-" in state_path
    try:
        with open(state_path) as state:
            launch_number = int(state.read())
    except FileNotFoundError:
        pass
    launch_number += 1
    with open(state_path, "w") as state:
        state.write(str(launch_number))


def send(value):
    print(json.dumps(value), flush=True)


def validate_strict_schema(schema):
    if not isinstance(schema, dict):
        return
    if schema.get("type") == "object":
        assert schema.get("additionalProperties") is False, "strict output objects must be closed"
        assert set(schema.get("required", [])) == set(schema.get("properties", {})), "every property must be required"
    for key, value in schema.items():
        if isinstance(value, dict):
            validate_strict_schema(value)
        elif isinstance(value, list):
            for child in value:
                validate_strict_schema(child)


for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    request_id = request.get("id")
    params = request.get("params", {})
    request_log = os.environ.get("FOCUS_STUDIO_CODEX_REQUEST_LOG")
    if request_log:
        assert "CodexDirectorTests-" in request_log
        with open(request_log, "a") as log:
            log.write(str(method) + "\n")  # Method names only; never payloads or credentials.
    if request_id is None:
        continue
    result = {}
    if method == "initialize":
        if scenario == "config-error":
            # An older CLI rejecting a config.toml written by a newer one. The
            # secret-looking line must be redacted and only the last three
            # lines may be shown.
            for line in ("older diagnostic that must not be shown",
                         "warning: Authorization: Bearer FAKE-BEARER-TOKEN key=FAKE-KEY-VALUE sk-FAKESECRET123",
                         "Error loading configuration: unknown variant `ultra`, expected one of `minimal`, `low`, `medium`, `high`",
                         "in `model_reasoning_effort`"):
                print(line, file=sys.stderr, flush=True)
            sys.exit(1)
        if scenario == "slow-connect":
            time.sleep(0.35)
        if scenario not in ("existing", "stale-model", "assistant-turn", "routing-recovery"):
            assert 'cli_auth_credentials_store="keyring"' in sys.argv
            assert "CodexDirectorTests-" in os.environ.get("CODEX_HOME", "")
        result = {"userAgent": "fixture"}
    elif method == "account/read":
        assert params.get("refreshToken") is False
        if scenario == "routing-recovery" and launch_number == 1:
            send({"id": request_id, "error": {"code": -32603, "message": "workspace routing discovery failed"}})
            continue
        result = {"requiresOpenaiAuth": True,
                  "account": {"type": "chatgpt", "email": None, "planType": "test"} if authenticated else None}
    elif method == "model/list":
        assert authenticated
        if params.get("cursor") is None:
            result = {"data": [{"id": "model-first", "model": "model-first", "displayName": "First",
                                 "isDefault": False, "defaultReasoningEffort": "high", "inputModalities": ["text"]}],
                      "nextCursor": "page-two"}
        else:
            assert params["cursor"] == "page-two"
            result = {"data": [{"id": "model-default", "model": "model-default", "displayName": "Default",
                                 "isDefault": True, "defaultReasoningEffort": "medium", "inputModalities": ["text", "image"],
                                 "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "medium"}]}],
                      "nextCursor": None}
    elif method == "account/login/start":
        assert scenario not in ("existing", "stale-model", "routing-recovery")
        if scenario == "slow-login":
            time.sleep(0.35)
        if params["type"] == "apiKey":
            assert params.get("apiKey") == "FAKE-TEST-SECRET-NOT-A-REAL-KEY"
            authenticated = True
            result = {"type": "apiKey"}
        else:
            result = {"type": "chatgpt", "loginId": "fixture-login", "authUrl": "https://auth.openai.com/fixture-only"}
            if scenario == "instant-browser-login":
                authenticated = True
                print(json.dumps({"id": request_id, "result": result}) + "\n" + json.dumps({
                    "method": "account/login/completed", "params": {
                        "loginId": "fixture-login", "success": True, "error": None}}), flush=True)
                continue
    elif method == "account/login/cancel":
        assert params["loginId"] == "fixture-login"
    elif method == "account/logout":
        assert scenario not in ("existing", "stale-model", "routing-recovery")
        authenticated = False
    elif method == "config/read":
        # Legacy director setup/planning must not acquire assistant-only config
        # reads or override its inherited tools.
        assert scenario == "assistant-turn"
        assert params["includeLayers"] is False and "CodexDirectorTests-" in params["cwd"]
        config_read_cwd = params["cwd"]
        if config_case == "read-error":
            send({"id": request_id, "error": {"code": -32601, "message": "DO_NOT_SURFACE_CONFIG_SECRET"}})
            continue
        if config_case == "slow-read":
            time.sleep(2)
        if config_case == "missing-config":
            result = {}
        elif config_case == "invalid-servers":
            result = {"config": {"mcp_servers": ["malformed"]}}
        elif config_case == "invalid-server-entry":
            result = {"config": {"mcp_servers": {"broken": "DO_NOT_SURFACE_CONFIG_SECRET"}}}
        else:
            config = {"model": "model-default", "arbitrary_secret": "DO_NOT_COPY_CONFIG_SECRET"}
            if config_case == "null-servers":
                config["mcp_servers"] = None
            elif config_case != "no-servers":
                config["mcp_servers"] = configured_servers
            result = {"config": config, "origins": {}}
    elif method == "thread/start":
        if params.get("developerInstructions", "").startswith("Slow preparation."):
            time.sleep(2)
        assert authenticated
        assert params["model"] == "model-default"
        assert params["sandbox"] == "read-only"
        if scenario == "assistant-turn":
            assert config_read_cwd == params["cwd"]
            assert params["approvalPolicy"] == "never" and params["ephemeral"] is True
            assert params["config"] == {"features.shell_tool": False, "features.unified_exec": False,
                                        "features.apps": False, "features.multi_agent": False,
                                        "features.plugins": False, "web_search": "disabled",
                                        "mcp_servers": {} if config_case in ("no-servers", "null-servers")
                                        else {key: {"enabled": False} for key in configured_servers}}
            # Stable clients must not send experimental thread/start fields.
            # The installed app-server rejects environments without opt-in.
            assert "environments" not in params
            assistant_threads += 1
            thread_id = "assistant-thread-%d" % assistant_threads
            assistant_instructions[thread_id] = params["developerInstructions"]
            result = {"thread": {"id": thread_id}}
        else:
            assert "config" not in params
            result = {"thread": {"id": "fixture-thread"}}
    elif method == "turn/start" and scenario == "assistant-turn":
        assert params["effort"] in ("medium", "low")
        if "outputSchema" in params:
            validate_strict_schema(params["outputSchema"])
            assert set(params["outputSchema"]["properties"]) == {"response_json"}
            assert "serialized JSON string" in assistant_instructions[params["threadId"]]
        assistant_turns += 1
        thread_id = params["threadId"]
        turn_id = "assistant-turn-%d" % assistant_turns
        prompt = params["input"][0]["text"]
        if delayed_completion is not None:
            # The old turn finishes after the next request is sent but before
            # its turn/start ID has been acknowledged. It must be ignored.
            send(delayed_completion)
            delayed_completion = None
        if "diagnostic fixture" in prompt:
            send({"method": "item/started", "params": {"threadId": thread_id, "turnId": turn_id,
                  "item": {"type": "reasoning", "text": "SECRET_REASONING_MUST_NOT_LOG"}}})
            for _ in range(3):
                send({"method": "item/reasoning/textDelta", "params": {"threadId": thread_id, "turnId": turn_id,
                      "delta": "SECRET_REASONING_MUST_NOT_LOG"}})
            send({"method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id,
                  "item": {"type": "commandExecution", "command": "SECRET_COMMAND_MUST_NOT_LOG"}}})
        response = {"id": request_id, "result": {"turn": {"id": turn_id}}}
        if "slow" in prompt:
            # Answer only after turn/interrupt, with an interrupted turn.
            pending_interrupt = (thread_id, turn_id, "late completion" in prompt)
            send(response)
            continue
        if "fail" in prompt:
            turn = {"id": turn_id, "status": "failed", "error": {"message": "fixture failure"}}
        else:
            text = json.dumps({"reply": "echo: " + prompt, "schema": "outputSchema" in params,
                               "instructions": assistant_instructions[thread_id], "thread": thread_id,
                               "effort": params["effort"],
                               "images": [item for item in params["input"] if item["type"] == "localImage"]})
            if "outputSchema" in params:
                if prompt == "malformed envelope":
                    text = json.dumps({"response_json": "not JSON"})
                elif prompt == "non-object envelope":
                    text = json.dumps({"response_json": "[]"})
                else:
                    text = json.dumps({"response_json": text})
            turn = {"id": turn_id, "status": "completed", "items": [
                {"type": "agentMessage", "phase": "commentary", "text": "thinking"},
                {"type": "agentMessage", "phase": "final_answer", "text": text}]}
        completion = {"method": "turn/completed", "params": {"threadId": thread_id, "turn": turn}}
        if assistant_turns % 2 == 1:
            # Both lines land in one read: the completion is processed before the
            # awaiting caller learns its turn id and must not be lost.
            print(json.dumps(completion) + "\n" + json.dumps(response), flush=True)
        else:
            print(json.dumps(response) + "\n" + json.dumps(completion), flush=True)
        continue
    elif method == "turn/interrupt":
        assert scenario == "assistant-turn" and pending_interrupt is not None
        thread_id, turn_id, delay_completion = pending_interrupt
        assert params["threadId"] == thread_id and params["turnId"] == turn_id
        pending_interrupt = None
        if delay_completion:
            delayed_completion = {"method": "turn/completed", "params": {"threadId": thread_id, "turn": {
                "id": turn_id, "status": "completed", "items": [{"type": "agentMessage", "phase": "final_answer",
                "text": json.dumps({"response_json": json.dumps({"reply": "WRONG_OLD_RESULT"})})}]}}}
            send({"id": request_id, "result": {}})
            continue
        print(json.dumps({"id": request_id, "result": {}}) + "\n" + json.dumps({
            "method": "turn/completed", "params": {"threadId": thread_id, "turn": {
                "id": turn_id, "status": "interrupted"}}}), flush=True)
        continue
    elif method == "turn/start":
        assert params["effort"] == "medium"
        assert "outputSchema" in params
        if scenario == "slow-turn":
            time.sleep(0.35)
        plan = {"title": "Fixture demo", "summary": "Protocol validated", "capture": {
            "mode": "url", "url": "https://example.com", "windowTitle": None, "screenshotPath": None},
            "actions": [{"type": "wait", "seconds": 1, "x": None, "y": None,
                         "deltaX": None, "deltaY": None, "url": None, "label": None}]}
        completion = {"method": "turn/completed", "params": {"threadId": "fixture-thread", "turn": {
            "id": "fixture-turn", "status": "completed", "items": [{"type": "agentMessage",
            "phase": "final_answer", "text": json.dumps(plan)}]}}}
        print(json.dumps({"id": request_id, "result": {"turn": {"id": "fixture-turn"}}})
              + "\n" + json.dumps(completion), flush=True)
        continue
    else:
        raise AssertionError("Unexpected protocol method: " + str(method))
    send({"id": request_id, "result": result})

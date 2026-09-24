#!/usr/bin/env python3
"""Local JSONL protocol fixture. No network and no credential files are touched."""
import json
import os
import sys
import time

scenario = os.environ.get("FOCUS_STUDIO_CODEX_FIXTURE", "new-user")
authenticated = scenario in ("existing", "stale-model", "assistant-turn")
# assistant-turn: one-shot completions on dedicated threads (see completeText).
assistant_threads = 0
assistant_turns = 0
assistant_instructions = {}
pending_interrupt = None

if len(sys.argv) > 1 and sys.argv[1] == "--version":
    # Version probing happens before any protocol traffic and never reads stdin.
    print("codex-cli 9.9.9")
    sys.exit(0)


def send(value):
    print(json.dumps(value), flush=True)


for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    request_id = request.get("id")
    params = request.get("params", {})
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
        if scenario not in ("existing", "stale-model", "assistant-turn"):
            assert 'cli_auth_credentials_store="keyring"' in sys.argv
            assert "CodexDirectorTests-" in os.environ.get("CODEX_HOME", "")
        result = {"userAgent": "fixture"}
    elif method == "account/read":
        assert params.get("refreshToken") is False
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
                                 "isDefault": True, "defaultReasoningEffort": "medium", "inputModalities": ["text", "image"]}],
                      "nextCursor": None}
    elif method == "account/login/start":
        assert scenario not in ("existing", "stale-model")
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
        assert scenario not in ("existing", "stale-model")
        authenticated = False
    elif method == "thread/start":
        if params.get("developerInstructions") == "Slow preparation.":
            time.sleep(2)
        assert authenticated
        assert params["model"] == "model-default"
        assert params["sandbox"] == "read-only"
        if scenario == "assistant-turn":
            assert params["approvalPolicy"] == "never" and params["ephemeral"] is True
            assistant_threads += 1
            thread_id = "assistant-thread-%d" % assistant_threads
            assistant_instructions[thread_id] = params["developerInstructions"]
            result = {"thread": {"id": thread_id}}
        else:
            result = {"thread": {"id": "fixture-thread"}}
    elif method == "turn/start" and scenario == "assistant-turn":
        assert params["effort"] == "medium"
        assistant_turns += 1
        thread_id = params["threadId"]
        turn_id = "assistant-turn-%d" % assistant_turns
        prompt = params["input"][0]["text"]
        response = {"id": request_id, "result": {"turn": {"id": turn_id}}}
        if "slow" in prompt:
            # Answer only after turn/interrupt, with an interrupted turn.
            pending_interrupt = (thread_id, turn_id)
            send(response)
            continue
        if "fail" in prompt:
            turn = {"id": turn_id, "status": "failed", "error": {"message": "fixture failure"}}
        else:
            text = json.dumps({"reply": "echo: " + prompt, "schema": "outputSchema" in params,
                               "instructions": assistant_instructions[thread_id], "thread": thread_id})
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
        thread_id, turn_id = pending_interrupt
        assert params["threadId"] == thread_id and params["turnId"] == turn_id
        pending_interrupt = None
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

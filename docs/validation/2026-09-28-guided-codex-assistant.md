# Guided Codex assistant — 2026-09-28

Historical launcher-only validation for builds 24–26. It did not cover the ordinary conversational start path. The user subsequently reported that path could leave a recording running after a stale action failed; see [unified conversational recording](2026-09-28-unified-assistant.md) for the replacement flow and its separate evidence.

## Scope

The assistant opens on an automatic-demo launcher: enter a website, open it in a visible browser, describe a walkthrough, then explicitly start the task. The actual executing Codex connection is selected and checked for image support. Advanced account and external MCP settings remain separate tabs in one connection sheet.

The exact prepared window, goal and bounded task approval are bound together. The task records that window with Codex interaction tracking, automatic zoom, browser-content crop, 60 fps and audio disabled. The bound is 120 seconds of total task time (including model latency and pauses), with at most six pointer-action attempts. The recorder's own media duration retains its existing pause semantics.

Only fresh observations and actions for that recording, status, bounded waits, saved-project inspection and stopping are allowed in this scope. Other actions retain their ordinary confirmation/permission paths. New tasks do not inherit old conversation, draft-plan or active-project context. Cancel/error/timeout saves an owned live take; countdown cancellation discards only that take. A replacement/manual recording is never stopped by cleanup. Zero successful interactions produces a needs-attention result, not a successful demo claim.

The chat panel uses concise localized tool receipts with expandable details, a multiline composer, explicit Stop, and command-return to send. Hidden chat is inactive: it releases focus, stops voice input/output and unregisters shortcuts. Pending confirmations reveal the chat tab. Preparation state is shared across the former director destination and the assistant window.

`Sources/FocusStudio/Capture/EventMonitor.swift` and `Sources/FocusStudioCore/CursorMotion.swift` are unchanged from HEAD. The manual mouse algorithm is outside this change.

## Automated evidence

- `.artifacts/guided-demo-task-tests.log`: complete assistant suite, including guided-task scope, fresh frames, action/time limits, cancellation during live recording/countdown, replacement recording isolation, explicit video defaults, old-context isolation, browser preparation and history compatibility.
- `.artifacts/assistant-guided-build.log`: development build.
- `.artifacts/assistant-guided-app-tests.log`: app regression (recording lifecycle, exact visible browser-window preparation and existing recording/editor integrations).
- `.artifacts/assistant-guided-release24.log`: native release packaging and bundled helper verification.

## Live result

The canonical installed build 24 completed a real task through the launcher and existing ChatGPT/Codex connection. No external MCP pointer dispatch or manual zoom insertion was used in the recording. The page was `https://finlyze.ai/dashboard`. The explicit goal was two safe navigation clicks: open the visible Deep Analysis page, then return Home.

- Recording: `B6A01BBC-1579-4618-8CBB-A2865BE97C7B`.
- Saved project: `C7838E9A-A1D8-41C7-91ED-095C979D4D26`, subsequently renamed through MCP to `Finlyze · 一键 Codex 自动演示`.
- Duration 40.947 s; source 2992 × 1866; 63 cursor samples/events; 2 clicks; 0 rejected events.
- Clicks at 18.330 s `(0.052, 0.437)` and 30.897 s `(0.042, 0.294)` generated automatic 1.75× zooms at 18.230–19.750 s and 30.797–32.317 s.
- Preparation connected the actual executing Codex instance and opened the visible Chrome page. View Page returned to that browser. Start hid the recorder and began capture of the prepared window. Stop automatically brought the saved video editor forward.
- The assistant completion card reported 2 of 6 allowed actions and offered Open Recorded Video. Chat showed localized concise receipts with collapsed technical details and a factual completion reply.
- Hidden-chat keyboard check: enter an unsent draft, switch to Automatic Demo, press Command-Return, return to chat. Draft remained and no message was sent; the test draft was then cleared.

The exported `.artifacts/finlyze-demo/Finlyze-Guided-Codex-Demo-1080p.mp4` is H.264, 1920 × 1080, 30 fps, 40.966667 s, 5,438,902 bytes, no audio. `ffmpeg -v error ... -f null -` decoded the entire video without errors. Frame inspection confirmed the tracked pointer/zoom over Deep Analysis and the successful destination page. The source project retains its 60 fps recording settings; 30 fps was a per-export choice.

Visual evidence:

- `.artifacts/finlyze-demo/guided-demo-first-click.png`
- `.artifacts/finlyze-demo/guided-demo-analysis-page.png`
- `.artifacts/finlyze-demo/guided-assistant-chat-success.png`
- `.artifacts/finlyze-demo/guided-assistant-ready-build26.png`

Build 25 refines disabled button appearance and makes the prepared website host prominent alongside the exact window description. Build 26 fixes the Start / Finish and Save action bar at the bottom so it remains visible in smaller windows. Both use the same tested task and recording implementations. Development builds and native release verification passed; final installation logs are `.artifacts/assistant-guided-install26.log`, with recoverable previous bundles retained by the installer. The final installed launcher was rechecked with Codex connected and Finlyze prepared.

The existing manual cursor implementation is byte-for-byte unchanged. No new physical manual recording is claimed. The automatic task supports fresh-frame pointer movement, clicking and scrolling; credential entry and arbitrary text-input workflows are outside this slice.

# Codex interaction trace validation — 2026-09-27

## Scope

Build 21 adds a recorder-owned execution path for Codex. Manual recordings retain the original system event monitor, cursor smoothing, camera-follow and automatic zoom algorithms. The new pointer processing is isolated from manual recording.

Codex must start a window recording with `interaction_mode: "codex"`, observe it through `capture_recording_frame`, and use `perform_recording_action`. Arbitrary CUA/browser/AX actions are not intercepted. No browser extension or vision-based cursor recovery is claimed.

## Automated checks

- `swift build`: passes.
- Core permission/geometry/cursor/zoom suite: passes after final manual-path isolation. `CursorMotion.swift` and `EventMonitor.swift` have no diff from HEAD; legacy and system-source smoothing match the original sample-for-sample for all four styles.
- `scripts/test-codex-plan-runner.sh --skip-build`: passes. Native inputs are replaced by a test driver; this is not a desktop recording.
- `scripts/test-codex-connection.sh --skip-build`: passes with a fake Codex app-server, including image payloads. A real read-only app-server connection also passed (7 models; no authentication changes or model turn).
- `scripts/test-ai-assistant.sh --skip-build`: passes with visual observation, confirmations, invalidation and 24-step bound. Build 23 exposes 28 in-app tools, including shared read-only `get_status` and `get_project`; MCP retains its existing 26-tool catalog. Repeated project reads report trace statistics to the model without navigation or writes.
- `scripts/test-app-regression.sh --skip-build`: passes, including synthetic manual and execution trace save paths, source isolation, automatic zooms, pause/stale/foreign-session guards, persistence, window handoff and real bundled MCP helper transport against a temporary app model.
- `scripts/test-mcp.sh --skip-build`: passes with 26 tools and explicit external effects annotation on pointer actions.
- Localization: 926 matching keys.

Logs are under `.artifacts/interaction-*.log`. Synthetic manual tests are compatibility checks, not a claim of a new physical-mouse recording. The user asked to prioritize Codex live testing and preserve the manual algorithm.

## Live external Codex checks

Installed and verified the signed arm64 **1.12.0 build 21** in `/Applications/Focus Studio.app`. This already-running Codex chat invoked the production stdio MCP helper through `.artifacts/finlyze-demo/mcp_session.py`; no test transport or library mutations were used.

Recorded the visible Chrome Finlyze AI window with `interaction_mode: "codex"`, browser-content cropping, automatic zooms, 30 fps and both audio inputs off. Recording `DE45F2D1-6A72-4294-BA9C-78B1FBFF88F7` started at 14:23:56 UTC and completed after 120.095 recorded seconds. Starting revealed Chrome; timed completion brought the editor forward, confirmed from the actual installed UI.

Result: project `36D6F20E-42A7-46EE-A17C-550715E17257`, **Finlyze · Codex 自动鼠标与缩放验收**.

| Observed operation | Recorded click | Automatic zoom |
| --- | --- | --- |
| Home → 深度分析 | 35.128 s, (0.051, 0.435) | 35.028–36.548 s, 1.75× |
| Analysis → NVDA | 84.086 s, (0.370, 0.450) | 83.986–85.506 s, 1.75× |

Both actions used a fresh recording observation and `perform_recording_action`; subsequent screenshots confirmed the navigations. **No `add_zoom` was called.** `get_project` reported execution/overlay, 69 events and cursor samples, 2 clicks, 2 automatic zooms, and 0 rejected events. A read-only audit of the saved project found 67 moves and 2 clicks, unique event IDs, valid monotonic times, and exact agreement between trace clicks, cursor samples and zoom source IDs/targets. The 240-pixel top crop is applied once to all three render paths. Rendered frames at 35.6 and 84.5 seconds show the generated zooms and click feedback.

The full export `.artifacts/finlyze-demo/Finlyze-Codex-Auto-Trace-1080p.mp4` is 120.100 seconds, 1920×1080 H.264, 30 fps, no audio, 16,233,403 bytes. FFprobe inspection and full FFmpeg decode passed. A separate **28.967-second highlight**, `Finlyze-Codex-Auto-Demo-29s.mp4`, keeps source intervals 32–43 and 81–99 seconds and removes idle waiting only; it adds no cursor or zoom effects. Its full decode also passed. The complete editable take and full export remain intact.

## Unified in-app assistant

The installed app has a single assistant entry with conversation, recording plan and Codex connection. Live tests found and fixed two actual Codex integration defects: an initialized failed app-server was reused indefinitely, and generic `additionalProperties: true` output schemas were rejected by the current backend. Build 22 reconnects a failed transport and uses a strict, validated `response_json` wrapper for arbitrary tool arguments. Offline regression verifies recovery, healthy connection reuse, recursive strict schema compliance and invalid inner JSON rejection. The saved obsolete executable path was updated through the normal UI. No authentication or system proxy settings were changed.

Two build-22 in-app attempts successfully connected to the real Codex model, listed sources, started recording, attached a real screenshot and proposed the correct Home coordinate. Human/outer-agent confirmation latency exceeded the 60-second observation lifetime; the input was correctly refused, so these attempts do **not** count as successful click tracking. The first timed out at 180 seconds (project `65FFEF42-586A-4595-8077-24ED995EC10D`); the second was explicitly stopped. Both saved to the editor without manually inserted zooms. Build 23 also adds the missing shared project/status tools, allowing the assistant to inspect the factual trace and zoom result itself.

Build 22 full app regression and native runner tests passed after the cancellation/resize/off-screen fixes. Build 23 Swift build, full assistant regression, arm64 package/signature/resources/MCP verification and canonical installation passed. Logs: `.artifacts/interaction-{build,release,install}23.log`, `.artifacts/interaction-app-tests22.log`, `.artifacts/interaction-runner-tests22.log`, `.artifacts/assistant-project-inspection-tests.log`; the completed Codex fixture test receipt is `.artifacts/codex-connection-22-verified.md`.

The final **build-23 in-app live check passed** using the real Codex connection, the unified assistant UI and its normal confirmation cards. Recording `AC23A056-8CFC-40E4-978B-B12120B0E9A9` saved project `DD091CE9-ABDB-4FEC-8A71-6A807EE86A45` (renamed **Finlyze · 统一 AI 助手实录验收**), 53.813 seconds at 2992×1866. The model received the current capture image, selected Home at uncropped normalized (0.042, 0.294), and used `perform_recording_action`; Chrome subsequently displayed `finlyze.ai/dashboard`.

The saved result reports execution/overlay, **20 events / 20 cursor samples, 1 click at 45.631 s, 1 automatic zoom at 45.531–47.051 s (1.75×), 0 rejected events**. No manual zoom was added. `stop_recording` brought the editor forward, and the assistant's own `get_project` returned the trace and zoom counts. The external production MCP helper independently read the same saved result in build 23. The rendered frame at 46.1 seconds visibly places the arrow/click ring on Home while the camera is zoomed in.

UI evidence: `.artifacts/finlyze-demo/unified-assistant-build23-success.png`. Both external MCP and in-app Codex recording paths are verified; arbitrary independent CUA/browser clicks remain outside the supported trace path. The user requested preservation of manual recording, so no fresh physical-mouse test was attempted.

The build-23 take was exported through the production helper to `.artifacts/finlyze-demo/Finlyze-Unified-Assistant-Build23-1080p.mp4`: 53.833 seconds, 1920×1080 H.264 at 30 fps, no audio, 9,897,280 bytes. FFprobe inspection and complete FFmpeg decode passed. The app remains in this saved take's editor. No test videos, private screenshots or credentials were published.

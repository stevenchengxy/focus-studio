# Editor and recording flow — 2026-09-27

Base: `f992a9e` (pulled from origin/main), local branch `codex/editor-playback-polish`.

## Behavior

- Bottom transport: Space toggles play/pause; Left/Right step one frame; Shift+Left/Right move five seconds; Home/End seek to bounds. Text editing and IME input retain their keys. Repeated Space does not toggle repeatedly. Playback restarts from zero after the end.
- Exact seeks replace the old 80/120 ms seek thresholds, which prevented single-frame movement. Transport, timeline ruler and video track all use the same seek path.
- Timeline: stronger selected tracks, hover/pressed feedback, clearer handles and playhead, adaptive ruler, millisecond hover labels, chapter add/delete and shortcut help. Motion respects Reduce Motion.
- A recording hides the recorder before its countdown and activates the selected window's owning app. Accessibility raises the matching window by bounds/title when available, without asking for new permissions. Display/area recording reveals the underlying desktop. Cancellation or startup failure restores the recorder.
- Every successful saved stop opens the editor in front, including MCP and automatic duration stops. Concurrent stop callers save and activate once. The registered main editor window is preferred over panels or the assistant.
- No eligible interaction events: editor and MCP guidance explain browser/AX input limitations and how to add missing zooms from observed interaction times.

## Real Codex/MCP exercise

Registered the installed production helper with `codex mcp add focus-studio`. This already-running Codex chat cannot refresh its tool catalog, so calls were made through a local standard-library Python JSON-RPC client to the **production stdio helper**, without test environment overrides. A new Codex session can load the registered server normally.

The live sequence exercised status, sources, recording, timed completion, explicit stop, project inspection, rename, zoom style, add/remove zoom, chapters, bundled background music, sound effects, frame rendering and MP4 export. All project edits used the public tools or UI; library JSON was not edited.

Final project: `7D4B1060-4ECA-4AFD-956F-4C75DD0A261D`, “Finlyze · Codex 产品演示”.

Local output: `.artifacts/finlyze-demo/Finlyze-Codex-Demo-1080p.mp4`.

55.0 seconds, 1920×1080, H.264 at 30 fps, stereo AAC 48 kHz, 16,602,386 bytes. Full FFmpeg decode passed. Three manually authored zooms follow the actual interaction log; five chapters and bundled Product Demo music were added. No microphone or system sound was recorded. Browser chrome was cropped via the editor. Existing user-selected background styling was preserved.

The initial take explicitly disabled automatic zooms. A later 54.2-second diagnostic take enabled them and used native-app CUA coordinate clicks. Those demonstration clicks still did not appear in the system event trace; only one unrelated click at 46.088 s, y=0.096 was stored, outside the browser-content crop, so zero automatic zooms were correctly generated. This does **not** prove automatic detection of Codex clicks works. The final zooms were added with `add_zoom`, not recovered or automatically inferred by the recorder. Two earlier short diagnostic takes did not contain in-time demonstration clicks and are not evidence for event capture.

Transcript and frame samples remain under `.artifacts/finlyze-demo/` (local, ignored). No video or private demo content was pushed to GitHub.

## Validation

- Swift development build: passed.
- Localization: 915 matching English/Chinese keys and placeholders passed.
- MCP protocol/catalog/forwarder tests: passed, 24 tools.
- Permission tests and editor regression suite: run during initial editor pass; subsequent flow regression and installed-app checks recorded below.
- Updated complete app regression suite: passed, including pre-countdown target handoff, exact-window matching, external/timed stops and joined-stop activation once.
- Signed arm64 app package verified; installed as **1.12.0 (build 20)** through the normal installer. Build 19 recovery copy: `/Applications/.focusstudio-install-A1466BC2-BE52-489A-9149-5C4A92C7C019/previous.bundle`.
- Installed build 20 reported Screen Recording, Accessibility and Input Monitoring granted. Its 20-second live MCP test hid Focus Studio's main window from the on-screen source list while recording, then automatically opened the saved clip in the editor after timed completion.
- Live UI checks on the saved test clip: text field accepted `录制流程 验证` including Space with playback stopped; playback button then Space paused at 0.716 s; Right moved to the next frame boundary at 0.733 s; End sought to 20.068 s and Space restarted at zero; chapter add followed by Backspace removed the selected chapter.
- Diagnostic takes were retained and named; the final demo remains a separate editable project. No screen/audio permissions were changed.

# Build 56 — timeline pointer and responsive editing

The editor now distinguishes a **candidate** frame from the committed playhead. Moving the pointer over the timeline draws a faint, frame-snapped guide and timecode without playing, seeking, saving, or changing the solid white playhead. Clicking or dragging the ruler commits the frame once on mouse-up and pauses playback. Clicking a clip selects it; its body no longer jumps to that clip's start. Trim handles, zoom handles, and transitions keep their own gestures.

During chapter drags, only local artwork changes until release. Zoom and clip trims already followed this pattern. The preview now coalesces rapid seek requests to the latest position, cancels obsolete seeks, and reuses static background/mask/shadow render graphs. This removes repeated exact decoding from ordinary pointer motion; no FPS measurement was made, so this is not a claim that every long project is free of lag.

For AI editing, `resolve_timeline_frame` is read-only and maps an output time or zero-based frame to its clip, source time, and split eligibility without moving the user's playhead. `capture_frame(exact_frame: true)` checks a precise rendered frame and reports whether AVFoundation delivered the requested frame. The normal fast capture path is unchanged. The recommended flow is `get_timeline` → `resolve_timeline_frame` → optional exact `capture_frame` → `split_clip` with the returned time and clip ID.

Validation:

- `zsh scripts/test.sh`: PASS, including editor frame snapping/end bounds, rendering E2E, AI assistant, MCP protocol and live-socket regression.
- `FOCUS_STUDIO_ARCHS=arm64 zsh scripts/build-app.sh`: PASS; bundled MCP helper reports 47 tools. Build 56 installed and signature verified at `/Applications/Focus Studio.app`.
- Native editor: starting playback, then clicking the ruler paused at `00:09.033`; selecting clip 2 left that time unchanged; a ruler drag committed `00:11.900` on release; zooming from 100% to 200% left it unchanged. The original project was returned to 100%, clip 1 selected, and `00:16.500`.
- Live Codex MCP `get_status`: Focus Studio 1.12.0 build 56, recording idle and the expected project open.

The computer-use API can click and drag but cannot issue a button-up pointer move, so the faint hover guide was verified by code path and frame math regression rather than a native screenshot. The remaining long-timeline FPS baseline is tracked in issue #8.

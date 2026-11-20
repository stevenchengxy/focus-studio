# Cursor stability and system capture picker — 1.14.8 (71)

Tracked in [#38](https://github.com/stevenchengxy/focus-studio/issues/38).

## Behavior

The shared cursor finishing pass simplifies confirmed free arrow movement with bounded spatial deviation. Clicks, mouse-button state changes, cursor-kind changes and dwell intervals anchor the path. Drag and semantic hover samples remain exact. Optional `isDragging` metadata survives decoding, timeline remapping and crop transforms; missing legacy metadata is unknown rather than assumed unpressed. No raw recording or user project was rewritten by this validation.

Camera following uses a true centre dead zone and analytically integrated critical damping. Edited shots and execution-trace discontinuities reset inertia. Preview and export share `ProjectFrameRenderer`; path finishing is prepared once, not recomputed per video frame.

On macOS 15.2+, manual capture uses the selected `SCContentFilter` for start, resume and screenshots. No broad desktop enumeration is added to that path. Area capture, macOS 15.0/15.1 and MCP source IDs retain their previous paths. Full-display system capture hides floating controls before streaming and uses menu-bar controls. A latched system-stop signal allows the writer to drain before classifying a concurrent Finish/Pause error.

## Verification

- `swift run FocusStudioPermissionTests`: PASS, including legacy Codable, exact rapid clicks 18 ms apart, final-frame click, 150 ms hover, drag/hand paths, edited metadata, mouse-up sampling, camera dead zone and cut isolation.
- Synthetic free-motion test: finished path length 64.0% of raw. This is fixture evidence, not a claim that all recordings improve by 36%.
- 10-minute/72,001-sample debug fixture: preprocessing 2.638 seconds; finite output, no per-frame simplification.
- `scripts/test-app-regression.sh`: PASS, including picker cancellation, failure, retired callbacks, MCP/toolbar exclusion, recording lifecycle, input protection, autosave and MCP end-to-end import/edit/export.
- `scripts/test-system-capture-stop.sh`: PASS after the final stop race fix, including removal failure followed by a late system-stop notification and writer completion; genuine writer failure remains an error.
- `FocusStudioE2E --cursor-motion-only`: PASS through the production compositor. Two 7-second, 960×540, 24 fps movies, 12 exact decoded PNG frames and distinct rendered motion. Source is an explicitly synthetic grid, with free transit, click/dwell, quiet-zone jitter, protected drag and I-beam hover.
- Side-by-side comparison: 1920×540, 168 decoded frames, exactly 7 seconds. Left is smoothing off; right is smooth. Both use the new camera implementation; this is not a before/after comparison of the old camera code.
- Universal release build and package verification: PASS, including signatures, resources, matching 1,550-key localization catalogs and 54 MCP tools over stdio on arm64 and x86_64.

Logs and generated videos live under `.artifacts/` and are not part of the repository. The render fixture is reproducible with:

```sh
swift run FocusStudioE2E --cursor-motion-only --output-dir .artifacts/cursor-stability
```

## Remaining real-device acceptance

This run did not exercise the system picker's successful native selection UI or a first-ever screen-sharing consent. Cancellation/state tests do not establish these behaviors. Manually verify window/display selection, full-display output without floating controls, pause/resume, source disappearance and macOS Stop Sharing on supported macOS versions. The existing machine already grants broad Screen Recording permission, so a fresh account/device is needed to prove limited picker-only authorization. Keep #38 open for that acceptance.

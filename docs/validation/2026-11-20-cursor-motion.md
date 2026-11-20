# Cursor motion and Zoom pacing — 1.14.10 (73)

## Changes

The previous finisher interpolated across event-free intervals, bypassed filtering for small hover jitter, and treated every hand / I-beam sample as an anchor. Shape cross-fades could overlap two pointers. Camera following could react independently of authored zoom movement. Native mouse callbacks used receipt time rather than physical event time.

The new finisher holds through unobserved gaps, detects bounded stationary clusters, and straightens confirmed free-arrow travel between semantic anchors. Click positions, drag paths, deliberate slow adjustments and meaningful pauses remain protected. Stable shape changes switch discretely. Camera hysteresis retains the new framing after a pause and coordinates with authored transitions. Only explicit cuts or unavailable cursor intervals reset composition. Native event timestamps pass through the same pause clock as other input.

Custom artwork now has 4× the former raster dimensions with matching hotspot and supersample scaling. New projects default to the outlined elevated cursor. Older project appearance selections remain unchanged.

New Zoom phases are 0.7 s entry, 1.4 s full-magnification hold and 0.8 s exit. UI and MCP share timing edits. Speed edits preserve unedited phases where footage permits; short-shot requests are idempotent. Disabled cues do not truncate enabled cues. Old projects are not migrated on load. The explicit relaxed preset updates automatic cues; manual cues retain timing and can be adjusted individually.

## Completed checks

- `swift build`: PASS.
- `FOCUS_STUDIO_CURSOR_BENCHMARK_SECONDS=600 swift run --skip-build FocusStudioPermissionTests`: PASS. Covers free travel, dwell, short hover, slow movement, clicks, genuine drag, shape stability, camera hysteresis, explicit cuts, artwork geometry, native timestamps and Zoom timing. The 600-second fixture prepared in 2.584 seconds in the debug build; this is preparation cost, not a playback FPS measurement. Free travel in the fixture used 64.0% of the raw path length while preserving tested anchors.
- `scripts/test-app-regression.sh --skip-build`: PASS. Includes recording lifecycle, original application capture chooser, timing persistence/undo, assistant control and actual MCP stdio import/edit/export against an isolated library.
- `scripts/test-ai-assistant.sh --skip-build`: PASS. Includes the shared Zoom timing API, repeated short-shot edits and complete MCP catalog. The first run exposed a catalog-size regression; duplicate parameter prose was shortened without weakening the size check or removing constraints, and the final run passed.
- `FocusStudioE2E --cursor-motion-only`: PASS. Both raw and smoothed variants use the shipping compositor, export 7-second MP4s and decode 12 frames. The fixture includes hover tremor, a hand cursor, an I-beam and a real drag arc.

## Read-only real recording comparison

A snapshot of a recent 12.457-second user recording was exported with the prior core and the new core, using identical project settings and manual zoom cues. The original library was not edited. Both outputs have a valid video track and four exact-time decoded frames. Media and project data remain local under `.artifacts/motion-quality-1.14.10/` and are not release assets.

| Measure | Previous | Updated |
| --- | ---: | ---: |
| Drift during first sampled stationary gap, source pixels | 46.667 | 0 |
| Drift during later sampled stationary gap, source pixels | 1.196 | 0 |
| Click-position error, source pixels | 0 | 0 |
| Prepared cursor samples | 1,561 | 409 |

The compared frame at 3.1 seconds visibly removes the prior overlapping arrow / I-beam. A local side-by-side export places the previous result on the left and the updated result on the right. The measurements establish these specific fixes, not subjective equivalence to another product or universal live-recording quality. Out-of-window movement with no recorded visibility metadata cannot be reconstructed reliably.

The application-owned screen/window/area picker remains intact. No new live microphone or desktop recording was made during this verification.

## Distribution checks

- Universal production build and archived bundle verification: PASS. Both arm64 and x86_64 MCP helpers answer with 54 tools; 1,544 localization keys match.
- DMG verification: PASS. 71,984,703 bytes; SHA-256 `890a864d184431d20385afb585560a577a07d209f14a2a4ead83f8842a997d75`.
- Local installer upgraded `/Applications/Focus Studio.app` to 1.14.10 (73), retaining a recovery bundle. MCP reconnected and reported the new version, all 25 pre-update projects and existing capture permissions. The user had already started a new recording when status was checked; no tool interrupted it. This observation is not a complete live-recording acceptance test.
- Remains a locally signed preview because Apple Developer credentials are not configured. No notarization or stable-release claim is made.

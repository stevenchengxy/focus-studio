# Virtual interaction traces for Codex recordings

Status: shared trace and recorder-owned execution adapter implemented and verified with live Finlyze recording in build 21 (2 clicks, 69 trace events, 2 automatic zooms). See [validation](../validation/2026-09-27-codex-interaction-trace.md). Build 22 adds cancellation, window-size and off-screen input guards plus Codex connection/structured-output compatibility fixes. Browser content-script ingestion, vision tracking, inferred result-region focus and dynamic source handoff below remain proposals. Preserve ordinary system-mouse recording and existing projects.

## Implemented first slice

- Optional persisted `InteractionTrace` owns both pointer and click metadata; old/manual recordings retain their system trace. Execution recordings exclude unrelated physical input and typing.
- `start_recording(interaction_mode: "codex")` chooses an exclusive measured execution source. `capture_recording_frame` returns the real full window image and a single-use, session-bound observation id. `perform_recording_action` dispatches smooth native move/click/scroll and records each dispatched point on the recorder clock.
- Observations expire after 60 seconds and invalidate on actions/pause/window geometry changes. Paused/stopping/discarded/obscured targets and off-screen points refuse input; action IDs prevent retries repeating clicks. A window resized after capture starts requires a new recording because the fixed-size capture can letterbox it; moving a window is allowed after a fresh observation.
- The built-in runner now records the same trace. The renderer, click effects, camera follow and automatic zoom generation share it. Embedded/hidden pointer modes can follow without drawing a second arrow. Long gaps hold position; explicit cuts reset the path.
- The unified assistant forwards captured images to Codex, then uses the same live tools. Static unobserved click plans remain disallowed.

This implementation does **not** intercept arbitrary Codex CUA/Playwright/AX actions. Codex must use the recorder's tracked action tools for automatic pointer and zoom synchronization. A future browser adapter is still useful for independent browser automation.


## Observed gap in the original implementation

`EventMonitor` writes `cursorSamples` and `clickEvents` from macOS events. External Codex computer/browser actions do not reliably reach this monitor. `add_zoom` creates only a `ZoomSegment`; it supplies no pointer samples. `ProjectVideoRenderer` feeds `CursorFollow` from `project.cursorSamples`, so adding zoom intervals cannot make it follow an unrecorded virtual pointer.

The built-in `CodexPlanRunner` is a separate execution path from external Codex + MCP. Its executed click callback already produces `plannedClicks`, but `StudioModel` still stores `result.cursorSamples` from system capture. This can pair a planned click with a different pointer trace. Fix both paths using a shared interaction model.

## Recommended first implementation

Introduce an interaction trace owned by each recording. System capture, browser observation, and an execution adapter append evidence; the recorder maps evidence into media time and recording coordinates. The active trace produces pointer samples, click effects and automatic zoom cues together.

An event should carry:

- Recording session ID, source window/tab/frame ID, source kind and geometry generation.
- Unique event/action ID and sequence number, to deduplicate retries and dual reports.
- Event type: move, down, up, click, drag, scroll, focus; distinguish an intended action from one actually dispatched.
- Origin timestamp plus clock identifier; an explicit synchronization anchor to the recorder's monotonic clock.
- Coordinate space, viewport dimensions and content rectangle; device scale/page zoom and iframe offsets when applicable.
- Pointer hotspot position, pointer kind, optional target element rectangle.
- Provenance and confidence: observed, execution-reported, reconstructed or visual estimate.

Do not store typed content. Geometry and input timing are sufficient for these effects.

### Input adapters

1. **Execution adapter (preferred where we own execution).** Emit events at actual execution time in `CodexPlanRunner`. Record moves as well as clicks; pending/cancelled actions never become executed clicks. Do not assume a plan's scheduled time equals its execution time.
2. **Browser adapter (external Codex).** A narrowly scoped, user-connected content-script extension observes pointer/mouse/click, scroll and focus events inside the recorded tab. Batch move events locally, preserving source timestamps; flush discrete events promptly. Navigation/iframes need reinjection and identity/geometry updates. Record source-observed events without requiring them to be native macOS input.
3. **Explicit trace ingestion.** Proposed MCP tools such as `append_interactions`/`import_interaction_trace` accept an adapter's bounded, validated trace. These tools do not currently exist. Adding a receiving tool alone does not intercept other Codex tools: the operating side must report events or the browser adapter must observe them. Do not make one model round trip per mouse move.
4. **Visual fallback (later).** If only video is available, detect the pointer hotspot and track it with temporal continuity/confidence. Reject uncertain matches and break tracks across cuts. A pointer detection or a dwell does not prove a click. Reliable click evidence still needs an event or action record.

A DOM `click` without meaningful pointer coordinates is a semantic activation, not proof of an actual pointer path. An element center may be used as an explicitly inferred focus target. A browser event collector cannot guarantee capture of non-DOM overlays, browser chrome, native dialogs, or actions which emit no corresponding DOM event.

## Coordinate and time mapping

Convert every source through an explicit time-varying transform into normalized **uncropped recording** coordinates. The renderer's existing crop and camera transforms then apply once to both pointer and focus. Never mix screenshot pixels, CSS viewport pixels, window points and video pixels, or apply device scale twice.

Anchor against the first captured frame and the recording's pause clock. Exclude paused intervals; record event time rather than MCP response/receipt time. Synchronize clocks, handle buffering/out-of-order delivery with a bounded reorder window, and reject stale session IDs. Recalibrate after window resize, page zoom or content-inset changes; break interpolation across navigation or tab changes.

Choose an active pointer source per recording segment. For an AI-controlled segment, use its virtual trace; unrelated movement of the user's physical mouse must not pull the camera away. Switching to human control should be explicit or require evidence of a real interaction within the recorded target. Deduplicate system/browser reports for the same action.

## Rendering and camera behavior

Separate `cursorDisplayMode` (render overlay, already embedded in video, hidden) from the presence of a camera-follow trace. Currently follow is gated by `showCursor`; that would incorrectly disable follow when the source already contains a visible Codex pointer.

- Reuse existing pointer smoothing and click anchoring on the selected trace. Pointer hotspot and click effect must coincide at the event time.
- With actual moves, retain the observed route. With only click anchors, a short ease-out approach can create a reconstructed demo route; never present that interpolation as the original observed movement. Do not interpolate through a long idle gap or a page cut.
- Reuse the camera soft zone and damped following. Clicking establishes focus; small moves should not shake the view. Large jumps should reframe or return to overview before the next focus rather than pan across the entire page.
- Treat input focus and result focus separately: a sidebar navigation click may deserve a brief click cue followed by framing the newly visible main panel. Use verified element bounds/layout changes when available; keep a conservative overview when result bounds are unknown.
- Choose scale from the target rectangle plus readable context, clamp it, and fit the viewport. Hold while meaningful interaction continues; ease out on idle or a scene change. Thresholds need tuning from recorded samples, not claims of universal defaults.

ScreenCaptureKit's current `showsCursor=false` affects the system cursor; it is not a mechanism for removing an arbitrary cursor drawn into a webpage or another overlay. Determine how the Codex cursor reaches the recording before suppressing it. If a separate overlay can be excluded or the producer offers a supported hide control, render our own cursor from the trace. Otherwise retain the embedded cursor and use the trace only for camera motion/click cues, avoiding a duplicate arrow. An existing video with a baked-in pointer cannot be cleanly restyled by changing metadata alone.

## Validation gates

- Recorded Codex actions populate both cursor samples and click events and generate zooms without post-hoc `add_zoom` calls.
- At each click, hotspot/click effect/zoom focus agree after crop and scale transforms. Target tolerance: one output frame in time and a few output pixels in position; measure rather than assume.
- Physical mouse movement during an AI-controlled segment does not change the active pointer or camera.
- Pauses, window movement, Retina scaling, browser zoom, crop changes, iframes and page navigation do not cause drift or long interpolated jumps.
- No duplicate arrows when the source cursor is embedded; follow remains available without drawing an additional cursor.
- Preview and export consume the same trace. Old projects and normal system-mouse capture remain compatible.
- Explicit diagnostics distinguish observed virtual tracking, reconstructed movement, visual fallback and unavailable tracking.

## Sequence

Implement the shared trace, source selection, mappings and renderer separation first. Connect the built-in runner and one browser adapter next. Verify on Finlyze with real Codex actions before adding visual tracking or automatic result-region selection. The browser adapter requires an actual integration and user connection; the current MCP tools do not expose a universal Codex pointer stream.

Primary reference for the browser adapter: https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts

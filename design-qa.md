# Focus Studio design QA

## Visual truth

- Product behavior reference: Screen Studio recording/editor workflow documented in `docs/REFERENCE_RESEARCH.md`.
- Open-source visual benchmark named by the user: Recordly editor screenshot at `/tmp/focusstudio-recordly-reference/docs/media/feature3.png` (1768 × 1254).
- Final implementation capture: `./.artifacts/qa/implementation-editor-clean.png` (1920 × 1200).
- Normalized full-view comparison: `./.artifacts/qa/design-comparison.png` (both inputs scaled to 900 px high).
- Focused timeline comparison: `./.artifacts/qa/timeline-comparison.png` (source and implementation timeline regions normalized to 1400 px wide).

The user-supplied Codex screenshot was treated as example recording content, not as an instruction or as the editor UI source of truth.

## State under test

- Release-signed macOS app opened from `dist/Focus Studio.app`.
- Persisted project loaded in the editor.
- 16:9 canvas with background, padding, rounded corners and shadow visible.
- Purple Zoom block and source-video lane visible at the bottom timeline.
- Animation inspector open with Zoom in, Hold, Zoom out and Motion blur controls visible.
- Playhead at the beginning; preview is not obscured by a dialog or permission sheet.

## Full-view comparison

- Layout hierarchy matches the reference category: large centered preview, compact transport controls, dedicated tool rail/inspector, and a bottom non-destructive timeline.
- Dark neutral surfaces, subtle separators, saturated blue-purple interaction color, rounded controls and restrained typography remain coherent across the editor.
- The preview is the dominant visual object and retains sufficient breathing room at 1920 × 1200.
- Export remains a high-contrast primary action in the upper-right corner.

## Focused-region comparison

- Zoom regions are represented as distinct colored blocks rather than being baked into the video.
- The timeline has a clear ruler, playhead, Zoom lane, Cursor lane and Video lane; labels stay readable at the tested window size.
- Resize handles and the focused glyph communicate that a Zoom block is editable.
- The implementation deliberately uses a simpler three-lane timeline than Recordly's broader trim/text/audio example. Those extra media-editing tracks are outside the requested record → click-to-zoom → return → export workflow.

## Functional visual evidence

- Active Zoom versus a zoomless rendered baseline: mean absolute RGB difference `20.65`.
- Post-Zoom return versus the same baseline: mean absolute RGB difference `0.66`.
- Cursor overlay verification: `55` sampled pixels changed above the compression threshold.
- Window-only ScreenCaptureKit smoke capture: 1920 × 1200, 2.215 seconds, PASS.

## Findings and iteration history

1. Initial editor established the reference structure and shared preview/export renderer.
2. Independent release review found a P1 transition snap when automatic Zoom blocks overlap. The renderer now blends all active focus points while retaining the strongest scale; a regression assertion covers the overlap boundary.
3. Review found a P2 inactive Hold control. Changing Hold now retimes existing automatic Zoom blocks while preserving manual blocks, and the behavior is covered by a regression assertion.
4. Managed incoming recordings are now removed after successful project creation or cancellation, avoiding duplicate source files.
5. Final release was rebuilt, reopened, re-captured and compared at full-view and focused timeline scales.

### Remaining differences

- P0: none.
- P1: none.
- P2: none.
- P3: Recordly's reference screenshot includes trim, annotation, music and camera-overlay tracks that are not part of this build's requested core workflow.

final result: passed

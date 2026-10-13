# Build 57 · per-zoom camera moves

The editor keeps the existing Classic zoom as the default. Each zoom segment can instead use Tilt reveal (a brief ~3° diagonal entry that settles level), Slide to focus, or Soft drift. The choice is saved with that segment; older project JSON decodes to Classic, and regeneration retains an authored automatic cue's selection. The inspector shows one simple preset picker and a short explanation. The timeline marks non-Classic blocks with a compact icon. Instant blocks disable the picker because they have no entry interval in which to show a move.

The same `ZoomFrameTransform` maps footage, the recorded cursor hotspot, and click feedback in preview and export. It adds only the coverage needed to avoid transparent corners during a tilt or slide, and it leaves the Classic path unchanged. No new Core Image filter or layer is introduced. The per-segment motion math settles to the ordinary focus before readable UI text is held on screen.

Codex and the in-app assistant can inspect `get_project.zoom_motion_presets` and each `zooms[].motion_preset`, then use `add_zoom` or `update_zoom` with `motion_preset`. The latter preserves the stable zoom ID, timing and other zooms. The assistant maps phrases such as “斜着展示、再复原” to `tiltReveal`.

## Checks

- `swift run FocusStudioPermissionTests`: passed, including angle/offset boundaries, edge coverage, cursor matrix alignment, old JSON fallback and regeneration ownership.
- `swift run FocusStudioE2E --output-dir .artifacts/e2e-build57`: passed. All four presets were encoded as real MP4s and sampled at seven timestamps. Preview/export frame difference stayed below the existing compression threshold; non-Classic moves visibly differ from Classic, while frames outside the segment return to the same appearance. Review frames are in `.artifacts/e2e-build57/focus-studio-zoom-motion-*.png`.
- `zsh scripts/test-ai-assistant.sh --skip-build`: passed, including MCP schemas, add/update receipts, stable ID, invalid-preset rejection, and output-size budgets.
- `zsh scripts/test.sh`: passed, including editor and recording regression, AI assistant, MCP protocol and catalog, localization, and end-to-end export.
- Signed arm64 build 57 was installed over build 56; `codesign --verify --deep --strict` passed. The previous app bundle remains in the installer's recovery folder.
- Live app/MCP smoke: imported a disposable 2.42-second synthetic clip, and the installed MCP helper's `tools/list` exposed `motion_preset`. A real `add_zoom` call with `tiltReveal` succeeded. The editor showed the new per-cue picker and timeline label; changing it to `slideFocus` updated `get_project.zooms[].motion_preset`, and switching back to `tiltReveal` showed the diagonal frame with no exposed edge. The disposable project was moved to the Trash and the previously open user project was reopened.

This already-open Codex task still has the pre-update connector schema cached and rejects `motion_preset` before forwarding an `add_zoom` call. The newly installed helper advertises and accepts the parameter; a new Codex task or refreshed MCP connection is needed for that tool schema to appear here.

Motion is intentionally subtle and 2D. This is a screen-demo camera move, not a 3D card or After Effects composition. Rendering cost was kept low, but native timeline frame rate has not yet been instrumented, so no numerical smoothness gain is claimed.

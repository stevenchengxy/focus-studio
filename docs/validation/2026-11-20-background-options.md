# Optional recording background — 1.14.11 (74)

The Design inspector now starts with a four-way background picker: None / Solid / Gradient / Image. None uses the cropped source ratio with zero effective frame padding, corner radius and shadow. Stored framing, image path and colours remain intact for restoring a decorated mode. Only relevant controls are shown; the toolbar reflects the effective Auto ratio, and the preview container follows it. Sidebar changes use a brief transition that respects Reduce Motion.

MP4 remains opaque. Mixed-aspect imported images/videos are fitted without cropping; any necessary matte is black. This mode is not transparent-video export. Zoom, cursor and caption effects remain available.

Codex can use `update_settings` with `backgroundStyle: "none"`. Reports retain stored settings and add `look.effectiveFrame` so an assistant can distinguish active geometry from saved decoration.

## Verification

- `swift build`: PASS.
- `scripts/test-app-regression.sh --skip-build`: PASS, including the new `BackgroundRenderingRegression`. Real prepared-preview and exported MP4 frames verify 4:3 source ratio, source pixels at all four corners, edited crop, inserted portrait image, inserted video and complete decoration restoration after serialization. The suite also exercises editor undo/save/reload, capture lifecycle and actual MCP stdio import/edit/export in an isolated library.
- `scripts/test-ai-assistant.sh --skip-build`: PASS, including none-mode schema, exact persistence/restoration and repeated requests. The MCP catalog still satisfies its size budget.
- `scripts/test-toolbar-snapshots.sh --skip-build`: PASS. All four real SwiftUI background modes were rendered offscreen at 292 px sidebar width; None and Gradient screenshots were visually checked for clipping and hidden controls. No user recording or desktop input was generated.

Local logs and screenshots: `.artifacts/background-options-1.14.11/`. Existing projects keep their saved background until the user or Codex changes it.

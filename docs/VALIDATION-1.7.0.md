# Focus Studio 1.7.0 (build 12) validation

Date: 2026-09-22. Host: Apple Silicon Mac, macOS 26.2. This update replaces the assistant's primitive toy with two selectable, semi-realistic adult head-and-shoulders 3D characters. It does not claim photorealism, phoneme-accurate lip sync, motion capture, or a complete articulated full-body avatar.

**Visual acceptance: rejected.** The user explicitly requested another redesign after seeing these characters on 2026-09-22. Engineering passes in this document must not be interpreted as approval of their appearance. New concept work must be reviewed separately from the actual runtime model and animation renders.

## Implementation and assets

- Blender 4.5.7 LTS authored polygon meshes, hair, clothing, blink/speak/smile shape keys; source: `Design/Avatars/Focus-Studio-Digital-Humans.blend`.
- Reproducible pipeline: `scripts/build-digital-humans.py`; build-time tool/source fingerprints and source license attribution are bundled in `Resources/Avatars`.
- Both models (132,615 vertices in total) use local, inline geometry. No model API, external texture URL, downloaded-at-runtime avatar, or user photo is involved.
- Male/female selector shared between Demo Director and AI Assistant, backed by local preferences; changing the avatar does not clear the conversation or recording plan.
- Scene replacement does not mutate a rig under its render callback. Facial targets use normalized absolute-position interpolation; hair/clothing do not morph. Head pose is restrained, without toy squash/stretch or bouncing.
- Audio drives a jaw-opening envelope, not arbitrary silent talking. NaN/infinite audio and expression inputs are sanitized. Reduce Motion holds a static portrait.
- Release build and archive validation require both models and attribution; reject invalid indices, malformed colors/morphs, non-finite buffers, symlinks, and external-resource fields. Runtime uses bounded reads and a nonfatal placeholder if resources are missing/corrupt.

## Verification

The native Metal renderer produced 16 model snapshots: two identities × six assistant states, plus fully closed eyes and maximum speech for each. Snapshots are `.artifacts/assistant-avatar-1.7.0/avatar-*.png`; numeric results are `avatar-validation.json` in that directory.

Additional assertions cover real mesh loading and distinct identities, no global head inflation during expression morphing, local target displacement ≤ 0.18 scene units, unchanged majority of head vertices, finite poses, muted-mouth rest, invalid-audio recovery, Reduce Motion, damaged-resource fallback, and isolated preference persistence.

Visual inspection caught and corrected hard lip-color patches, jagged neckline cuts, an additive/absolute shape-key mismatch, incomplete eyelid closure, insufficient mouth opening, and exposed mouth-interior helpers at rest. The previews are actual SceneKit output, not separately generated marketing portraits.

Full regression logs:

- `.artifacts/test-1.7.0.log`: first full pass during asset iteration.
- `.artifacts/test-1.7.0-final.log`: interrupted by intentional source safety fixes; compiler detected a file changing during compilation. Not a release pass.
- `.artifacts/test-1.7.0-final-retry.log`: final frozen-source run **PASS, exit 0**, including synthetic media E2E, cursor/pause regressions, 789 matched localized keys, 50 editor/back cycles, installation fixtures, Codex runner/setup, both avatars and preferences, asset validator, mocked AI gateway and assistant tools.

## Resource fingerprints

| File | SHA-256 |
| --- | --- |
| `studio-female.json` | `58e1c9333262a96ef720d559ccdc4bbaa072acb27297b45b1798dc2c9c5a74d4` |
| `studio-male.json` | `0deeff320767afa480711a32e5b75425923b0985acea19f4b199361a2bd31bae` |
| `Focus-Studio-Digital-Humans.blend` | `3e0eb84b37447899c5d529d3b4e5fa5438fdbf12c4af648f11ddd98b1ef28f08` |

## Boundaries

The current turn's new UI checks concern avatar selection, display, restart persistence and unchanged chat history. No fresh physical screen recording, external paid model request, or microphone recording is implied by these avatar checks. Synthetic video and existing recording regressions run in the suite. Prior native recording evidence remains in `VALIDATION-1.6.0.md`.

Universal2 packaging is not a physical Intel-Mac test. Local distribution remains ad-hoc signed, without Developer ID or Apple notarization; other Macs have independent first-run permissions and Gatekeeper policy. Blender and the editable `.blend` are authoring artifacts, not runtime dependencies.

## Final package / native UI result

Universal2 DMG and ZIP packaging completed; `.artifacts/package-1.7.0-b12.log` records successful archive checks and resource validation. `/Applications/Focus Studio.app/Contents/Info.plist` reports 1.7.0 / build 12. Native UI inspection displayed the female avatar and switched the shared selector to male without clearing the conversation or recording plan. The female UI capture is `.artifacts/qa-1.7.0-b12/director-female.png`.

The user then rejected the models' appearance. Manual restart-persistence verification was not completed in that native UI session (isolated preference tests passed). The subsequent work in `Design/Avatars/Concepts/2026-09-22-redesign` is **new 2D concept exploration**, not another installed 3D release. Do not reuse these engineering results to claim the replacement look has passed native visual QA.

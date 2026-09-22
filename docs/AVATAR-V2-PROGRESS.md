# Approved digital humans — implementation checkpoint

2026-09-22. User approved `Design/Avatars/Concepts/2026-09-22-redesign/stylized-duo.png` and requested implementation. **Not a release-completion report.** No installed app, old model, recording or conversation has been replaced by this work.

## Completed

- Frozen separate male/female frontal source PNGs with real alpha in `Design/Avatars/Sources/v2`. Actual resolution is 1254², not the larger resolution requested in the prompts. All ImageGen prompts and checks are recorded there.
- Schema 2 local texture pipeline: per-vertex UVs; base-color, normal, roughness and AO PNG channels; optional unlit baked materials. Schema 1 still loads unchanged.
- Safe resource bounds: no network references, absolute/traversal paths or symlinks; actual PNG decoding, per-file byte/dimension bounds and per-character decoded-pixel budget; nonfatal clean fallback on rejection.
- Material cache now distinguishes textures, light mode, color and roughness. Actual Metal red/blue orientation test establishes Blender UV compatibility.
- Candidate-only SceneKit inspection harness in `Tests/AssistantAvatarLookdev` and `scripts/preview-avatar-candidate.sh` supports front, quarter/side, blink and speech views at 512/176/112px, without replacing bundled assets.
- A female TRELLIS.2 generation produced real multi-view geometry/appearance previews, saved in `Design/Avatars/Reconstruction/v2`. The appearance has recognizable face/clothing; fine hair has noisy geometry and needs cleanup. This is not a finished rig.
- Offline MediaPipe measurements extracted 478 3D facial landmarks per fictional source into `female-landmarks.json` / `male-landmarks.json`. This supplies later eye/lip fitting references, not a production character mesh. The isolated authoring environment runs with `arch -x86_64 .tools/avatar-modeling/landmark-env/bin/python`; no dependency was installed globally.

## Verification at this checkpoint

- `swift build`: PASS.
- `scripts/test-assistant-avatar.sh`: PASS on the **existing** bundled schema 1 models; this checks that texture support did not break the old animation/selection/fallback behavior.
- `scripts/test-assistant-avatar-textures.sh`: PASS on closed 3D fixture geometry, including real Metal texture orientation and validation failure cases.
- `scripts/verify-avatar-assets.swift --self-test`: PASS, including new schema 2 texture/path fixtures.
- Production resource validation still concerns the old models, not a newly completed character. No new native look-development pass or release claim is implied.

## Blocked export — no GLB received

The anonymous public service accepted the generation, then rejected GLB export: the export endpoint requests a 120-second reservation and only 104 seconds remained. No account, credential, paid request, alternate identity or quota workaround was used. There is no exported GLB locally and no reliable shareable/resumable job URL. Retrying the same anonymous two-stage workflow can reproduce the same reservation failure, even after the next reset.

The user was asked to sign in themselves to the official Hugging Face TRELLIS.2 page. Do not ask them to paste passwords or tokens. After they confirm, verify the signed-in UI and its allowance before performing a new bounded generation/export. The source input is only the fictional character PNG, never the user's recording or other files. Public-service availability and quota must be rechecked; do not promise export success merely from login.

## Remaining

1. Obtain actual textured mesh files for both approved identities.
2. Clean noisy hair/mesh, inspect topology and UVs, build eyes/lids/mouth and expression shapes. A generated mesh does not automatically provide an animation-ready rig.
3. Export candidate schema 2 geometry/resources; render with the real application's SceneKit path. Inspect the actual results against the approved concept, including facial expressions and small UI sizes.
4. Run avatar/resource regressions and app tests, then bump version, package, verify and install. Preserve the existing canonical app and user data until that visual/functional gate succeeds.

The concept images, remote preview JPGs, test texture boxes and previous 1.7.0 renders are not evidence that steps 1–4 are complete.
# Cancelled

The user requested removal of digital humans on 2026-09-22. The prior work recorded below is historical only. No reconstruction or avatar release is continuing; see `VALIDATION-1.7.1.md`.

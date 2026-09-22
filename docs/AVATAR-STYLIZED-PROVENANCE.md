# Stylized avatar provenance and 1.7.1 release gate

**Cancelled 2026-09-22:** the user requested complete removal of digital humans. This is historical source research only; the planned avatar release below will not ship. See `VALIDATION-1.7.1.md` for the chat-only replacement.

Status: source investigation and release plan, verified 2026-09-22. This is not a declaration that 1.7.1 has been built, visually approved, or installed. The production resource manifest must describe the final exported objects; it is not replaced by this draft.

## Upstream source

The local authoring source is Blender Studio / Blender community **Human Base Meshes, bundle v1.0.0**, distributed from Blender's official server. The official Blender 3.6 release page identifies the bundle as a sculpting, animation and texturing starting point. The project's official discussion identifies the bundle's license as CC0 and says individual artists are credited in the asset descriptions. The discussion JSON was retrieved directly from `devtalk.blender.org` on the verification date; the individual credits below were independently read from the downloaded `.blend` file.

- [Official Human Base Meshes download](https://download.blender.org/demo/asset-bundles/human-base-meshes/human-base-meshes-bundle-v1.0.0.zip)
- [Official bundle announcement and features](https://www.blender.org/download/releases/3-6/)
- [Official base-mesh development and licensing discussion](https://devtalk.blender.org/t/asset-bundle-base-meshes/21535)
- [Machine-readable discussion](https://devtalk.blender.org/t/asset-bundle-base-meshes/21535.json)

Local archive: `.tools/avatar-modeling/human-base-meshes-bundle-v1.0.0.zip`

Archive SHA-256: `46a912c0524072ac3b78c35d5d2471df7b8df102394a050ca8cd7184e3393648`

Local blend: `.tools/avatar-modeling/base-meshes/human_base_meshes_bundle.blend`

Blend SHA-256: `660e245812ef56768bc71293bd4c8bc1fd19a63710e16aafc8258a7351cbc35e`

## Exact embedded asset metadata

The following collection-level metadata was inspected using Blender 4.5.7 LTS, in background mode with factory settings and script auto-execution disabled. The file was not saved or modified.

| Asset collection | Mesh objects included | Embedded author | Embedded license |
| --- | --- | --- | --- |
| `Head - Stylized` | `GEO-head_stylized`, `GEO-head_stylized.eye.L`, `GEO-head_stylized.eye.R` | Julien Kaspar | CC0 |
| `Body Male - Stylized` | `GEO-body_male_stylized`, `GEO-body_male_stylized.eye.L`, `GEO-body_male_stylized.eye.R` | Julien Kaspar | CC0 |
| `Body Female - Stylized` | `GEO-body_female_stylized`, `GEO-body_female_stylized.eye.L`, `GEO-body_female_stylized.eye.R` | Julien Kaspar | CC0 |

The inner `GEO-*` objects do not carry separate asset metadata; their enclosing asset collections carry the author and license. Do not incorrectly credit these stylized collections to the realistic-model contributor Dan Ulrich. The separate stylized eye, hand, foot and jaw object assets also identify Julien Kaspar and CC0, but their presence in the source file does not mean they are used by the final export.

## Redistribution and design boundary

[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) permits copying, modification and distribution, including commercial use, without requesting copyright permission. CC0 does not waive other parties' trademarks, patents, publicity or privacy rights, and must not be presented as an endorsement. The [legal code](https://creativecommons.org/publicdomain/zero/1.0/legalcode.en) governs, rather than this summary.

Focus Studio's planned characters are original stylized adult digital humans, authored locally using these base meshes. “Memoji-inspired” describes the requested general visual direction only: no Apple avatar mesh, texture, illustration, logo or character asset is part of this source, and no Apple/Blender/artist endorsement is claimed. This is not a real person's scan or identity clone. Record the actual Focus Studio changes—such as proportions, hair, clothing, materials and facial morphs—only after the final authoring/export step has completed. Do not relabel all app assets as CC0 merely because their upstream base geometry is CC0.

Blender is an authoring tool, not an end-user requirement. The application should bundle only the validated local runtime assets and attribution, not Blender, the upstream authoring archive, user data, credentials, or the abandoned online reconstruction experiment.

## Planned 1.7.1 (build 13) acceptance checklist

At inspection, the installed/running canonical app was `/Applications/Focus Studio.app`, version 1.7.0 (12). It was not stopped, replaced or otherwise modified. The following are pending gates, not completed validation claims.

1. Freeze both avatar exports, runtime source and attribution together. Update the resource manifest to Julien Kaspar and the precise source collection/object names actually used; record both generated asset hashes and authoring changes. Bump the version only when the release owner approves.
2. Validate both avatars, finite mesh/normal/color/morph values, index bounds, file-size limits, identical morph vertex counts, and no symlinks or external references. If schema 2 textures are used, validate UVs, channel names, referenced local PNGs and decoded-pixel budgets; also extend the release inventory allowlist, which currently accepts only avatar JSON and documentation.
3. Inspect **actual application renderer** outputs for male and female at front, three-quarter, side and rear views, plus blink, speech, smile and idle states. Check eyelid closure, teeth/mouth visibility, hair silhouette, neck/clothing joins, clipping, dark/light backgrounds and small assistant-window size. Blender-only previews are insufficient.
4. Run `zsh scripts/test.sh` after freeze. It includes avatar geometry, texture and preferences tests, malformed-resource validator fixtures, NaN/expression safety tests, recording/edit/export regressions, installation fixtures and assistant/Codex tests. Keep logs; a previous-version PASS does not establish the new version's result.
5. Build a fresh Universal 2 candidate at `dist/candidates/1.7.1-b13/Focus Studio.app`, without modifying a running app. Require the existing production source/resource snapshot guard to pass for both architecture slices.
6. Verify the candidate, unpacked ZIP and read-only mounted DMG: version/build, macOS 15 minimum, arm64+x86_64, signature, system-only linked frameworks, icons, both catalogs, audio resources, avatars and exact attribution. Verify source/candidate resource hashes and final archive SHA-256 files. Do not describe an ad-hoc package as Developer ID signed or notarized.
7. Coordinate any native smoke test or canonical update with the release owner and user. Require idle/not-recording/not-exporting/not-running-assistant state and the existing numeric-version, validation, running-destination and rollback guards. Preserve the previous bundle and user library. Never carry or force system permissions across machines; clearly report any new permission approval needed.
8. Record automated, packaging, native visual and physical-recording results separately. Intel cross-compilation is not a claim of Intel hardware testing, and no new live recording should be claimed unless actually exercised.

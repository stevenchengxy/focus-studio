# Build 43 editor and media-library validation — 2026-09-29

## Result

Focus Studio 1.12.0 build 43 was built for the host arm64 architecture, signed for local development, installed at `/Applications/Focus Studio.app`, and launched against the existing Finlyze editing project. This is a local installation, not a notarized Universal 2 release.

In the installed app, the timeline zoom button changed the scale from 100% to 200%; Fit returned it to 100%. The editor exposed Undo/Redo controls and Import/AI entry points for the project media library. A synthetic `green.png` was imported through the native file picker and appeared as a media card. Clicking it inserted a 3-second image clip, changing the project duration from 25.415 to 28.415 seconds. Undo restored three original clips and 25.415 seconds; Redo restored the image clip; two final Undo actions removed both the insertion and import. The test-owned imported file was removed after the restored project no longer referenced it.

The assistant was connected with the in-window **Connect Codex** button. A real read-only request, “只查看当前编辑项目的素材库，列出素材名称和数量；不要修改项目或开始录屏”, immediately displayed “思考中…”, invoked the media-library tool and answered that the current project contained 0 assets. It did not start recording or edit the project.

## Automated and renderer checks

- `swift build` passed after source changes.
- `zsh scripts/test-ai-assistant.sh --skip-build` passed, including media-library assistant/MCP tool tests and the mixed video timeline test.
- `zsh scripts/test-app-regression.sh --skip-build` passed, including project media import, persistence, insertion, Undo/Redo, and existing recording and editor regressions.
- A Core renderer smoke project exported `.artifacts/mixed-core-smoke/mixed.mp4` with an image, an imported portrait video with audio and the original screen capture. The 3.8-second H.264/AAC file was decoded and image/audio samples inspected.
- `FOCUS_STUDIO_ARCHS=native zsh scripts/build-app.sh` passed packaging, localization checks (1,153 matching keys), code-signature verification and a stdio listing of 43 MCP tools. Build log: `.artifacts/media-library-build/build.log`.
- The original Finlyze source project `BC58955A-9F90-4948-8159-004C70C32850` retained its raw movie SHA-256 `90d1bf10e0d64485c587680b7b1f0c1edff3ffbb65464a06ca4c5ed991fbc6c9` and metadata SHA-256 `862c63a19f81e546dfca659bbcad72659f31f4831fcce74d291e52c0e941c3e0`.

## Scope and remaining boundaries

Import copies user media into the current project's working copy. It is a project media library, not a cross-project catalog. The assistant adds successful Seedance videos and Seedream images there after paid-generation confirmation; a live paid generation was not run, so that external service path is covered by mocked integration tests only. Insertion was verified by click and model/MCP tests. A CUA drag did not produce a new clip; it is unclear whether that automation gesture initiated native dragging, so human drag-and-drop remains unverified. Preview rerenders now avoid title-only and unused-library changes, and filmstrip thumbnails are cached and limited to visible clips; no quantitative performance benchmark was taken. Manual physical-mouse capture logic was left unchanged.

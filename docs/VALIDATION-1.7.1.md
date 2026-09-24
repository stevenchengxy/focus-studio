# 1.7.1 (14): remove digital humans

The user explicitly cancelled the digital-human work on 2026-09-22 and requested removal. This supersedes the avatar redesign and 1.7.1 avatar release plans.

## Scope

- Remove 3D characters, male/female selection, SceneKit portrait animation and bundled model resources from the application.
- Keep AI Assistant / Demo Director chat, model settings, attachments, voice input, opt-in voice replies, confirmation cards and recording-plan actions.
- Replace the large character header with a compact text-and-controls chat header.
- Packaging rejects leftover `Contents/Resources/Avatars`; new builds do not copy it.
- Recording projects, conversation history, credentials and other settings are not deleted.

## Recovery

Removed feature source, model resources, authoring files and dedicated tests/scripts are locally archived under `.artifacts/removed-digital-human-20260922/`. This ignored, recoverable archive is not compiled, copied into releases or downloaded at runtime. Historical validation documents refer to their old versions only.

## Verification

- `zsh scripts/test.sh` completed with exit 0 for the final build-14 source. Evidence: `.artifacts/test-1.7.1-b14-chat-only.log`. Includes permission/area geometry, zoom and typing behavior, synthetic recording/export, pause assembly, localization, 50 edit/back cycles, library management, installer fixtures, Codex connection/plan runner and offline AI chat/tool tests.
- Universal 2 build and release verification passed (arm64 + x86_64, macOS 15+, matching catalogs, audio resources, signature and resource inventory). No avatar resource directory is present, and `otool -L` confirms the app no longer links SceneKit. Evidence: `.artifacts/build-1.7.1-b14-chat-only.log`.
- Build-14 DMG integrity and extracted ZIP verification passed. Artifacts: `dist/releases/Focus-Studio-1.7.1-universal-local.dmg`, `.zip` and `.sha256`; packaging evidence: `.artifacts/package-1.7.1-b14-chat-only.log`.
- Build 13 was installed into `/Applications/Focus Studio.app` using the verified recoverable installer and opened natively. Demo Director showed a compact chat header, no character and no male/female picker. Existing conversation and plan draft remained visible; the library initially showed all 29 existing projects. No recording/project data was changed by this task.
- Native inspection found the header's parent accessibility identifier overriding child identifiers. Build 14 removes that parent identifier, preserving the existing button IDs. Both full regression and universal build were rerun successfully.
- Build 14 installation is awaiting a convenient restart: user activity was detected in the running app, so further UI actions/restarts were paused rather than interrupting that work. Build 13 already removes the digital human. Build-13 prior app recovery: `/Applications/.focusstudio-install-4976E9D6-576B-4C3D-8894-5E4D04AD8D90/previous.bundle`.
- No paid model calls, live screen recording, microphone permission changes, Intel hardware testing or Apple notarization were performed for this removal. Packages are local/ad-hoc signed, not notarized.

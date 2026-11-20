# Application capture chooser rollback — 1.14.9 (72)

The user requested removal of the macOS system picker introduced in 1.14.8. The application-owned Display / Window / Area chooser, source preview, area re-selection and floating recording controls are restored to the pre-picker implementation at `55aa8b7`. System picker state, native-selection filters and dedicated setup/menu-bar views have been removed. The independent normal-stop classification and writer-drain race fixes remain.

Cursor / Zoom algorithms, drag metadata and their tests have no changes against `f3c432e`.

## Checks completed

- `swift build`: PASS.
- `scripts/test-app-regression.sh --skip-build`: PASS, including listed-source modes, area re-selection, missing-source handling, countdown cancellation, pause/resume, assistant control, and a real MCP stdio import/edit/export round trip against an isolated test library.
- `scripts/test-system-capture-stop.sh --skip-build`: PASS, including late user-stop notification, writer draining and genuine failures.
- `swift run --skip-build FocusStudioPermissionTests`: PASS, including cursor stability and area geometry.
- Notarization preflight mock suite: 9 tests PASS; stable-release safeguards are retained.
- Universal release build and archived bundle verification: PASS; arm64 and x86_64 MCP helpers each report 54 tools. Localization catalogs contain 1541 matching keys.
- DMG `hdiutil verify`: PASS. Size: 71998163 bytes. SHA-256: `ac41b41a3d1cfcdf6989566d31e64431d2a0b9458dae4f2e8777a18657799f4c`.
- Local installation upgraded `/Applications/Focus Studio.app` from 1.14.8 (71) to 1.14.9 (72). Installed app `get_status` confirmed the new version, idle recording and all 28 pre-update projects. `list_recording_sources` returned the display and visible windows after relaunch.
- Two independent source reviews confirmed the original chooser/MCP paths and retained stop/cursor fixes; `git diff --check` passed.

Logs are in `.artifacts/picker-rollback-1.14.9/` locally. The app regression uses scripted capture and does not prove real first-run consent or an end-to-end live recording. This rollback does not claim a new manual acceptance pass for those behaviors.

## Distribution

The update remains on `preview`, using a locally signed Universal DMG. Apple notarization has not been submitted because Developer Program membership and Developer ID credentials are not configured. A future stable release must have a higher version, valid signing and successful notarization; the previous 1.14.9 stable draft is superseded by this rollback update.

# Building and distributing Focus Studio

## Release status

The source is version **1.12.0 (build 19)**: 1.11.0 (build 18) plus the MCP helper `focus-studio-mcp`, through which Claude Code, Codex and other MCP clients record, edit and export in Focus Studio once the person approves them (GitHub issue #1). A recording an AI tool starts shows its countdown, the tool's name, the sound it records and the time left in the recording control bar, even with no main window; its `duration` counts recorded time, so paused time is excluded. The universal candidate is `dist/candidates/1.12.0/Focus Studio.app`, packaged as `dist/releases/Focus-Studio-1.12.0-universal-local.dmg` and `.zip`. Verification for this version is in [VALIDATION-1.12.0.md](VALIDATION-1.12.0.md); the live MCP checks from [MCP-QA.md](MCP-QA.md) are still pending there. Automated or package checks do not by themselves prove live recording. Do not overwrite or stop the currently installed app while preparing a candidate.

Versions 1.8.0 (build 15) to 1.11.0 (build 18) are recorded in [VALIDATION-cursor-motion-2026-09-22.md](VALIDATION-cursor-motion-2026-09-22.md) (1.8.0, 1.9.0), [VALIDATION-cursor-styles-toolbar-2026-09-23.md](VALIDATION-cursor-styles-toolbar-2026-09-23.md) (1.10.0) and [VALIDATION-toolbar-backgrounds-2026-09-23.md](VALIDATION-toolbar-backgrounds-2026-09-23.md) (1.11.0). The prior **1.7.1 (build 14)** removed digital humans and their selection/rendering/model resources at the user's request; packaging still rejects leftover avatar resources. Its verification is in [VALIDATION-1.7.1.md](VALIDATION-1.7.1.md).

Version 1.5.0 (build 9) was installed through the native installer into `/Applications/Focus Studio.app` and then launched from that canonical path. Its actual test evidence and limitations remain in [VALIDATION-1.5.0.md](VALIDATION-1.5.0.md); the version bump does not imply that those results also validate 1.6.0.

The prior **1.6.0 (build 11)** native recording validation remains in [VALIDATION-1.6.0.md](VALIDATION-1.6.0.md), including Chrome recording, pause/resume and the 72.845-second fixture. It is historical evidence, not a claim that a new physical recording was performed for the 1.7.0 avatar-only update.

## Build

Run `./scripts/build-app.sh` on macOS with current Command Line Tools (Swift 6.1 or later since 1.12: the MCP Swift SDK and its dependencies need Swift 6 manifests). It builds separate `arm64-apple-macosx15.0` and `x86_64-apple-macosx15.0` release slices of the app and of the MCP helper `focus-studio-mcp`, combines them with `lipo`, bundles the verified static audio assets, multi-resolution icon and English / Simplified Chinese catalogs, signs and verifies the app, then replaces `dist/Focus Studio.app`. No end-user project or credentials are copied. The previous app remains intact if building or verification fails. A source-and-resource digest rejects builds if production code or bundled assets change while the two architecture slices compile.

The default is Universal 2. For local iteration only, `FOCUS_STUDIO_ARCHS=native ./scripts/build-app.sh` builds the host architecture. `arm64` and `x86_64` are also supported. The packaging script requires both slices.

To leave a running app untouched, build and package a separate candidate:

```sh
FOCUS_STUDIO_APP_DIR="$PWD/dist/candidates/1.12.0/Focus Studio.app" ./scripts/build-app.sh
FOCUS_STUDIO_APP_DIR="$PWD/dist/candidates/1.12.0/Focus Studio.app" ./scripts/package-release.sh --skip-build
```

The override must be an absolute, non-symlink path inside this checkout's `dist` directory and end in `Focus Studio.app`. Its parent is created when needed; staging and replacement are restricted to that selected parent. The default remains `dist/Focus Studio.app`. Building a candidate does not launch it or replace the default running bundle. `package-release.sh` reads the same variable, so the second command packages the candidate; its outputs still go to `dist/releases/`, where a previous package with the same name is replaced.

## The MCP helper (1.12)

`Contents/MacOS/focus-studio-mcp` is the stdio MCP server that Claude Code, Codex and other MCP clients start. It is built from `Sources/FocusStudioMCP` with the official MCP Swift SDK, pinned exactly to 0.12.1 in `Package.swift`; `Package.resolved` is kept in the repository and the release build passes `--force-resolved-versions`, so an SDK upgrade is always an explicit change. The SDK is linked statically: the helper, like the app, links only libraries that ship with macOS. The first build needs network access to fetch the pinned packages.

- **Signing order.** The helper is nested code, so it is signed first and the app's signature then seals it. It has its own identifier, `com.local.focusstudio.mcp`, and no entitlements. With a signing identity it gets the hardened runtime (`--options runtime`) and, for Developer ID, a secure timestamp; ad hoc it gets a designated requirement naming its identifier. If you ever re-sign a bundle by hand, sign the helper first with `--identifier com.local.focusstudio.mcp` (and `--options runtime` for Developer ID), then the app; `verify-release.sh` rejects any other identifier.
- **Notices.** `build-app.sh` writes the licence and notice texts of the packages the helper links (swift-sdk, swift-log, swift-system, eventsource) to `Contents/Resources/ThirdPartyNotices.txt`, and `package-release.sh` also places that file next to the app in the DMG and ZIP. A module from a package without a notice entry stops the build; after an SDK upgrade, add the new package to `build-app.sh` and `verify-release.sh`.
- **Notarization.** Apple checks nested code too. With `FOCUS_STUDIO_NOTARY_PROFILE`, `package-release.sh` refuses to submit unless the helper is signed with Developer ID Application and has the hardened runtime, like the app.
- **Verification.** `verify-release.sh` checks that the helper is a regular executable (not a symlink), has the app's architectures, minimum macOS version and system-only dependencies, carries identifier `com.local.focusstudio.mcp` with a designated requirement naming it, no entitlements, the app's Team ID, and the hardened runtime whenever the app has it. It then runs `scripts/verify-mcp-helper.py` on every slice this Mac can execute (x86_64 through Rosetta on Apple Silicon): initialize and tools/list over stdio must negotiate the requested protocol version, report `focus-studio` with the app's version and list exactly the tools in `Tests/MCPTests/v1-tools.txt`, with only JSON-RPC on stdout and a clean exit when stdin closes. The smoke test sets `FOCUS_STUDIO_MCP_NO_LAUNCH=1` and a scratch socket, so it never opens or reaches a running Focus Studio.

The build script also refuses to replace an output app that is running, including if it is launched while compilation is underway. Packaging rejects an app whose version/build does not match `Resources/Info.plist`, so `--skip-build` cannot accidentally ship an older default bundle.

## Explicit canonical installation

The native installation panel and CLI share `AppInstallation.swift`. They install only the explicit selected app into `/Applications/Focus Studio.app`, verify its signature/processor architecture and copied contents, compare numeric version/build values, reject downgrades and equal-build content conflicts, refuse replacement of a running destination, and retain a recoverable prior bundle. They do not stop apps or install online updates.

```sh
# Read-only inspection; no installation, process termination or app launch:
zsh scripts/install-app.sh "$PWD/dist/candidates/1.12.0/Focus Studio.app" --check
# Explicitly authorized installation, after finishing work in the installed app:
zsh scripts/install-app.sh "$PWD/dist/candidates/1.12.0/Focus Studio.app" --yes
# Optional one-command build + explicit installation:
./scripts/build-app.sh --install
```

The installed bundle carries its MCP helper, so AI tools that were connected to the candidate's `Contents/MacOS/focus-studio-mcp` keep using the candidate until they are pointed at `/Applications/Focus Studio.app`: open **Settings → AI tools** in the installed app and choose **Update** for a client shown as connected to another copy. The in-app installer refuses to install or open another copy while an AI tool call or a detached job (an export, say) is still running; finish or wait for that work, then try again.

The installer uses an atomic `.focusstudio-install.lock` directory in the destination parent. If installation is interrupted, inspect running installer processes and the referenced recovery folder before manually removing a stale lock; never remove another running installer's lock. Successful updates keep the prior app in the reported hidden staging folder as `previous.bundle`, not another launchable `.app`. Isolated tests (`zsh scripts/test-installation.sh`) use disposable fixture bundles and inject validation/failure behavior; they never replace a real installation.

## Create local installation packages

```sh
./scripts/package-release.sh
# If an integrated universal build has already been tested:
./scripts/package-release.sh --skip-build
```

Outputs go to `dist/releases/`: a compressed DMG, a ZIP, and SHA-256 checksums. The DMG and ZIP include the app, an Applications shortcut, installation instructions (`docs/INSTALL.md`), the third-party notices and a release-status manifest. Packaging verifies the app's and the MCP helper's architecture, minimum macOS version, signature, system-only dependencies, resource inventory, localized catalog keys and placeholders, archived copy and DMG integrity.

An ad-hoc or Apple Development signed package is named `universal-local`; a Developer ID signed package without notarization is `universal-developer-id`. Neither is described as notarized. Other Macs may require the app-specific Privacy & Security override described in INSTALL.md.

## Developer ID signing and Apple notarization

The release machine needs a valid **Developer ID Application** signing identity and an existing `notarytool` Keychain profile. Signing credentials are never stored in the repository or app. Inspect available identities with `security find-identity -v -p codesigning`.

```sh
FOCUS_STUDIO_SIGNING_IDENTITY='Developer ID Application: Your Company (TEAMID)' \
FOCUS_STUDIO_NOTARY_PROFILE='focus-studio-notary' \
./scripts/package-release.sh
```

The build enables the hardened runtime, audio-input entitlement and secure timestamp for Developer ID signatures. The package script submits the app archive using the named Keychain profile, waits for acceptance, staples and validates its ticket, then creates, signs, submits and staples the DMG. It creates the final ZIP from the stapled app. Failed notarization stops packaging; only accepted output is named `universal-notarized`.

Apple reference: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

No signing identity was present on the current build machine during initial setup. Local Universal 2 artifacts can be built, but a smooth default-Gatekeeper public release requires the publisher's Developer ID certificate and notarization credentials.

## Verification boundaries

`./scripts/verify-release.sh 'dist/Focus Studio.app' --require-universal` checks binary packaging. Run `./scripts/test.sh` and exercise the packaged app separately for recording, editing and exporting; the live MCP checks (background launch, approval prompt, one-click connect, recording through Claude Code and Codex) are listed in `docs/MCP-QA.md`. A universal executable provides both architectures, but compilation and structural checks are not a substitute for Intel hardware testing. First-run permissions must be granted independently on each destination Mac; they cannot be shipped inside a package.

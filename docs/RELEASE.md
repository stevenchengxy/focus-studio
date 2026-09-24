# Building and distributing Focus Studio

## Build

Run `./scripts/build-app.sh` on macOS with current Command Line Tools (Swift 6.1 or later since 1.5: the MCP Swift SDK and its dependencies need Swift 6 manifests). It builds separate `arm64-apple-macosx15.0` and `x86_64-apple-macosx15.0` release slices of the app and of the MCP helper `focus-studio-mcp`, combines them with `lipo`, bundles the verified static audio assets, multi-resolution icon and English / Simplified Chinese catalogs, signs and verifies the app, then replaces `dist/Focus Studio.app`. No end-user project or credentials are copied. The previous app remains intact if building or verification fails. A source-and-resource digest rejects builds if production code or bundled assets change while the two architecture slices compile.

The default is Universal 2. For local iteration only, `FOCUS_STUDIO_ARCHS=native ./scripts/build-app.sh` builds the host architecture. `arm64` and `x86_64` are also supported. The packaging script requires both slices.

To leave a running app untouched, build and package a separate candidate:

```sh
FOCUS_STUDIO_APP_DIR="$PWD/dist/candidates/1.5.0/Focus Studio.app" ./scripts/build-app.sh
FOCUS_STUDIO_APP_DIR="$PWD/dist/candidates/1.5.0/Focus Studio.app" ./scripts/package-release.sh --skip-build
```

The override must be an absolute, non-symlink path inside this checkout's `dist` directory and end in `Focus Studio.app`. Its parent is created when needed; staging and replacement are restricted to that selected parent. The default remains `dist/Focus Studio.app`. Building a candidate does not launch it or replace the default running bundle. `package-release.sh` reads the same variable, so the second command packages the candidate; its outputs still go to `dist/releases/`, where a previous package with the same name is replaced.

## The MCP helper (1.5)

`Contents/MacOS/focus-studio-mcp` is the stdio MCP server that Claude Code, Codex and other MCP clients start. It is built from `Sources/FocusStudioMCP` with the official MCP Swift SDK, pinned exactly to 0.12.1 in `Package.swift`; `Package.resolved` is kept in the repository and the release build passes `--force-resolved-versions`, so an SDK upgrade is always an explicit change. The SDK is linked statically: the helper, like the app, links only libraries that ship with macOS. The first build needs network access to fetch the pinned packages.

- **Signing order.** The helper is nested code, so it is signed first and the app's signature then seals it. It has its own identifier, `com.local.focusstudio.mcp`, and no entitlements. With a signing identity it gets the hardened runtime (`--options runtime`) and, for Developer ID, a secure timestamp; ad hoc it gets a designated requirement naming its identifier. If you ever re-sign a bundle by hand, sign the helper first with `--identifier com.local.focusstudio.mcp` (and `--options runtime` for Developer ID), then the app; `verify-release.sh` rejects any other identifier.
- **Notices.** `build-app.sh` writes the licence and notice texts of the packages the helper links (swift-sdk, swift-log, swift-system, eventsource) to `Contents/Resources/ThirdPartyNotices.txt`, and `package-release.sh` also places that file next to the app in the DMG and ZIP. A module from a package without a notice entry stops the build; after an SDK upgrade, add the new package to `build-app.sh` and `verify-release.sh`.
- **Notarization.** Apple checks nested code too. With `FOCUS_STUDIO_NOTARY_PROFILE`, `package-release.sh` refuses to submit unless the helper is signed with Developer ID Application and has the hardened runtime, like the app.
- **Verification.** `verify-release.sh` checks that the helper is a regular executable (not a symlink), has the app's architectures, minimum macOS version and system-only dependencies, carries identifier `com.local.focusstudio.mcp` with a designated requirement naming it, no entitlements, the app's Team ID, and the hardened runtime whenever the app has it. It then runs `scripts/verify-mcp-helper.py` on every slice this Mac can execute (x86_64 through Rosetta on Apple Silicon): initialize and tools/list over stdio must negotiate the requested protocol version, report `focus-studio` with the app's version and list exactly the tools in `Tests/MCPTests/v1-tools.txt`, with only JSON-RPC on stdout and a clean exit when stdin closes. The smoke test sets `FOCUS_STUDIO_MCP_NO_LAUNCH=1` and a scratch socket, so it never opens or reaches a running Focus Studio.

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

# Building and distributing Focus Studio

## Build

Run `./scripts/build-app.sh` on macOS with current Command Line Tools. It builds separate `arm64-apple-macosx15.0` and `x86_64-apple-macosx15.0` release slices, combines them with `lipo`, bundles the verified static audio assets, multi-resolution icon and English / Simplified Chinese catalogs, signs and verifies the app, then replaces `dist/Focus Studio.app`. No end-user project or credentials are copied. The previous app remains intact if building or verification fails. A source-and-resource digest rejects builds if production code or bundled assets change while the two architecture slices compile.

The default is Universal 2. For local iteration only, `FOCUS_STUDIO_ARCHS=native ./scripts/build-app.sh` builds the host architecture. `arm64` and `x86_64` are also supported. The packaging script requires both slices.

To leave a running app untouched, build and package a separate candidate:

```sh
FOCUS_STUDIO_APP_DIR="$PWD/dist/candidates/1.1.3/Focus Studio.app" ./scripts/build-app.sh
FOCUS_STUDIO_APP_DIR="$PWD/dist/candidates/1.1.3/Focus Studio.app" ./scripts/package-release.sh --skip-build
```

The override must be an absolute, non-symlink path inside this checkout's `dist` directory and end in `Focus Studio.app`. Its parent is created when needed; staging and replacement are restricted to that selected parent. The default remains `dist/Focus Studio.app`. Building a candidate does not launch it or replace the default running bundle.

## Create local installation packages

```sh
./scripts/package-release.sh
# If an integrated universal build has already been tested:
./scripts/package-release.sh --skip-build
```

Outputs go to `dist/releases/`: a compressed DMG, a ZIP, and SHA-256 checksums. The DMG includes the app, an Applications shortcut, installation instructions and a release-status manifest. Packaging verifies the app's architecture, minimum macOS version, signature, system-only dependencies, resource inventory, localized catalog keys and placeholders, archived copy and DMG integrity.

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

`./scripts/verify-release.sh 'dist/Focus Studio.app' --require-universal` checks binary packaging. Run `./scripts/test.sh` and exercise the packaged app separately for recording, editing and exporting. A universal executable provides both architectures, but compilation and structural checks are not a substitute for Intel hardware testing. First-run permissions must be granted independently on each destination Mac; they cannot be shipped inside a package.

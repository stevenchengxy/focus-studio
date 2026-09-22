# Building and distributing Focus Studio

## Release status

The source is version **1.7.1 (build 14)**. Digital humans and their selection/rendering/model resources have been removed at the user's request. AI Assistant and Demo Director remain fully conversational, with optional voice replies. Packaging rejects leftover avatar resources. Verification for this version is in [VALIDATION-1.7.1.md](VALIDATION-1.7.1.md). Automated or package checks do not by themselves prove live recording. Do not overwrite or stop the currently installed app while preparing a candidate.

Version 1.5.0 (build 9) was installed through the native installer into `/Applications/Focus Studio.app` and then launched from that canonical path. Its actual test evidence and limitations remain in [VALIDATION-1.5.0.md](VALIDATION-1.5.0.md); the version bump does not imply that those results also validate 1.6.0.

The prior **1.6.0 (build 11)** native recording validation remains in [VALIDATION-1.6.0.md](VALIDATION-1.6.0.md), including Chrome recording, pause/resume and the 72.845-second fixture. It is historical evidence, not a claim that a new physical recording was performed for the 1.7.0 avatar-only update.

## Build

Run `./scripts/build-app.sh` on macOS with current Command Line Tools. It builds separate `arm64-apple-macosx15.0` and `x86_64-apple-macosx15.0` release slices, combines them with `lipo`, bundles the verified static audio assets, multi-resolution icon and English / Simplified Chinese catalogs, signs and verifies the app, then replaces `dist/Focus Studio.app`. No end-user project or credentials are copied. The previous app remains intact if building or verification fails. A source-and-resource digest rejects builds if production code or bundled assets change while the two architecture slices compile.

The default is Universal 2. For local iteration only, `FOCUS_STUDIO_ARCHS=native ./scripts/build-app.sh` builds the host architecture. `arm64` and `x86_64` are also supported. The packaging script requires both slices.

To leave a running app untouched, build and package a separate candidate:

```sh
FOCUS_STUDIO_APP_DIR="$PWD/dist/candidates/1.7.1-b14/Focus Studio.app" ./scripts/build-app.sh
FOCUS_STUDIO_APP_DIR="$PWD/dist/candidates/1.7.1-b14/Focus Studio.app" ./scripts/package-release.sh --skip-build
```

The override must be an absolute, non-symlink path inside this checkout's `dist` directory and end in `Focus Studio.app`. Its parent is created when needed; staging and replacement are restricted to that selected parent. The default remains `dist/Focus Studio.app`. Building a candidate does not launch it or replace the default running bundle.

The build script also refuses to replace an output app that is running, including if it is launched while compilation is underway. Packaging rejects an app whose version/build does not match `Resources/Info.plist`, so `--skip-build` cannot accidentally ship an older default bundle.

## Explicit canonical installation

The native installation panel and CLI share `AppInstallation.swift`. They install only the explicit selected app into `/Applications/Focus Studio.app`, verify its signature/processor architecture and copied contents, compare numeric version/build values, reject downgrades and equal-build content conflicts, refuse replacement of a running destination, and retain a recoverable prior bundle. They do not stop apps or install online updates.

```sh
# Read-only inspection; no installation, process termination or app launch:
zsh scripts/install-app.sh "$PWD/dist/candidates/1.7.1-b14/Focus Studio.app" --check
# Explicitly authorized installation, after finishing work in the installed app:
zsh scripts/install-app.sh "$PWD/dist/candidates/1.7.1-b14/Focus Studio.app" --yes
# Optional one-command build + explicit installation:
./scripts/build-app.sh --install
```

The installer uses an atomic `.focusstudio-install.lock` directory in the destination parent. If installation is interrupted, inspect running installer processes and the referenced recovery folder before manually removing a stale lock; never remove another running installer's lock. Successful updates keep the prior app in the reported hidden staging folder as `previous.bundle`, not another launchable `.app`. Isolated tests (`zsh scripts/test-installation.sh`) use disposable fixture bundles and inject validation/failure behavior; they never replace a real installation.

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

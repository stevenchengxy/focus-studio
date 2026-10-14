# Focus Studio Desktop preview

This is an installable Windows/Linux companion for the hosted Studio editor. It shares account pairing and export allowances with the macOS app. It does **not** contain the Swift editor or the macOS MCP service.

## Current capability boundary

| Capability | Windows x64 | Linux x64 |
|---|---|---|
| Installable app | NSIS `.exe` | AppImage and Debian `.deb` |
| Choose screen/window | Local source picker | Local picker on X11; PipeWire portal selection on Wayland |
| System sound | Optional Windows loopback, covering **all applications** | Unavailable in this preview |
| Microphone | Explicit app permission plus OS permission | Explicit app permission plus OS permission |
| Editing, voiceover and export | Hosted Studio features | Hosted Studio features |
| Account pairing and one free successful export | Server-authoritative | Server-authoritative |
| macOS native effects, native project library, MCP automation | Not included | Not included |
| Offline editor startup | Not supported | Not supported |

The editor is loaded from `https://focus-studio.stevenchengxy19.chatgpt.site/studio`; an internet connection is required to open it and authorize exports. Imported media, recordings and active edits stay in memory until export; closing the window loses unexported work. Rendered export recovery journals are retained in the app's Chromium profile. Normal uninstall keeps that profile.

The website decides which codecs and controls are available. Selecting “system sound” is a request, not a promise that a stream contains sound: the editor must inspect returned audio tracks. On Windows the chooser requires a second, explicit checkbox because loopback includes sound from other windows too. On Linux the system-audio control is disabled. Microphone and imported/recorded narration remain usable where the OS permits them.

## Install and run

Download only the artifacts from the repository's desktop release or the public website's download links, and compare against the release `SHA256SUMS.txt`.

- **Windows:** run `Focus-Studio-Desktop-0.1.1-windows-x64.exe`. The installer supports installation for the current user. This preview is not Authenticode-signed, so Windows may show a publisher/reputation warning.
- **Linux AppImage:** make `Focus-Studio-Desktop-0.1.1-linux-x86_64.AppImage` executable and open it. A FUSE-compatible installation may be required; extraction with `--appimage-extract` is an alternative. A working desktop session is required.
- **Debian/Ubuntu:** install `Focus-Studio-Desktop-0.1.1-linux-amd64.deb` through the system package installer. Package dependencies must be resolved by the distribution.

Wayland recording requires a working PipeWire service and desktop portal appropriate to the compositor. A portal cancellation denies capture; the app never silently records the first returned screen. Do not disable Chromium's sandbox to bypass a distribution configuration problem.

Open **Connect account** in the editor. A local dialog opens the normal system browser; sign in and approve the matching code. The app receives a revocable device token without importing browser cookies. Windows uses DPAPI; Linux uses an available keyring (GNOME Secret Service or KWallet). With no secure Linux keyring, the token stays in memory and the user signs in again after closing the app. Account management remains available in the normal browser.

## Developer build

Requires Node.js 24. Dependencies are pinned in `desktop/package-lock.json`.

```sh
cd desktop
npm ci
npm test
npm run test:electron
npm start
```

Build installers on their corresponding CI runners:

```sh
# Windows
npm run dist:windows
# Linux
npm run dist:linux
npm run checksums
```

`.github/workflows/desktop-preview.yml` runs unit and real Electron integration smoke checks, builds Windows x64 NSIS and Linux x64 AppImage/deb, verifies Linux package metadata, and uploads installers plus checksums as Actions artifacts. It does not publish releases or sign binaries. `workflow_dispatch` can also run it manually. Publish verified installers using the [release workflow](UPDATES.md); the website and app update checker then discover the published release automatically.

## Website bridge, version 1

The isolated preload exposes `window.focusDesktop`. It never exposes Node, IPC primitives, the device token, arbitrary URLs or arbitrary file paths.

```ts
interface FocusDesktop {
  version: 1;
  getCapabilities(): Promise<{
    platform: 'win32' | 'linux' | 'darwin';
    systemAudio: 'loopback' | 'unavailable';
    microphone: true;
    version: string;
    secureTokenStorage: boolean;
  }>;
  request(input: {
    path: string;
    method: 'GET' | 'POST';
    body?: object;
  }): Promise<{status: number; body: object}>;
  startSignIn(): Promise<{userCode: string; expiresIn: number}>;
  signOut(): Promise<void>;
  onAccountChanged(callback: () => void): () => void;
  setActivity(activity: {recording: boolean; exporting: boolean}): void;
}
```

Allowed requests are `GET /api/account`, `POST /api/exports/reserve` with a UUID idempotency key and bounded project identifier, and `POST /api/exports/<uuid>/{commit,renew,release}` with an empty object. All others are rejected before network access. Requests use the paired token in the main process. Redirects and non-JSON responses fail closed. `401` clears stale login; network errors return `503` and preserve the token and uncertain export outcome. The editor must keep its existing persistent render/recovery workflow and validate the exact commit receipt before offering a completed export.

Screen and microphone streams use standard `getDisplayMedia` and `getUserMedia`. No custom stream, filesystem or computer-control bridge is provided. The editor uses native `MediaRecorder` and browser audio APIs; the desktop shell does not re-encode audio/video.

## Security design

- One pinned HTTPS origin and the `/studio` top-level page can invoke the bridge. Every IPC call checks the exact WebContents and main frame, including after asynchronous login confirmation.
- Node integration, webviews, mixed content and insecure web security are disabled; context isolation and the renderer sandbox are enabled. External frames and navigation are blocked. Account links open only approved first-party paths in the system browser.
- Source enumeration and thumbnails appear only in an isolated, bundled chooser. Selection IDs must belong to that pending request. Cancellation, navigation and concurrent requests cannot grant capture.
- Camera, geolocation, device, filesystem and other unrelated permissions are denied. Microphone access needs explicit user approval for the current app session.
- Downloads use the normal Save As dialog. The remote page cannot select a filesystem destination.
- The release packaging disables Electron's Node-mode, Node environment/inspect flags and file-protocol privileges, and restricts loading to ASAR. Windows also enables embedded ASAR integrity validation.
- No credentials are packaged. Daily update checks use the official release feed. Download prompts wait until the app is focused and idle; recording, playback, export, capture selection and permission dialogs defer them. The Help menu supports manual checking, a preview/stable channel and disabling automatic checks. Installation remains an explicit user action.

## Validation and remaining work

Local validation covers 24 policy, capture, token-storage, account-race and update tests, plus an actual Electron integration smoke using a local HTTPS fixture for the pinned host. The smoke verifies sandbox preferences, absence of Node in the page, bridge rejection, installed camera-denial policy, chooser isolation, bounded activity reporting, and rejection of privileges from the offline screen. It neither records the user's screen nor calls a live paid account.

A Linux x64 unpacked app, AppImage and Debian installer were built on macOS. The Windows and Linux jobs in [CI run 38441738897](https://github.com/stevenchengxy/focus-studio/actions/runs/38441738897) both passed the real Electron smoke, unit tests and installer builds. Source-level unit tests and macOS-hosted Electron smoke are not evidence of successful microphone/system-audio capture on a Windows or Linux machine. Required live acceptance: X11 and Wayland screen/window selection, microphone denial/grant/revocation, Windows loopback including its warning, account pairing, a free successful export and receipt recovery, install/uninstall, and session data persistence.

The current release has no Windows signing credential. macOS remains the separate native Swift app. Linux ARM64, Windows ARM64, native MCP, native offline editing and full multi-track parity remain outside this preview.

Primary implementation references: [Electron display-media handler](https://www.electronjs.org/docs/latest/api/session#sessetdisplaymediarequesthandlerhandler-opts), [desktop capture and PipeWire limits](https://www.electronjs.org/docs/latest/api/desktop-capturer), [Electron security guidance](https://www.electronjs.org/docs/latest/tutorial/security), [safeStorage platform guarantees](https://www.electronjs.org/docs/latest/api/safe-storage), and [electron-builder multi-platform builds](https://www.electron.build/v26/docs/features/multi-platform-build/).

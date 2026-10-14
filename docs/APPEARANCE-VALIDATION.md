# Appearance checks — 2026-10-14

This checkpoint covers the light, dark and system appearance update. It does not replace recording, export or platform acceptance.

## Verified

- Website production build and TypeScript checks passed. Scoped `git diff --check` passed.
- Website Light, Dark and System selections survived reload. System mode responded to a live system appearance change; preference changes synchronized between open tabs. The theme menu worked with the keyboard.
- The website had no horizontal overflow at **390 px**. Account and download interfaces were checked in dark mode.
- Browser Studio retained **In = 2 seconds**, a **14-second selection**, **Zoom** selection and its undo state across theme changes.
- Sampled Browser Studio text contrast met **4.5:1**: light secondary text on the background **6.02:1**; muted text on the background, soft panel and input well **4.84 / 4.82 / 4.61:1**; selected actions **4.57:1** in light mode and **4.94:1** in dark mode. This is a palette check, not an exhaustive accessibility audit.
- Native macOS builds passed. Source review found no theme-based editor identity reset or changes to rendered/exported media colors. The floating recording bar, timeline marks and warning foregrounds were corrected for light surfaces.
- Installed macOS **1.14.1 (63)** passed a live light/dark editor switch: the selected project, clip bounds and **00:05.000** playhead stayed in place. Home, editor, AI assistant and connection/settings surfaces were visually checked. The appearance picker selected System successfully, and a subsequent Light selection survived quitting and relaunching the app.
- The Universal2 app and packaged archives passed bundle verification. The bundled MCP helper answered over stdio with **52 tools** on both arm64 and x86_64. This does not constitute an Intel GUI test.

## Scope and remaining acceptance

- The website and `/studio` share the appearance preference stored in the current browser profile. The native Mac app stores its preference separately.
- Windows/Linux Desktop Preview loads the hosted `/studio` editor and receives its appearance controls. Its isolated capture chooser and offline fallback retain their existing appearance; no theme IPC or capture-security changes were introduced.
- Native undo-history preservation was reviewed in source but was not exercised with a new edit in this appearance-only live check. The system appearance option was selected successfully; a live macOS-wide appearance change was not performed.
- Full Windows/Linux capture and audio acceptance remains as documented in [CROSS-PLATFORM-DESKTOP.md](CROSS-PLATFORM-DESKTOP.md). Browser theme checks do not establish native recording parity.

Appearance styling leaves video pixels, thumbnails, recording and export algorithms unchanged. New editor surfaces use static fills and gradients; no blur filter was added to the canvas or timeline.

## Glass palette refinement — 2026-10-14

- Website version 5 uses a lavender-to-ice-blue ambient gradient, a restrained blush accent, white glass surfaces and blue action gradients. Dark theme colors retain their previous values.
- The production build through the Sites build helper and TypeScript checks passed. Light desktop (1440 px), light mobile (390 px), dark desktop and the Browser Studio sample editor were visually checked. The mobile layout's document width is 390 px, with no horizontal overflow.
- The responsive sculpture opacity now follows the existing breakpoints. Small secondary text and blue accent text were darkened after contrast review; the white button text has at least 4.65:1 contrast across the action gradient.
- The native library, preview background, panels, buttons and tracks use matching static gradients. No new video/timeline blur filters or animated background loops were introduced.
- Installed macOS **1.14.2 (64)** was checked in the library and editor. Light → Dark retained the project, clip bounds, paused frame and **00:05.000** position; after stepping a frame, Dark → Light retained **00:05.033**. A screenshot misinterpretation initially reported as issue #31 was corrected and closed; no playback refresh patch is included.
- Universal2 bundle and archive verification passed, including MCP discovery with **52 tools** on arm64 and x86_64. This remains an ad-hoc signed preview, not an Apple-notarized release.

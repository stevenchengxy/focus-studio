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

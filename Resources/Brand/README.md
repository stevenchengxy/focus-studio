# Focus Studio brand mark

`FocusStudioIcon.svg` is the editable vector master. Created on 2026-10-15 from the Focus Studio website's own lavender aperture sculpture (`website/components/marketing/focus-sculpture.tsx` and its CSS). The rounded glass frame, pearl highlights, dark aperture, focus corners, and play gesture connect the app identity to that sculpture. The icon stays upright for a clear silhouette at small sizes; its restrained lower edge supplies depth without perspective distortion.

This is an authored SVG, with no embedded bitmap, external font, third-party logo, or generated image. `FocusStudioIcon.png` is the 1024 × 1024 RGBA export with a transparent exterior. The previous raster-only icon remains recoverable in Git history.

## Regenerate

With the website dependencies installed, run from the repository root:

```sh
node scripts/generate-brand-assets.cjs
zsh scripts/build-icon.sh
```

The export script uses Sharp's SVG renderer and synchronizes these files:

- `Resources/Brand/FocusStudioIcon.png` — macOS in-app master, 1024 px.
- `website/public/icons/focus-studio.svg` and `website/public/favicon.svg` — exact vector copies for browser use.
- `website/public/icons/focus-studio.png` — 1024 px web image.
- `website/public/icons/icon-192.png` and `icon-512.png` — PWA install icons.
- `desktop/build/icon.png` — 512 px Windows/Linux packaging source.

`build-icon.sh` packages all macOS icon sizes into `Resources/FocusStudio.icns`. It only needs the committed PNG and macOS system tools, so ordinary app builds do not depend on Node.js. The app build embeds both ICNS and PNG.

Use the complete mark on light or dark backgrounds. Preserve its transparent exterior and dark aperture; do not add a colored tile or crop away the outer bevel.

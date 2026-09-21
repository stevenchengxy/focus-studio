# Seedream prompting for product-demo stills

## Contents
1. Presets shipped in `generate_still.py`
2. Recipes (EN + 中文)
3. Layout rules for text overlays
4. Reference-image (restyle) guidance
5. Sizes and where each image goes

## 1. Presets

`--preset` wraps `{prompt}` (your description) in scaffolding tuned for enterprise demos:

* **hero-bg** - "Cinematic widescreen hero background for an enterprise software product video. {prompt}. Abstract
  composition: layered frosted glass panels, soft volumetric light, subtle depth of field, deep gradient, clean
  negative space in the center for a title. Photorealistic 3D render, high detail. No text, no letters, no numbers,
  no logos, no watermark, no people, no hands."
* **title-card** - dark, minimal, darker center so white text stays readable, fine film grain.
* **feature-icon** - a single minimal 3D glass icon of {prompt}, centered on plain dark background, studio light.
* **restyle-screenshot** - keeps the reference UI legible and unchanged, places it on a floating glass card with soft
  shadow and slight perspective above a background of {prompt}.
* **none** - your prompt verbatim (remember the no-text sentence yourself).

## 2. Recipes

### Hero background (片头背景)
EN: `--preset hero-bg --prompt "deep violet and indigo gradient space, floating frosted glass panels with thin luminous edges, soft cyan-purple rim light, faint grid of light on the floor, subtle bokeh"`

中文：`--preset hero-bg --prompt "深紫到靛蓝的渐变空间，悬浮的磨砂玻璃面板带有细微发光边缘，柔和的青紫色轮廓光，地面有淡淡的光栅，少量光斑"`

### Stat / number card background (数据卡片)
EN: `--preset title-card --prompt "graphite to deep blue gradient, one soft diagonal light streak, very low detail, darker lower half"`
Then let the composer draw "查询延迟降低 70%" as the `title` of a `still` segment.

### Feature icons (章节图标, 1:1, 1K)
EN: `--preset feature-icon --prompt "a rounded rectangle window with a magnifying glass, glass and violet glow"` /
`"a microphone and a speaker wave"` / `"two overlapping cursors"`. Generate the set with the same `--seed` for consistency.

### CTA / ending background (片尾)
EN: `--preset title-card --prompt "calm deep violet gradient, soft light from bottom-left, tiny particles, empty center"`

### Screenshot to marketing hero (截图变主视觉)
`--preset restyle-screenshot --reference shot.png --prompt "deep purple gradient with soft light and faint reflections"`
Use a screenshot exported from Focus Studio (already padded with the brand gradient) for best results.

## 3. Layout rules for text overlays

* Title in the middle → ask for "empty center" and "darker center"; caption at the bottom → "calm lower third".
* White text needs luminance contrast: prefer gradients that end dark at the text position.
* Keep the horizon/line of glass panels away from the safe area where text sits (avoid busy detail behind text).
* For 4K output generate 4K stills (`--size 4K --ratio 16:9` → 4096×2304); 2K is enough for 1080p.

## 4. Reference-image guidance

* One reference: "keep the interface exactly as shown, fully legible" - Seedream 4.x preserves screenshots well
  when told explicitly; add "do not change colors, layout or icons".
* Several references (palette + screenshot): describe which is which - "use the first image's color palette, keep
  the second image's interface unchanged".
* Do not send confidential or customer data; the image leaves the machine. Blur or mock data in Focus Studio first.
* Aspect: references must be between 1:3 and 3:1; the script downsizes to 2048 px.

## 5. Where each image goes

| image | size | storyboard use |
| --- | --- | --- |
| hero background | 2K/4K 16:9 | `still` segment with `motion: zoom_in` + `title`, or `first_frame` of the Seedance opener |
| stat card | 2K 16:9 | `still` + `title` (number as text) |
| icons | 1K 1:1 | `logo` overlay or inside Focus Studio |
| CTA background | 2K 16:9 | `title` segment `background` (image path) |
| restyled screenshot | 2K 16:9 | `still` with `motion: pan_right`, or Focus Studio "Screenshot demo" |

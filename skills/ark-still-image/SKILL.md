---
name: ark-still-image
description: Generate still images with Volcengine Ark (火山引擎 / 火山方舟) Seedream models - doubao-seedream-5.0-pro, 5.0, 4.5, 4.0 - for product demo and launch videos - title cards, 16:9 hero backgrounds, feature icons, stat cards, and "restyle this screenshot into a marketing hero" using a reference image. Use whenever the user mentions Seedream, 火山方舟生图, AI 生图, 标题卡 / 片头背景 / 主视觉 / 图标, wants a background for text overlays, or wants a Focus Studio screenshot turned into a polished marketing visual. Estimates cost, caches by request hash, converts the result to PNG/JPEG.
---

# ark-still-image - Seedream stills for product demos

`scripts/generate_still.py` calls the Ark image API (`POST /images/generations`) and saves one image plus a
sidecar JSON. Stills are cheap (≈ ¥0.2-0.3 each at 2K) and often replace a video clip: the composer adds
Ken Burns motion (`still` segments), so a title card, a stat card or a CTA background rarely needs Seedance.

## Before you spend money

* `python3 ../_shared/ark_client.py check` → the key is configured (from `$ARK_API_KEY` or
  `~/.config/focus-studio/ark.env`; never print it, never paste it into chat or the repo).
* `python3 ../_shared/ark_client.py probe-activation` → free; `404 ModelNotOpen` means the user must activate the
  model in the Ark console (火山方舟控制台 → 开通管理) first.
* `--dry-run` prints the exact request and the estimated cost; do that before the first real call and whenever
  you change `--size` or model.

## Quick start

```bash
S=skills/ark-still-image/scripts
# 16:9 hero background (2560x1440) for a title card
python3 $S/generate_still.py --preset hero-bg --ratio 16:9 --size 2K \
  --prompt "deep violet and indigo gradient, floating frosted glass panels, soft cyan rim light" \
  --model doubao-seedream-4-5-251128 --seed 7 --out ai-clips/hero-bg.png
# restyle a Focus Studio screenshot into a floating-glass marketing hero
python3 $S/generate_still.py --preset restyle-screenshot --reference ~/Pictures/Focus\ Studio\ Screenshots/shot.png \
  --prompt "deep purple gradient with soft light" --out assets/hero.png
# icon for a feature chapter
python3 $S/generate_still.py --preset feature-icon --prompt "a cursor inside a zoom lens" --size 1K --ratio 1:1 --out assets/icon-zoom.png
```

Presets (`--preset`) wrap your description in tested scaffolding and forbid text/logos - see
`references/prompting.md` for the full texts and when to override with `--preset none`:
`hero-bg`, `title-card` (both default to 16:9), `feature-icon`, `restyle-screenshot` (needs `--reference`), `none`.

Sizes: `--size 1K|2K|4K` lets the model choose the aspect; add `--ratio 16:9` (or 9:16, 1:1, 4:3, 3:4, 3:2, 2:3, 21:9)
to get explicit pixels (2K·16:9 → `2560x1440`, 4K·16:9 → `4096x2304`, 1K·16:9 → `1280x720`), or pass `WxH`
directly (area ≥ 1280×720, long side ≤ 4096). Match the video canvas: 2K for 1080p output, 4K for 4K output.

Reference images (`--reference`, up to 10) may be local files - they are embedded as base64 data URLs after
downscaling to 2048 px - or URLs. Local screenshots are sent to Volcengine; do not use confidential screens.

## Model selection

| model | when | approx. ¥/image |
| --- | --- | --- |
| `doubao-seedream-4-5-251128` (default) | reliable composition, good glass/gradient looks, cheap | 0.25 |
| `doubao-seedream-4-0-250828` | budget drafts, icon sets | 0.20 |
| `doubao-seedream-5-0-260128` | better realism and typography-free layouts | ≈ 0.30 (estimate) |
| `doubao-seedream-5-0-pro-260628` | final hero images, 4K | ≈ 0.35 (estimate) |

Numbers are budgeting estimates; `<out>.json` stores the real `usage` block for calibration.

## The request the script sends

`POST {ARK_BASE_URL}/images/generations` with `Authorization: Bearer $ARK_API_KEY`:

```json
{
  "model": "doubao-seedream-4-5-251128",
  "prompt": "Cinematic widescreen hero background for an enterprise software product video. ... No text, no letters, no numbers, no logos, no watermark, no people, no hands.",
  "size": "2560x1440",
  "response_format": "url",
  "watermark": false,
  "sequential_image_generation": "disabled",
  "seed": 7,
  "image": "data:image/jpeg;base64,..."
}
```

`image` is only present with `--reference` (a string for one image, a list for several); `output_format`
(`png|jpeg|webp`) only with `--format`; `--extra '{"guidance_scale": 5}'` merges extra fields.
Response: `{"data": [{"url": "https://...", "size": "2560x1440"}], "usage": {...}}` - the URL is temporary and is
downloaded immediately; the script converts to the extension of `--out` with Pillow when the API returns JPEG.

Verification status (2026-09-21): this exact request (hero-bg preset, 2560x1440, seedream-4-5) was submitted with the
account key; Ark answered `404 ModelNotOpen` for every Seedream model, i.e. the account has not activated image
models yet. Field names follow the current Ark reference. After activation, run one `--dry-run` and one real
2K call; if `400 InvalidParameter` names `size`, fall back to `--size 2K` without `--ratio`, and record the accepted
shape here.

## Writing prompts

`references/prompting.md` has recipes in English and Chinese. Non-negotiables:

* No text, letters, numbers, logos or watermarks in the image - text is added by the composer.
* Leave **negative space** where the title will go (center for hero, lower third for captions, darker area for
  white text).
* Keep the palette identical to the video clips and the Focus Studio background colour (`settings.backgroundColor`).
* For `restyle-screenshot`, insist that the interface stays legible and unchanged; only the surroundings are new.

## Output and hand-off

`<out>.png` (or .jpg/.webp), `<out>.png.json` sidecar (request with data URLs redacted, usage, cost, cache key), and a
cache entry in `<out dir>/.cache/`. Use it as a storyboard `still` segment (`asset`), as `first_frame` for a
Seedance clip, as a `title` segment `background`, or import it into Focus Studio ("Screenshot demo" turns a PNG into
a 12-second editable project).

## Troubleshooting

| symptom | fix |
| --- | --- |
| exit 3 `ARK_API_KEY is not configured` | create `~/.config/focus-studio/ark.env` (see README) |
| `404 ModelNotOpen` | activate the model in the console; nothing was billed |
| `400` mentioning `size` | use `--size 2K` (class) instead of explicit pixels, or an aspect between 1:3 and 3:1 |
| `400` mentioning `image` | reference too small (< 300 px), wrong aspect, or too many references (max 10) |
| result has text/logos | strengthen the exclusion sentence, lower detail words like "poster", "UI", "banner" |
| wrong aspect with `--size 2K` alone | add `--ratio 16:9` for explicit pixels |
| `CERTIFICATE_VERIFY_FAILED` | `export SSL_CERT_FILE=/etc/ssl/cert.pem` (python.org builds ship without CA certs) |

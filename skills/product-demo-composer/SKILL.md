---
name: product-demo-composer
description: Compose the final enterprise-grade product demo / launch video with ffmpeg from a storyboard.json - Focus Studio export chapters with Chinese/English captions, AI hero and B-roll clips (Volcengine Ark Seedance) and stills (Seedream) with Ken Burns motion, title/CTA cards, xfade transitions, background music with ducking, 1080p or 4K output plus a render report. Use whenever the user wants to render, assemble, stitch, 合成 or export a demo video, add 片头/片尾/字幕/BGM to a screen recording, generate the missing AI assets of a storyboard, make a quick preview render, or re-import the result into Focus Studio.
---

# product-demo-composer - storyboard.json → final MP4

`scripts/compose_demo.py` reads a storyboard (schema in `../demo-storyboard/references/storyboard-schema.md`),
normalises every segment to the output canvas, burns captions with a CJK-capable font, joins everything with
xfade/acrossfade, mixes BGM with ducking and writes `<output>.mp4` + `<output>-render-report.json`.
`scripts/probe_media.py` is the ffprobe helper used for verification. Both need ffmpeg 7.x
(`/usr/local/bin/ffmpeg` with libx264, drawtext, xfade, sidechaincompress) and Python 3.9+ (stdlib only).

## Workflow

```bash
C=skills/product-demo-composer/scripts
python3 $C/compose_demo.py storyboard.json --dry-run          # 1. plan: durations, transitions, placeholders, cost, commands
python3 $C/compose_demo.py storyboard.json --preview          # 2. fast 720p draft (<output>-preview.mp4) - watch it
python3 $C/compose_demo.py storyboard.json --generate         # 3. create missing ai_clip/still assets (asks Ark, bills once, cached)
python3 $C/compose_demo.py storyboard.json                    # 4. final render at storyboard resolution
python3 $C/probe_media.py --brief final.mp4                   # 5. verify size / fps / duration / audio
```

Money is only spent with `--generate`; without it, missing AI assets become animated-gradient placeholders that
carry the segment's title/caption plus a small "AI placeholder" label, so the cut can be reviewed for free.
Before running `--generate`, show the user the `--dry-run` line "would generate N asset(s), estimated ≈ ¥X" and
get a go-ahead. Generated assets land in `generation.assets_dir` (default `assets/`) with a sidecar JSON and a
request-hash cache in `assets/.cache/`, so re-rendering never re-bills. `--force-generate` re-bills deliberately.

Verification: after the final render, read the report, run `probe_media.py`, and extract two or three frames
(`ffmpeg -ss 8 -i final.mp4 -frames:v 1 f.png`) to check caption placement and Chinese glyphs before delivering.

## What the composer does

* **Canvas**: `output.width × height @ fps` (1920×1080@30 default; 3840×2160 and 60 fps supported), `yuv420p`,
  libx264 `crf 18` `preset medium` (`h264_videotoolbox` optional), AAC 192 kbps 48 kHz stereo, `+faststart`.
  `--width/--height/--fps` override; `--preview` forces 1280×720, crf 28, ultrafast.
* **demo** segments: `-ss/-t` trim, optional `speed` (setpts + atempo), `contain` scale + pad with `output.background`.
* **ai_clip**: existing `asset` (cover-fit, trimmed) → generated (`--generate`) → placeholder.
* **still**: image with `zoompan` Ken Burns (`zoom_in`, `zoom_out`, `pan_left`, `pan_right`, `none`), rendered from a
  2× oversampled frame so motion stays smooth.
* **title**: animated three-stop gradient derived from `background` (or an image) with centred title/subtitle.
* **Text**: ffmpeg `drawtext` with per-overlay fade in/out, `title` (centred) and `caption` (lower-third with
  translucent box and an accent "kicker" chip). Font lookup order: `output.font` / `--font` / `$FOCUS_DEMO_FONT` →
  PingFang (found under `/System/Library/AssetsV2/.../PingFang.ttc` on current macOS, or `/System/Library/Fonts/PingFang.ttc`)
  → Hiragino Sans GB → STHeiti → Songti → Arial Unicode → Helvetica → Noto/WenQuanYi/DejaVu on Linux. All of the
  macOS defaults render Simplified Chinese; the chosen file is printed in the `[plan]` line and stored in the report.
* **Transitions**: xfade (any name from the schema list) with matching `acrossfade`; `cut` uses `concat`. Every
  intermediate is an h264 + PCM `.mov` at the exact canvas spec so xfade never complains about mismatched inputs.
  Transition length is clamped below both neighbours; the first segment's transition is ignored (use `output.fade_in`).
* **Audio**: program audio = each segment's own track (silence where none). BGM is looped/trimmed, faded, and ducked:
  `sidechain` (`sidechaincompress`, threshold 0.02, ratio 8, attack 30 ms, release 600 ms - dips under narration
  and UI sounds), `segments` (fixed `level` during audible segments - deterministic), or `none`. `amix` with
  `normalize=0` keeps levels honest; optional `loudnorm` (EBU R128, I=-16) and `master_volume` at the end.
* **Report**: `<output>-render-report.json` - spec, font, per-segment input/trim/duration/transition/caption,
  timeline start/end per segment, assets (existing/generated/cached/placeholder with usage and cost), ffmpeg
  commands, and the ffprobe of the result.

## Tested on 2026-09-21

Synthetic inputs (`testsrc2` demo with a beeping `sine`, a 24 fps clip without audio, a 220 Hz BGM) through a
3-segment storyboard (ai_clip + title overlay → demo with trim + Chinese caption → title CTA, slideleft/fade,
sidechain ducking) rendered in 6.5 s to 1920×1080@30 fps yuv420p, AAC 48 kHz stereo, duration 13.60 s = 5 + 7 + 3
− 0.6 − 0.8. A second storyboard exercised placeholders, a Ken Burns still, `cut`, `speed: 2.0`, top captions,
`segments` ducking and `loudnorm` (11.10 s, exact). Frames were inspected: PingFang glyphs, caption box, chip and
placeholder label render correctly. Test artefacts live in `.artifacts/ai-clips/composer-test*/`.

## Re-importing into Focus Studio and publishing

* Focus Studio can import an existing MP4/MOV ("导入现有 MP4/MOV 并手动添加缩放"): import `final.mp4` to add
  zooms, cursor effects or the Focus Studio audio finishing on top. Render with `audio.loudnorm: false` and
  no BGM in that case, and let Focus Studio mix music.
* For direct publishing keep `loudnorm: true`, `crf 18`, `+faststart` (already set) - the file plays progressively.
* Deliver 4K by setting `output.width: 3840, height: 2160` and generating 4K stills (`--size 4K`); AI clips at
  720p/1080p are upscaled with lanczos, which is acceptable for abstract footage.

## Troubleshooting

| symptom | fix |
| --- | --- |
| `no usable font found` | `--font /path/to/font.ttf` (needs CJK glyphs for Chinese) or set `output.font` |
| Chinese shows as boxes | the font has no CJK glyphs - use PingFang/Hiragino/Arial Unicode |
| `transition ... clamped` | shorten the transition or lengthen the neighbouring segments |
| `demo source not found` | paths are relative to the storyboard file; export from Focus Studio first |
| `ffmpeg failed while assembling` with xfade errors | run with `--work-dir work --verbose`, inspect the `.mov` intermediates with `probe_media.py` |
| render is slow | `--preview` while iterating; `preset: veryfast` in `output` for drafts; 4K at `medium` takes minutes |
| BGM pumps audibly | raise `duck.release` to 900-1200 ms, lower `ratio` to 4, or switch to `duck.mode: segments` |
| audio too quiet/loud on upload | `audio.loudnorm: true` for publishing; adjust `master_volume` |
| `cannot generate: _shared/ark_client.py not found` | keep the `_shared` folder next to the skill folders, or set `FOCUS_SKILLS_SHARED` |
| `404 ModelNotOpen` during `--generate` | activate the model in the Ark console; nothing billed - rerun later, the cut still works with placeholders |

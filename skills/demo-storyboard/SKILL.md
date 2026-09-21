---
name: demo-storyboard
description: Turn a product description plus a Focus Studio recording (project.json with clickEvents/zoomSegments, or just the exported MP4) into a storyboard.json for an enterprise-grade product demo / launch video - hero opener, 3-6 feature chapters cut from the recording with captions, optional AI stills/clips (Volcengine Ark Seedance/Seedream) and a closing CTA. Use whenever the user wants to plan, script or structure a 产品演示视频 / demo video / 发布视频 / feature walkthrough, asks for chapters, captions, subtitles or 分镜 for a screen recording, or wants to know which parts of a recording to keep before composing.
---

# demo-storyboard - from recording to storyboard.json

The storyboard is the contract between the human, Claude and `product-demo-composer`: an ordered list of
segments (`demo` slices of the Focus Studio export, `ai_clip`, `still`, `title`) with captions, transitions and
audio settings. Get it right here and the composer is a one-liner.

Full schema: `references/storyboard-schema.md`. Worked examples: `examples/saas-dashboard-launch.json`
(SaaS, Chinese captions, sidechain ducking) and `examples/devtool-feature-update.json` (developer tool, English,
still-based opener, cuts). Copy the closest one instead of starting from scratch.

## Workflow

### 1. Collect inputs (ask if missing)

* What the product is, who watches the video, and the one sentence the viewer should remember.
* Language of captions (zh / en / both), target length (45-90 s is the sweet spot), 1080p or 4K, 30 or 60 fps.
* The Focus Studio project dir (`~/Library/Application Support/FocusStudio/Projects/<uuid>/`) and, ideally, the
  **exported MP4** - the export has zooms, cursor and background baked in; `raw.mp4` does not.
* Whether AI footage is wanted (needs an activated Ark account; costs money) or the demo should stay recording-only.
* Brand colour (defaults to `settings.backgroundColor`), logo PNG, BGM file (Focus Studio ships CC0 tracks under
  `Resources/Audio/`; any mp3/wav works).

### 2. Draft the chapters from the recording

```bash
python3 skills/demo-storyboard/scripts/storyboard_from_project.py \
  --project "~/Library/Application Support/FocusStudio/Projects/<uuid>" \
  --export ~/Movies/demo-export.mp4 --product "Focus Studio, a macOS product-demo recorder" \
  --title "Focus Studio 1.2" --lang zh --thumbs work/thumbs --out work/storyboard.json
```

The script clusters enabled `zoomSegments` (fallback: `clickEvents`, then an even split) into 3-6 chapters, cuts
each chapter ~1 s before its first interaction, writes `TODO` caption placeholders, `notes` with the zoom times and
targets, and one JPEG per chapter in `--thumbs`. Options: `--min-chapters/--max-chapters`, `--gap` (seconds of
idle time that separate chapters), `--lead`, `--skip-head`, `--trim-tail`, `--no-hero`, `--no-cta`, `--bgm`,
`--width 3840 --fps 60`.

### 3. Look, then write

Open every thumbnail (they are images - read them) and the `notes`; replace each TODO with a caption that states
the **benefit shown on screen**, not the click: "一键录制窗口，自动生成缩放镜头" beats "点击开始录制". Rules that keep
captions readable at 44 px on 1080p: ≤ 18 汉字 or ≤ 9 English words per line, at most two lines, verb first,
numbers as digits, no trailing punctuation. Use the `kicker` for chapter numbers ("01") or short labels ("NEW").

Adjust trims by hand when a chapter drags: shorten dead time before a click, add `"speed": 1.25-1.5` for long typing
or loading stretches, never cut in the middle of a zoom animation (check `zoomSegments` start/end in the notes).

### 4. Decide the AI shots (optional)

* Opener: an `ai_clip` (Seedance, 5 s) or - half the cost and often enough - a `still` (Seedream) with
  `motion: zoom_in` and the product name as `title`.
* One `still` "stat card" between chapters for a number worth remembering; a short `ai_clip` B-roll only when the
  recording has no visual for a claim ("syncs across the team").
* Ending: a `title` segment on the brand colour, or a `still` background.
* Write prompts with `../ark-video-clip/references/prompting.md` and `../ark-still-image/references/prompting.md`:
  abstract glass/gradient, same palette as `output.background`, and always "no text, no logos". Put the prompt,
  model, seed and `asset` path on the segment so the composer can generate it with `--generate` later.

### 5. Transitions, audio, output

* Transitions: `fade` 0.5-0.6 s into and out of AI shots, `slideleft`/`smoothleft` 0.5 s between chapters,
  `cut` when the timeline must stay honest (terminal timing), `fadeblack` 0.7 s before a stat card.
* Audio: keep `audio: true` on chapters with narration/UI sounds and use sidechain ducking; mute keyboard-heavy
  chapters (`audio: false`) and use `duck.mode: segments` when the BGM should only dip under narration.
* Output: 1920×1080@30 for the web, 3840×2160 for keynote screens, 60 fps only if the export is 60 fps.

### 6. Validate before rendering

```bash
python3 skills/product-demo-composer/scripts/compose_demo.py work/storyboard.json --dry-run
```

Fix anything the plan reports (missing sources, clamped transitions, placeholders) and hand the file to
`product-demo-composer`. The composer ignores `notes`/`thumbnail`, so leave them in for the next revision.

## Segment cheat sheet

```json
{"id": "hero",       "type": "ai_clip", "duration": 5, "prompt": "...", "asset": "assets/hero.mp4", "title": {"text": "Focus Studio", "subtitle": "一句话价值主张"}}
{"id": "chapter-01", "type": "demo",    "source": "exports/demo.mp4", "trim": {"start": 0, "end": 11.5}, "caption": {"kicker": "01", "text": "..."}, "transition": {"type": "fade", "duration": 0.6}}
{"id": "stat",       "type": "still",   "duration": 4, "prompt": "...", "asset": "assets/stat.png", "motion": "zoom_in", "title": {"text": "查询延迟降低 70%"}, "transition": {"type": "fadeblack", "duration": 0.7}}
{"id": "cta",        "type": "title",   "duration": 4, "background": "#0B0A1F", "title": {"text": "立即体验", "subtitle": "focusstudio.app"}, "transition": {"type": "fade", "duration": 0.8}}
```

Final length = Σ segment lengths − Σ transition durations. Paths are relative to the storyboard file.

## Focus Studio project.json fields you will use

`duration` (s), `sourceWidth/sourceHeight`, `clickEvents[{time,x,y}]` (normalised 0-1), `zoomSegments[{start,end,
targetX,targetY,scale,kind: automatic|manual, isEnabled}]`, `settings.backgroundColor` (hex → brand colour),
`settings.aspectRatio`, `settings.frameRate`, `settings.exportWidth`. The recording itself is `raw.mp4` next to it.

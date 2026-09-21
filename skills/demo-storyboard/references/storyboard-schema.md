# storyboard.json 结构说明 / Storyboard schema (version 1)

A storyboard is one JSON object. All relative paths are resolved **relative to the storyboard file**.
`compose_demo.py` (product-demo-composer) is the consumer; `storyboard_from_project.py` writes drafts.
Unknown keys are ignored, so `notes`/`thumbnail` fields are safe to keep for humans and Claude.

## Top level

| key | type | meaning |
| --- | --- | --- |
| `version` | int | always `1` |
| `title` | string | video title, reused by the hero/CTA text |
| `language` | `zh` \| `en` | caption language hint (no effect on rendering) |
| `product` | string | one-line product description used when writing prompts |
| `output` | object | encoding + canvas, see below |
| `style` | object | text styling defaults, see below |
| `audio` | object | BGM / ducking / loudness, see below |
| `generation` | object | defaults for AI assets (models, sizes) |
| `segments` | array | ordered list, at least one |

### `output`

| key | default | notes |
| --- | --- | --- |
| `path` | `final.mp4` | relative to the storyboard file; `--out` overrides |
| `width`, `height` | 1920 × 1080 | even numbers; 3840 × 2160 for 4K; every segment is scaled+padded to this canvas |
| `fps` | 30 | 24 / 30 / 60 |
| `background` | `#0B0A1F` | pad colour behind `contain` segments and base of gradient backgrounds |
| `font` | auto | font file; auto = PingFang → Hiragino Sans GB → STHeiti → Songti → Arial Unicode → Helvetica |
| `codec` | `libx264` | or `h264_videotoolbox` (then `bitrate`, default `16M`) |
| `crf`, `preset` | 18, `medium` | libx264 quality/speed |
| `fade_in`, `fade_out` | 0 | seconds of fade from/to black on the whole film |
| `logo` | – | `{path, position: top-right|top-left|bottom-right|bottom-left, width, margin, opacity}` PNG with alpha |

### `style`

```json
"style": {
  "accent": "#8B7CFF",
  "title":   {"size": 96, "subtitle_size": 40, "color": "#FFFFFF", "subtitle_color": "#D6D2FF", "gap": 28},
  "caption": {"size": 44, "color": "#FFFFFF", "box": true, "box_color": "#000000@0.45", "margin": 96,
              "kicker_size": 26, "kicker_color": "#0B0A1F", "box_border": 18},
  "text_fade": 0.35
}
```
Sizes are designed for 1080p and scale with the output height. Colours are `#RRGGBB` or `#RRGGBB@alpha`.

### `audio`

```json
"audio": {
  "bgm": {"path": "music.mp3", "volume": 0.18, "fade_in": 1.5, "fade_out": 2.0, "loop": true,
          "duck": {"mode": "sidechain", "level": 0.3, "threshold": 0.02, "ratio": 8, "attack": 30, "release": 600}},
  "loudnorm": false,
  "master_volume": 1.0
}
```
* `duck.mode`: `sidechain` (ffmpeg `sidechaincompress`, BGM dips whenever the program audio is loud - narration,
  UI sounds), `segments` (BGM is set to `level` during every segment whose audio is active - deterministic, no
  pumping), or `none`.
* `loudnorm: true` applies EBU R128 (`I=-16`) at the very end - use it for publishing, skip it when the
  result goes back into Focus Studio for further mixing.
* No `bgm` → the program audio (demo narration) is passed through untouched.

### `generation`

```json
"generation": {
  "enabled": false,
  "assets_dir": "assets",
  "video": {"model": "doubao-seedance-2-0-mini-260615", "resolution": "720p", "ratio": "16:9", "generate_audio": false},
  "image": {"model": "doubao-seedream-4-5-251128", "size": "2K"}
}
```
`enabled` is informational; the composer only spends money when run with `--generate`. Assets are written to
`assets_dir/<segment id>.mp4|png` unless a segment sets `asset`, and the request hash cache lives in
`assets_dir/.cache` (re-running never re-bills a finished asset).

## Segments (common fields)

| key | meaning |
| --- | --- |
| `id` | unique; used for file names and the report |
| `type` | `demo` \| `ai_clip` \| `still` \| `title` |
| `transition` | how this segment comes in: `{"type": "fade", "duration": 0.5}`; `cut` (or duration 0) = hard cut. Ignored on the first segment (use `output.fade_in`). Duration is clamped below both neighbours' lengths. |
| `title` | big centred text: `{"text", "subtitle", "start", "end", "align": "center"|"left", "size", "color"}` |
| `caption` | lower-third: `{"text", "kicker": "01", "position": "bottom"|"top", "start", "end", "box", "align"}` - multi-line with `\n` |
| `audio` | keep the segment's own audio (default `true` for demo, `false` otherwise) |
| `fit` | `contain` (pad with background, default for demo) or `cover` (crop, default for AI/still) |
| `notes` | free text for humans; ignored |

xfade transition names accepted: `fade fadeblack fadewhite fadefast fadeslow dissolve wipeleft wiperight wipeup wipedown
slideleft slideright slideup slidedown smoothleft smoothright smoothup smoothdown circlecrop rectcrop circleopen
circleclose vertopen vertclose horzopen horzclose distance radial pixelize fadegrays diagtl diagtr diagbl diagbr hlslice
hrslice vuslice vdslice hblur wipetl wipetr wipebl wipebr squeezeh squeezev zoomin hlwind hrwind vuwind vdwind coverleft
coverright coverup coverdown revealleft revealright revealup revealdown`. Enterprise demos read best with `fade`,
`fadeblack`, `slideleft`, `smoothleft`, `wipeleft` at 0.4-0.8 s.

### `demo` - a slice of the Focus Studio export

```json
{"id": "chapter-01", "type": "demo", "source": "exports/demo.mp4",
 "trim": {"start": 12.0, "end": 24.5}, "speed": 1.0,
 "caption": {"kicker": "01", "text": "一键录制窗口", "start": 0.4}, "audio": true,
 "transition": {"type": "slideleft", "duration": 0.5}}
```
`trim` takes `end` or `duration`; omit for the whole file. `speed` 0.5-4.0 (video `setpts` + audio `atempo`).

### `ai_clip` - Seedance clip

```json
{"id": "hero", "type": "ai_clip", "duration": 5, "asset": "assets/hero.mp4",
 "prompt": "...", "model": "doubao-seedance-2-0-mini-260615", "resolution": "720p", "ratio": "16:9",
 "seed": 42, "first_frame": "assets/hero-bg.png", "generate_audio": false, "camera_fixed": false,
 "trim": {"start": 0, "end": 5}, "title": {"text": "Focus Studio", "subtitle": "产品演示"}}
```
Resolution order: existing `asset` file → generated with `--generate` (prompt required; `first_frame`,
`last_frame`, `reference` may be local files) → placeholder (animated gradient + the segment's text + a small
"AI placeholder" label). `duration` is the requested clip length and the placeholder length.

### `still` - Seedream image with Ken Burns motion

```json
{"id": "stat", "type": "still", "duration": 4, "asset": "assets/stat.png",
 "prompt": "...", "model": "doubao-seedream-4-5-251128", "size": "2K", "ratio": "16:9", "seed": 7,
 "reference": ["shots/dashboard.png"], "motion": "zoom_in", "motion_amount": 0.08,
 "title": {"text": "查询延迟降低 70%"}}
```
`motion`: `zoom_in` (default) | `zoom_out` | `pan_left` | `pan_right` | `none`.

### `title` - text card on a gradient or image

```json
{"id": "cta", "type": "title", "duration": 4, "background": "#0B0A1F",
 "title": {"text": "立即体验", "subtitle": "focusstudio.app"}, "transition": {"type": "fade", "duration": 0.8}}
```
`background` is a hex colour (animated three-stop gradient derived from it) or an image path (then `motion` applies).

## Timing rules

* Final length = Σ segment lengths − Σ transition durations (cuts subtract nothing).
* Text `start`/`end` are relative to the segment; captions on demo chapters usually start at 0.3-0.5 s so they do
  not fight the incoming transition.
* Keep every segment ≥ 1.5 s and every transition ≤ 0.8 s; the composer clamps offenders and logs it.
* AI clips are 4-15 s (Seedance 2.x); use `trim` to take the best 3-5 s.

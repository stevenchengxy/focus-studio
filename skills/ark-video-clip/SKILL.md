---
name: ark-video-clip
description: Generate short AI video clips with Volcengine Ark (火山引擎 / 火山方舟) Seedance models - doubao-seedance-2.0, 2.0-fast, 2.0-mini, 2.5, 1.0-pro - by text-to-video or image-to-video (first frame, last frame, reference images). Use this whenever the user wants an AI-generated 片头 / 片尾 / hero opener / B-roll / transition shot for a product demo, launch or marketing video, mentions Seedance, 火山方舟视频生成, "AI 视频片段", "让这张图动起来", or asks how much an AI clip would cost. Reads the key from ~/.config/focus-studio/ark.env, estimates cost before spending, polls the task, downloads the MP4 and caches by request hash so nothing is billed twice.
---

# ark-video-clip - Seedance clips for product demos

`scripts/generate_clip.py` turns a prompt (plus optional images) into an MP4 through the Ark video
generation API. It is the "AI footage" source for the `demo-storyboard` → `product-demo-composer`
pipeline, but works on its own for any short clip.

## Before you spend money

1. **Key**: `python3 ../_shared/ark_client.py check` must say `configured: true`. If not, tell the user to create
   `~/.config/focus-studio/ark.env` with `ARK_API_KEY=...` and `ARK_BASE_URL=https://ark.cn-beijing.volces.com/api/v3`
   (`chmod 600`). Never ask the user to paste the key into the chat, never print or log it, never copy it into the repo.
2. **Activation**: models must be *activated* for the account in the Ark console, not just listed. Run
   `python3 ../_shared/ark_client.py probe-activation` - it is free and reports `activated` / `not-activated`
   per model. A `404 ModelNotOpen` on a real call means the same thing: stop, and ask the user to activate the
   model (火山方舟控制台 → 开通管理).
3. **Estimate first**: every run supports `--dry-run`, which prints the exact request and the estimated cost
   (tokens ≈ width × height × 24 fps × seconds / 1024). Show that number to the user before generating anything
   above ~¥2, and default to the cheapest configuration while iterating on prompts.

## Quick start

```bash
S=skills/ark-video-clip/scripts
# 1. look at the request and cost, no network
python3 $S/generate_clip.py --prompt "abstract dark purple glass UI panels, slow camera push-in, no text" \
  --model doubao-seedance-2-0-mini-260615 --resolution 480p --ratio 16:9 --duration 5 --out ai-clips/hero.mp4 --dry-run
# 2. generate (creates the task, polls, downloads; writes ai-clips/hero.mp4 + hero.mp4.json + ai-clips/.cache/)
python3 $S/generate_clip.py --prompt "..." --model doubao-seedance-2-0-mini-260615 --resolution 480p --duration 5 --out ai-clips/hero.mp4
# 3. verify
python3 skills/product-demo-composer/scripts/probe_media.py --brief ai-clips/hero.mp4
```

Image-to-video: `--first-frame hero-bg.png` (local files are embedded as `data:image/jpeg;base64,...`,
downscaled to 2048 px and ≤ 4 MB with Pillow), optional `--last-frame`, or `--reference img.png` (repeatable,
Seedance 2.x; mutually exclusive with first/last frame). `--ratio adaptive` follows the first frame.

Re-running the same command is free: the cache key is the sha256 of the request JSON (prompt, model, images,
seed, every parameter), stored in `<out dir>/.cache/`. Change the prompt or pass `--seed` to get a new clip;
`--force` re-bills deliberately.

## Choosing a model

| model | use it for | resolutions | approx. cost (¥/s, 16:9)* |
| --- | --- | --- | --- |
| `doubao-seedance-2-0-mini-260615` | prompt iteration, drafts, most B-roll | 480p, 720p | 0.22 @480p, 0.50 @720p |
| `doubao-seedance-2-0-fast-260128` | faster turnaround, good quality | 480p-1080p | ≈ 0.75 @720p, 1.7 @1080p (estimate) |
| `doubao-seedance-2-0-260128` | final hero shots, complex motion, native audio | 480p-1080p | ≈ 1.0 @720p, 2.2 @1080p (estimate) |
| `doubao-seedance-2-5-260628` | newest quality tier; verify pricing in the console | 480p-1080p | ≈ same as 2.0 (estimate) |
| `doubao-seedance-1-0-pro-250528` / `-fast` | legacy, cheaper, no audio | 480p-1080p | 0.32 @720p, 0.73 @1080p (pro) |

*Per-second numbers come from the token formula and the 2026-06 public prices (mini: 0.023 元/千 tokens); rows
marked "estimate" are placeholders until the console bill confirms them. `ark_client.py estimate --model ...`
prints the arithmetic. Every sidecar JSON records the real `usage.completion_tokens`, so calibrate the table in
`_shared/ark_client.py` (`VIDEO_MODELS[...]["yuan_per_ktoken"]`) after the first real bill.

Typical demo budget: 1 hero clip (720p, 5 s, 2.0) + 2 B-roll clips (720p, 5 s, mini) ≈ ¥10.

## The request the script sends

`POST {ARK_BASE_URL}/contents/generations/tasks` with `Authorization: Bearer $ARK_API_KEY`:

```json
{
  "model": "doubao-seedance-2-0-mini-260615",
  "content": [
    {"type": "text", "text": "abstract dark purple glass UI panels, slow camera push-in, no text"},
    {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}, "role": "first_frame"}
  ],
  "resolution": "480p",
  "ratio": "16:9",
  "duration": 5,
  "generate_audio": false,
  "watermark": false,
  "seed": 20260921
}
```

Only flags you set are sent (`camera_fixed`, `return_last_frame`, `--extra '{"k": "v"}'` for anything new).
Response: `{"id": "cgt-..."}`. Poll `GET /contents/generations/tasks/{id}` until `status` is `succeeded`
(`queued` → `running` → `succeeded|failed|cancelled`); the result is `content.video_url` (a temporary signed URL,
downloaded immediately) plus `usage.completion_tokens`. `DELETE .../tasks/{id}` cancels a queued task.

Verification status (2026-09-21): the request above was submitted with this account's key and reached model
routing, which answered `404 ModelNotOpen` for every Seedance model - the account has not activated them yet.
Parameter names follow the current Ark reference (`resolution`, `ratio`, `duration`, `generate_audio`,
`watermark`, `seed`, `camera_fixed`, `return_last_frame`); after activation, run one `--dry-run` and one real
480p/5 s mini call, and if the API returns `400 InvalidParameter` for a field, adjust the flag (or drop it via
`--extra`) and update this section with the accepted shape.

Accepted values (per current docs; the API is authoritative): `resolution` 480p/720p/1080p (mini: 480p/720p),
`ratio` 16:9 · 9:16 · 1:1 · 4:3 · 3:4 · 21:9 · adaptive, `duration` 4-15 s for Seedance 2.x (2-12 s for 1.0),
images ≥ 300 px, aspect 0.4-2.5, JPEG/PNG/WebP.

## Prompting for enterprise demo footage

Read `references/prompting.md` before writing prompts. The rules that matter most:

* **No on-screen text, logos or UI copy** in the prompt - captions and product names are rendered later by the
  composer with the right font, and generated text is unreliable. Say it explicitly: "no text, no letters, no logos".
* Describe **one camera move** (slow push-in, orbit, dolly left) and **one lighting mood**; 5 s is enough for one idea.
* Abstract > literal: glass panels, light, particles and gradients age well; fake dashboards with wrong numbers do not.
* Ask for `--duration 5` and trim in the storyboard; keep `--audio` off (BGM is mixed by the composer).
* Use `--seed` once you like a result so re-renders with small prompt edits stay close.

## Output and hand-off

* `<out>.mp4` - H.264 MP4 (Ark returns MP4; mini 480p is 864×480 @ 24 fps).
* `<out>.mp4.json` - request (data URLs redacted), task id, `usage`, estimated cost, cache key.
* Put the path in a storyboard segment: `{"type": "ai_clip", "asset": "ai-clips/hero.mp4", ...}` and the
  composer scales, pads and captions it. The composer can also generate missing clips itself (`--generate`).

## Troubleshooting

| symptom | cause / fix |
| --- | --- |
| `error: ARK_API_KEY is not configured` (exit 3) | create the env file as above or `export ARK_API_KEY` |
| `HTTP 401` | wrong or revoked key - rotate it in the console; check for stray quotes/whitespace in the env file |
| `HTTP 404 ModelNotOpen` | model not activated for the account - activate in the console; nothing billed |
| `HTTP 404 InvalidEndpointOrModel.NotFound` | typo in the model id, or region mismatch - `ark_client.py models` |
| `HTTP 400 InvalidParameter ...` | read the message: wrong ratio/duration/resolution for that model, or an image too small |
| `CERTIFICATE_VERIFY_FAILED` | python.org Python without CA certs; the client already tries `/etc/ssl/cert.pem`, else `export SSL_CERT_FILE=/etc/ssl/cert.pem` |
| task `failed` (exit 5) | usually content moderation or an unusable first frame; rephrase, avoid faces/brands |
| timeout (exit 6) | keep polling: `python3 ../_shared/ark_client.py task <task_id> --wait`; queue times of several minutes are normal |
| `HTTP 429` | rate/quota limit - the client retries with backoff; wait or lower concurrency |

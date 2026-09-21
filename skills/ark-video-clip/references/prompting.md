# Seedance prompting for enterprise product-demo footage

Read this when writing `--prompt` text for `generate_clip.py` or `ai_clip` storyboard segments.

## Contents
1. Principles
2. Recipes (EN + 中文): hero, product-in-context, transition, data/abstract, ending
3. Camera, lighting and material vocabulary
4. Negative guidance
5. Model selection: quality vs cost vs speed
6. Image-to-video tips

## 1. Principles

* **One clip = one idea, one camera move, one mood.** 4-6 seconds cannot carry a story; the storyboard does.
* **Never ask for text.** Generated letters/numbers/logos are wrong or unreadable and cannot be edited later. The
  composer overlays real text with a real font. Always end with: *no text, no letters, no numbers, no logos, no watermark.*
* **Abstract UI, not fake UI.** Frosted glass panels, soft gradients, floating cards, light beams. Do not ask for a
  "dashboard with revenue numbers" - viewers notice wrong charts.
* **Match the brand**: name the palette (deep violet + indigo, graphite + emerald), the light (cool, soft, rim), the
  finish (matte, glass, brushed metal). Reuse the same three adjectives across all clips for a coherent film.
* **Motion should be slow.** Enterprise footage reads as premium when the camera drifts; fast moves look like stock.
* **Say the frame.** "16:9, centered composition, empty space in the middle for a title" leaves room for overlays.
* **Iterate cheap, finish expensive.** Draft with `doubao-seedance-2-0-mini-260615` at 480p, lock the prompt and seed,
  then re-run the chosen prompt once on `2-0` or `2-5` at 720p/1080p.

## 2. Recipes

### Hero opener (片头主视觉)
EN: *Cinematic abstract hero shot for an enterprise analytics product: layered translucent frosted-glass panels
floating in a deep violet-to-indigo gradient space, thin luminous edges, soft volumetric light from the upper left,
subtle floating particles, slow cinematic camera push-in toward the center, shallow depth of field, photorealistic
3D render, 16:9, empty center for a title. No text, no letters, no numbers, no logos, no people.*

中文：*企业级数据产品的电影感抽象主视觉：多层半透明磨砂玻璃面板悬浮在深紫到靛蓝的渐变空间中，边缘有细微发光，左上方柔和的体积光，
少量漂浮微粒，镜头缓慢向画面中心推进，浅景深，写实 3D 渲染，16:9，中间留白用于放标题。不要出现任何文字、字母、数字、Logo 或人物。*

### Product-in-context B-roll (产品场景 B-roll)
EN: *A modern laptop on a clean desk in a bright office, screen showing a soft blurred glowing interface (no readable
UI), morning light through large windows, slow dolly from left to right, shallow depth of field, calm and premium
mood, 16:9. No text, no logos, no visible brand marks, no faces.*

中文：*明亮办公室的整洁桌面上放着一台现代笔记本电脑，屏幕上是柔和虚化的发光界面（不可辨认的 UI），大窗透进晨光，镜头从左到右缓慢平移，
浅景深，安静高级的氛围，16:9。不要文字、Logo、品牌标识和人脸。*

### Transition / interstitial (章节转场)
EN: *Abstract transition shot: a single sheet of frosted glass sweeps across a dark gradient background from right to
left, refracting soft violet and cyan light, minimal, smooth, 4 seconds, no text.*

中文：*抽象转场镜头：一片磨砂玻璃从右向左扫过深色渐变背景，折射出柔和的紫色和青色光线，极简、顺滑，4 秒，无文字。*

### Data / capability metaphor (能力隐喻)
EN: *Dozens of small translucent cubes assembling into a larger structure on a dark graphite plane, emerald accent
light, slow orbiting camera, clean minimal 3D render. No text, no logos.* (use for "sync", "build", "aggregate")

中文：*几十个小的半透明立方体在深色石墨平面上逐渐组合成一个大结构，翠绿色的点缀光，镜头缓慢环绕，干净极简的 3D 渲染。无文字、无 Logo。*

### Ending / CTA background (片尾)
EN: *Calm dark gradient background with a slow soft light sweep from bottom-left to top-right, faint particles,
very little detail, darker center, 5 seconds, no text.* (the composer draws the CTA text on top)

中文：*安静的深色渐变背景，一道柔光从左下缓慢扫向右上，少量微粒，细节极少，中心更暗，5 秒，无文字。*

## 3. Vocabulary

* Camera: slow push-in / pull-back, dolly left/right, slow orbit, crane up, static with parallax, rack focus.
  Add `--camera-fixed` for a locked-off shot with only the scene moving.
* Light: soft volumetric light, rim light, cool key light from upper left, warm bounce, caustics, bloom.
* Material: frosted glass, translucent acrylic, brushed aluminium, matte graphite, satin ceramic, thin luminous edges.
* Mood words that steer toward "enterprise": premium, calm, precise, minimal, clean, confident.
* Composition: centered, empty center, rule of thirds, foreground bokeh, negative space on the left.

## 4. Negative guidance

Seedance has no separate negative-prompt field; put exclusions at the end of the prompt in plain words:
*no text, no letters, no numbers, no logos, no watermark, no people, no hands, no faces, no flicker, no fast cuts,
no lens flare spam.* Avoid brand names and celebrity likenesses (moderation failures return `status: failed`).

## 5. Model selection

| need | model | resolution / duration | why |
| --- | --- | --- | --- |
| prompt exploration, 3-6 variants | 2-0-mini | 480p, 5 s | ≈ ¥1.1 per try |
| B-roll behind captions | 2-0-mini | 720p, 5 s | ≈ ¥2.5, sharp enough when scaled into 1080p |
| hero opener | 2-0 or 2-5 | 720p-1080p, 5 s | best motion & lighting; ≈ ¥5-11 |
| fast turnaround, many clips | 2-0-fast | 720p | speed over fidelity |
| clip with native sound design | 2-0 / 2-5 with `--audio` | 720p | only if you will not add BGM |
| legacy compatibility | 1-0-pro(-fast) | 1080p | cheaper, no audio, older look |

Costs follow tokens = w × h × 24 × s / 1024 (mini 480p·5 s ≈ 48 600 tokens ≈ ¥1.1; 720p ≈ ¥2.5; 2.0 at 1080p·5 s ≈ ¥11 est.).

## 6. Image-to-video tips

* Generate the still first with `ark-still-image` (same palette, 16:9), then `--first-frame still.png` and describe
  only the motion: "the camera slowly pushes in; light drifts across the glass; particles rise".
* `--ratio adaptive` keeps the still's aspect; otherwise ask for the same ratio you rendered the still in.
* `--return-last-frame` gives you the final frame to chain a second clip seamlessly (`--first-frame` of the next).
* A first frame with baked-in text will animate that text - keep stills text-free too.

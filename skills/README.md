# Focus Studio AI 演示视频 Skills（火山方舟 Seedance / Seedream + ffmpeg）

这是一组 Claude Code skills（`SKILL.md` 格式），把 Focus Studio 的录屏导出与火山引擎 **火山方舟（Ark）** 的
Seedance 视频生成、Seedream 图片生成结合起来，产出企业级科技产品演示视频：**AI 片头 → 录屏功能章节（字幕）→ AI 片尾 CTA**，
成片可直接发布，也可重新导入 Focus Studio 继续加缩放与音效。

> English summary at the end of this file.

## 四个 skill 分别做什么

| skill | 作用 | 入口脚本 |
| --- | --- | --- |
| `ark-video-clip` | 用 Seedance（2.0 / 2.0-fast / 2.0-mini / 2.5 / 1.0-pro）文生视频、图生视频（首帧/尾帧/参考图），含成本预估、轮询、下载、缓存 | `scripts/generate_clip.py` |
| `ark-still-image` | 用 Seedream（5.0-pro / 5.0 / 4.5 / 4.0）生成标题卡、16:9 主视觉背景、功能图标，或把录屏截图重绘成营销主视觉 | `scripts/generate_still.py` |
| `demo-storyboard` | 把产品描述 + Focus Studio `project.json`（点击 / 缩放时间）变成 `storyboard.json` 分镜：章节切点、字幕占位、AI 镜头提示词、转场、BGM | `scripts/storyboard_from_project.py` |
| `product-demo-composer` | 按分镜用 ffmpeg 合成：归一化到 1080p/4K、drawtext 中英文字幕、xfade 转场、BGM 淡入淡出与 ducking，输出 MP4 + `render-report.json`；可按需生成缺失的 AI 素材 | `scripts/compose_demo.py`、`scripts/probe_media.py` |

共享代码在 `_shared/ark_client.py`（仅标准库 `urllib`）：密钥加载、`create_video_task` / `get_task` / `wait_for_task` /
`download` / `generate_image`、成本估算、按请求 JSON 的 sha256 做内容寻址缓存（同一请求永不重复计费）、`--dry-run`、免费的
`probe-activation` 模型开通检测。各 skill 的脚本通过相对路径 `../../_shared` 或 `./_shared` 引入它，因此**单独复制某个 skill
时请连同 `_shared` 目录一起复制**（或设置 `FOCUS_SKILLS_SHARED=/path/to/_shared`）。

## 环境要求

* macOS，Python 3.9+（只用标准库 + 可选 Pillow，用于压缩本地参考图），**不需要** `requests`。
* ffmpeg 7.x（`brew install ffmpeg`），需要 libx264、aac、drawtext、xfade、sidechaincompress、zoompan（Homebrew 版默认包含）。
* 中文字幕字体：自动查找 PingFang（现代 macOS 位于 `/System/Library/AssetsV2/.../PingFang.ttc`）→ Hiragino Sans GB → STHeiti →
  Songti → Arial Unicode → Helvetica；也可用 `--font` 指定。
* 火山方舟 API Key，且**已在控制台开通**要使用的模型（见下文）。

## 安装到 Claude Code

方式一：复制或软链到用户级 skills 目录（对所有项目生效）：

```bash
bash skills/install.sh            # 软链 4 个 skill + _shared 到 ~/.claude/skills/
bash skills/install.sh --copy     # 或复制一份
```

方式二：在本仓库目录里直接运行 `claude`，或在别的目录用 `claude --add-dir /Users/<you>/Desktop/videoRecording` 把仓库加入
工作区后，让 Claude 读取 `skills/<name>/SKILL.md`（例如："按 skills/demo-storyboard/SKILL.md 的流程帮我做分镜"）。

安装后在 Claude Code 里说 "帮我把这段 Focus Studio 录屏做成带 AI 片头的产品演示视频"，四个 skill 会按描述自动触发。

## 端到端流程

```text
Focus Studio 录制 ──导出 MP4──▶ demo-storyboard ──storyboard.json──▶ product-demo-composer ──▶ final.mp4
      │                              │                                    │                        │
  project.json                 ark-still-image / ark-video-clip       --dry-run / --preview      发布，或
（点击、缩放时间）              （可选：片头、B-roll、标题卡）           --generate（付费）        重新导入 Focus Studio
```

1. **录制并导出**：在 Focus Studio 里录制、自动缩放、调背景，导出 MP4（1920 或 3840 宽，30/60 fps）。
2. **分镜**：`storyboard_from_project.py --project <项目目录> --export <导出.mp4> --thumbs thumbs/`，把缩放聚成 3-6 个章节，
   Claude 看缩略图后把 `TODO` 字幕改成"说明收益"的一句话，决定是否加 AI 镜头（写好 `prompt` / `model` / `seed`）。
3. **（可选）生成 AI 素材**：单独用 `generate_still.py` / `generate_clip.py`，或让合成器 `--generate` 一次补齐；先 `--dry-run`
   看请求与预估费用。默认用最便宜的 `doubao-seedance-2-0-mini-260615` 480p/720p 迭代提示词，最后再用 2.0/2.5 出正式片头。
4. **合成**：`compose_demo.py storyboard.json --dry-run` → `--preview` → 正式渲染 → `probe_media.py --brief final.mp4` 并抽帧检查字幕。
5. **（可选）重新导入 Focus Studio**："导入现有 MP4/MOV"，再加缩放、光标、音效与内置 BGM；此时合成时不要加 BGM、关闭 loudnorm。

## 费用参考（人民币，估算）

视频按 token 计费：`tokens ≈ 宽 × 高 × 24 fps × 秒数 / 1024`。

| 模型 | 单价 | 5 秒示例 |
| --- | --- | --- |
| `doubao-seedance-2-0-mini-260615` | 0.023 元/千 tokens（2026-06 公开价；含视频输入 0.014） | 480p ≈ ¥1.1，720p ≈ ¥2.5 |
| `doubao-seedance-2-0-260128` | ≈ 0.046 元/千 tokens（估算，mini 宣称便宜约 50%） | 720p ≈ ¥5，1080p ≈ ¥11 |
| `doubao-seedance-2-0-fast-260128` | ≈ 0.035 元/千 tokens（估算） | 720p ≈ ¥3.8 |
| `doubao-seedance-2-5-260628` | 以控制台为准（脚本按 2.0 估算） | - |
| `doubao-seedance-1-0-pro-250528` | 0.015 元/千 tokens | 1080p ≈ ¥3.6 |
| `doubao-seedream-4-0 / 4-5` | ≈ 0.20 / 0.25 元/张 | 2K 一张 |
| `doubao-seedream-5-0 / 5-0-pro` | ≈ 0.30 / 0.35 元/张（估算） | 2K/4K 一张 |

`ark_client.py estimate --model ... --resolution 720p --duration 5` 可现场算；每个生成物旁的 `*.json` 记录真实 `usage`，
按账单校准 `_shared/ark_client.py` 里的价格表即可。一支典型演示视频（1 个片头 + 2 个 B-roll + 2 张静帧）约 ¥10-15。

**2026-09-21 验证记录**：`GET /models` 正常；用本机密钥提交 Seedream 4.5（2560×1440）和 Seedance 2.0 mini（480p、5 s）请求，
方舟均返回 `404 ModelNotOpen`（账号尚未开通这些模型），`probe-activation` 显示所有 Seedance / Seedream 模型都未开通。
因此本轮**没有产生任何费用或 token 消耗**；请在火山方舟控制台"开通管理"里开通需要的模型后，再跑一次
`generate_still.py --dry-run` 与真实请求，若返回 `400 InvalidParameter`，按提示调整参数并把可用的请求形态回填到各 SKILL.md。

## 密钥与安全规则

* 密钥**只**放在 `~/.config/focus-studio/ark.env`（`chmod 600`）：
  ```
  ARK_API_KEY=你的密钥
  ARK_BASE_URL=https://ark.cn-beijing.volces.com/api/v3
  ```
  脚本先读环境变量 `ARK_API_KEY`，再读该文件；缺失时只打印创建说明。
* 任何脚本、日志、sidecar JSON、`render-report.json` 都不会输出密钥；错误信息会自动打码。不要把密钥粘贴进对话、文档或仓库
  （`.gitignore` 已忽略 `*.env`、`ai-clips/`、`.artifacts/`）。泄露后请立即在控制台轮换。
* 本地参考图 / 截图会以 base64 发送到火山引擎；不要上传含敏感数据的画面。
* 脚本不会关闭 TLS 校验；python.org 版 Python 缺少根证书时会自动尝试 `/etc/ssl/cert.pem`，也可 `export SSL_CERT_FILE=/etc/ssl/cert.pem`。
* 付费操作只在明确的 `--generate` / 真实运行时发生；先 `--dry-run` 看预估，同一请求走缓存不重复计费。

## 目录

```
skills/
├── README.md
├── install.sh
├── _shared/ark_client.py
├── ark-video-clip/        SKILL.md  scripts/generate_clip.py  references/prompting.md
├── ark-still-image/       SKILL.md  scripts/generate_still.py references/prompting.md
├── demo-storyboard/       SKILL.md  scripts/storyboard_from_project.py  references/storyboard-schema.md  examples/*.json
└── product-demo-composer/ SKILL.md  scripts/compose_demo.py  scripts/probe_media.py
```

---

## English summary

Four Claude Code skills that turn a Focus Studio screen recording into an enterprise-grade product demo video with
optional AI footage from Volcengine Ark: **ark-video-clip** (Seedance text/image-to-video with cost estimates, polling,
download and a request-hash cache), **ark-still-image** (Seedream title cards, hero backgrounds, icons, screenshot
restyling), **demo-storyboard** (project.json + product description → `storyboard.json` with chapters cut from the
zoom timeline, captions, prompts, transitions, BGM), and **product-demo-composer** (ffmpeg: normalise to 1080p/4K,
CJK captions via drawtext, xfade transitions, BGM ducking, render report; `--generate` fills missing AI assets,
otherwise placeholders). Install with `bash skills/install.sh` (symlinks into `~/.claude/skills/`) or run `claude`
in this repo / `claude --add-dir <repo>`. The API key lives only in `~/.config/focus-studio/ark.env`; scripts never
print it. Pricing: Seedance mini ≈ ¥0.023 per 1k tokens (480p·5 s ≈ ¥1.1), Seedream ≈ ¥0.2-0.3 per image. On
2026-09-21 the API answered `404 ModelNotOpen` for every Seedance/Seedream model on this account - activate them in
the Ark console before the first paid run; the composer was verified end-to-end with synthetic media at zero cost.

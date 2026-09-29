# Focus Studio 录制与 Demo 剪辑 Skills

这些 Skills 可安装到 **Codex 或 Claude Code**。普通产品演示直接通过 Focus Studio 的 MCP 工具完成：
录制 → 保存原始项目 → 分析操作间的等待 → 创建剪辑副本 → 调整逐段缩放 → 预览 → 导出。
原始视频和手动录制算法保持不变；剪辑只影响单独的新项目。

一句话示例：**“录制这个产品的核心流程，剪掉操作间的空等，延长重点展示，导出 1080p。”**
使用 `focus-demo-editing` 串联流程，`focus-studio-mcp` 提供录制及编辑工具约定。它们不需要 Ark 密钥或付费素材。
需要片头、片尾、复杂转场或营销视频组装时，再使用分镜与合成 Skills；AI 素材生成是可选的付费步骤。

## 安装到 Codex / Claude Code

```bash
bash skills/install.sh --codex --skill focus-studio-mcp --skill focus-demo-editing
bash skills/install.sh --codex   # 所有 Skills（默认目标是 Codex）
bash skills/install.sh --claude  # 安装到 Claude Code
bash skills/install.sh --all --copy  # 两个客户端都安装，使用副本
```

默认软链到 `${CODEX_HOME:-$HOME/.codex}/skills` 或 `${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}`。
已有同名内容会保留到技能目录外的 `skill-backups`，不会删除。软链会跟随仓库更新；副本需再次运行安装器。
安装后重新打开客户端会话以刷新技能发现。Focus Studio 中仍需启用 **设置 › AI 工具** 的 `focus-studio` MCP 连接。

## Skills 分工

| skill | 作用 |
| --- | --- |
| `focus-demo-editing` | 将录制、空等分析、非破坏剪辑、单段缩放、预览和导出连成一个任务；保存策略与验证报告 |
| `focus-studio-mcp` | 通过真实工具控制 Focus Studio 录制、项目、缩放、字幕、音频与导出 |
| `demo-storyboard` | 为需要片头、章节和片尾的成片创建分镜 |
| `product-demo-composer` | 按分镜用 ffmpeg 合成已导出的片段、字幕、转场和音轨 |
| `ark-still-image` / `ark-video-clip` | 按需生成可选的付费图片或视频素材 |

`focus-demo-editing` 使用的是新的原生剪辑工具；如果已安装的 Focus Studio 还没有这些工具，请先更新应用。
`get_project` 和实际工具 schema 是当前版本的依据；不能用启用自动缩放代替补回缺失的鼠标轨迹。

## 可选：分镜与营销视频合成

### 分镜与合成 Skills

| skill | 作用 | 入口脚本 |
| --- | --- | --- |
| `ark-video-clip` | 用 Seedance（2.5 / 2.0 / 2.0-mini / 1.0-pro）文生视频、图生视频（首帧/尾帧/参考图），Seedance 2.5 还支持参考视频（`--reference-video`）与参考音频（`--reference-audio`）的多模态参考；含成本预估、轮询、下载、缓存 | `scripts/generate_clip.py` |
| `ark-still-image` | 用 Seedream（5.0-pro / 5.0 / 4.5 / 4.0）生成标题卡、16:9 主视觉背景、功能图标，或把录屏截图重绘成营销主视觉 | `scripts/generate_still.py` |
| `demo-storyboard` | 把产品描述 + Focus Studio `project.json`（点击 / 缩放时间）变成 `storyboard.json` 分镜：章节切点、字幕占位、AI 镜头提示词、转场、BGM | `scripts/storyboard_from_project.py` |
| `product-demo-composer` | 按分镜用 ffmpeg 合成：归一化到 1080p/4K、drawtext 中英文字幕、xfade 转场、BGM 淡入淡出与 ducking，输出 MP4 + `render-report.json`；可按需生成缺失的 AI 素材 | `scripts/compose_demo.py`、`scripts/probe_media.py` |

共享代码在 `_shared/ark_client.py`（仅标准库 `urllib`）：密钥加载、`create_video_task` / `get_task` / `wait_for_task` /
`download` / `generate_image`、成本估算、按请求 JSON 的 sha256 做内容寻址缓存（同一请求永不重复计费）、`--dry-run`、免费的
`probe-activation` 模型开通检测。各 skill 的脚本通过相对路径 `../../_shared` 或 `./_shared` 引入它，因此**单独复制某个 skill
时请连同 `_shared` 目录一起复制**（或设置 `FOCUS_SKILLS_SHARED=/path/to/_shared`）。

### 可选合成环境要求

* macOS，Python 3.9+（只用标准库 + 可选 Pillow，用于压缩本地参考图），**不需要** `requests`。
* ffmpeg 7.x（`brew install ffmpeg`），需要 libx264、aac、drawtext、xfade、sidechaincompress、zoompan（Homebrew 版默认包含）。
* 中文字幕字体：自动查找 PingFang（现代 macOS 位于 `/System/Library/AssetsV2/.../PingFang.ttc`）→ Hiragino Sans GB → STHeiti →
  Songti → Arial Unicode → Helvetica；也可用 `--font` 指定。
* 火山方舟 API Key，且**已在控制台开通**要使用的模型（见下文）。

## 分镜合成流程（可选）

```text
Focus Studio 录制 ──导出 MP4──▶ demo-storyboard ──storyboard.json──▶ product-demo-composer ──▶ final.mp4
      │                              │                                    │                        │
  project.json                 ark-still-image / ark-video-clip       --dry-run / --preview      发布，或
（点击、缩放时间）              （可选：片头、B-roll、标题卡）           --generate（付费）        重新导入 Focus Studio
```

1. **录制并导出**：在 Focus Studio 里录制、自动缩放、调背景，导出 MP4（1920 或 3840 宽，30/60 fps）。
2. **分镜**：`storyboard_from_project.py --project <项目目录> --export <导出.mp4> --thumbs thumbs/`，把缩放聚成 3-6 个章节，
   助手看缩略图后把 `TODO` 字幕改成"说明收益"的一句话，决定是否加 AI 镜头（写好 `prompt` / `model` / `seed`）。
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

**密钥类型（重要）**：火山引擎有两种 Key。IAM 的 API Key（`console.volcengine.com/iam/keymanage`，形如 `Vx…`）能通过
`GET /models` 列出模型，但对本账号所有 Seedance / Seedream 请求都返回 `404 ModelNotOpen`；**火山方舟控制台"API Key 管理"里创建的
项目 Key（`ark-` 开头）才绑定已开通的模型**。请把 `ark-` Key 写入 `~/.config/focus-studio/ark.env`。

**2026-09-22 验证记录**（`ark-` Key）：`probe-activation` 显示已开通 Seedance 2.5 / 2.0 / 2.0-mini / 1.0-pro / 1.0-pro-fast 与
Seedream 5.0 / 4.5 / 4.0（未开通：Seedance 2.0-fast、Seedream 5.0-pro）。真实调用：Seedream 4.5 生成 2560×1440 主视觉成功
（`output_tokens` 14400，≈ ¥0.25）；Seedance 2.5 用官方多模态参考示例（2 张 `reference_image` + `reference_video` + `reference_audio`、
`generate_audio: true`、11 秒）提交成功并在约 3 分钟内完成：1280×720、24 fps、11.07 s、含模型生成的音频，`completion_tokens` 411300（约 ¥19；带参考视频与音频的实际用量约为事前估算的 1.7 倍）。

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
├── product-demo-composer/ SKILL.md  scripts/compose_demo.py  scripts/probe_media.py
├── focus-studio-mcp/      SKILL.md（录制与编辑工具约定）
└── focus-demo-editing/    SKILL.md  agents/openai.yaml  references/editing-tools.md
```

---

## English summary

Install into Codex (default), Claude Code (`--claude`), or both (`--all`) using `skills/install.sh`.
`focus-demo-editing` runs the native record–analyze–cut–zoom–preview–export workflow through Focus Studio;
`focus-studio-mcp` documents its recording and editing tools. The original take is retained and the edit is
a separate project. Existing installed skills are backed up rather than deleted.

The optional `demo-storyboard` and `product-demo-composer` skills assemble exported chapters with captions,
title cards, transitions and audio. `ark-still-image` and `ark-video-clip` generate paid assets only when
requested; these optional tools need an Ark key. Native demo editing does not.

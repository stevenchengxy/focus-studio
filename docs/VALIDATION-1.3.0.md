# Focus Studio 1.3.0（build 7）验证记录

本次范围：AI 模型网关（多提供商 + OpenRouter + 火山方舟）、章节字幕与 AI 生成/润色、对话式 AI 助手（意图理解 → 工具执行：Seedream 生图、Seedance 生视频、截帧、外观设置、章节、导出与拼接）、界面文字密度降低，以及 Seedance 2.5 多模态参考格式的 skills 更新。验证机器：Apple Silicon、macOS 26.2、Swift 6.2.4。

## 自动化

| 检查 | 结果 |
| --- | --- |
| `bash scripts/test-ai-gateway.sh`（提供商表、推荐模型、JSON 提取、两种传输的请求体、钥匙串隐私、URLProtocol 模拟的列表/补全/重试/超时） | PASS |
| `swift run FocusStudioPermissionTests`（含 `ChapterTests`：裁剪/排序、编辑、活动章节、淡入淡出端点、按缩放聚类、SRT、带围栏/散文的 JSON 解析、越界拒绝、旧 JSON 解码） | PASS |
| `swift run FocusStudioE2E`（合成项目带一个章节：字幕帧与无字幕基线均值差 0.41、变化像素集中在字幕行；章节外帧差 0；预览与导出 MP4 差 0.72；顶部中文字幕无编号；禁用章节不渲染） | PASS |
| `swift scripts/test-localization.swift` | PASS（630 个键，中英一致） |
| `zsh scripts/test-app-regression.sh --skip-build` | PASS |
| `zsh scripts/test-ai-assistant.sh`（协议解析、脚本化代理循环、确认门、停止、`update_settings`/`set_chapters` 校验、`assemble_video` 双片段拼接、Ark 请求体、`fake-ark.py` 夹具往返含全部工具） | PASS |
| `zsh scripts/test.sh`（以上全部串行，含 E2E 与 Codex 真实连接） | PASS，退出码 0 |

## 实机检查（候选应用 `dist/candidates/1.3.0/Focus Studio.app`）

- `FOCUS_STUDIO_START_DESTINATION=editor` 启动：工具栏出现"字幕"工具，时间线出现"章节"泳道（`.artifacts/qa/1.3.0/editor-captions-lane.png`）。
- 录制页、项目库、Codex 面板与检查器的说明段落已改为工具提示，界面只保留控件与状态。
- `FOCUS_STUDIO_OPEN_SETTINGS=1` 启动：设置窗口打开在“AI 模型”页，左侧 8 个提供商带状态点，右侧只有密钥、模型、状态/测试与“高级”折叠（`.artifacts/qa/1.3.0/settings-ai-models.png`）。
- 火山方舟文本模型实测：`GET /models` 列出 doubao-seed-2.0/2.1 系列，`POST /chat/completions`（`doubao-seed-2-1-turbo-260628`）返回带 `reasoning_content` 的 JSON 回答，网关客户端会跳过思考块只取正文。

## AI 助手实机运行（真实调用）

`FOCUS_STUDIO_IMPORT_ARK_ENV=1 FOCUS_STUDIO_START_DESTINATION=editor FOCUS_STUDIO_ASSISTANT_PROMPT="为这段录屏生成一张深紫色科技感的 16:9 背景图，不要文字，并把它设为背景"` 启动候选应用：

1. 网关导入火山方舟密钥并测试通过，默认文本模型自动选为 `doubao-seed-2-0-pro-260215`。
2. 助手理解意图后调用 `generate_image`（Seedream 4.5，2560 × 1440，预估 ¥0.25），图片保存到项目目录 `ai/image-20260922-014049.png`，工具卡片显示缩略图与"在访达中显示"。
3. 接着调用 `set_background_image`，预览立即显示新的紫色科技背景。
4. 最终回复中文说明与费用，并给出两条后续建议（调整圆角/阴影、添加章节字幕）。

截图：`.artifacts/qa/1.3.0/assistant-generate-background.png`。视频生成路径（`generate_video`）在离线夹具中验证了确认卡片 → 提交 → 轮询 → 下载全流程；真实 Seedance 2.5 调用已在 skills 一节用同一请求形态验证。

## 安装包

`FOCUS_STUDIO_APP_DIR="$PWD/dist/candidates/1.3.0/Focus Studio.app" zsh scripts/build-app.sh` 与 `scripts/package-release.sh --skip-build` 通过：arm64 + x86_64 Universal 2、macOS 15.0 最低系统版本、仅系统框架、图标与 685 键双语资源、12 个音频素材验证通过，DMG 完整性校验 VALID。ad-hoc 本地签名，未经 Apple 公证；Intel 切片仅经交叉编译。用户正在运行的 `dist/Focus Studio.app`（1.1.2）未被替换或重启。

- `dist/candidates/1.3.0/Focus Studio.app`
- `dist/releases/Focus-Studio-1.3.0-universal-local.dmg`（SHA-256 `24da526eee099005ffd23e8db685ed0d0fda7b09002ed57ab50f4a5245a97c31`）
- `dist/releases/Focus-Studio-1.3.0-universal-local.zip`（SHA-256 `331ca93e12aa13beaa21e539810041444f09ec2f559e8dfde7c0e8dbfc355f36`）
- `dist/releases/Focus-Studio-1.3.0-universal-local.sha256`

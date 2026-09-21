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
| AI 助手测试脚本、完整 `scripts/test.sh` | 见下文（助手集成后补充） |

## 实机检查（候选应用 `dist/candidates/1.3.0/Focus Studio.app`）

- `FOCUS_STUDIO_START_DESTINATION=editor` 启动：工具栏出现"字幕"工具，时间线出现"章节"泳道（`.artifacts/qa/1.3.0/editor-captions-lane.png`）。
- 录制页、项目库、Codex 面板与检查器的说明段落已改为工具提示，界面只保留控件与状态。
- `FOCUS_STUDIO_OPEN_SETTINGS=1` 启动：设置窗口打开在“AI 模型”页，左侧 8 个提供商带状态点，右侧只有密钥、模型、状态/测试与“高级”折叠（`.artifacts/qa/1.3.0/settings-ai-models.png`）。
- 火山方舟文本模型实测：`GET /models` 列出 doubao-seed-2.0/2.1 系列，`POST /chat/completions`（`doubao-seed-2-1-turbo-260628`）返回带 `reasoning_content` 的 JSON 回答，网关客户端会跳过思考块只取正文。

## 待补充

设置窗口 AI 模型页截图、AI 助手面板截图、助手测试与完整测试套件结果、Universal 2 安装包。

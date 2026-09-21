# Focus Studio 1.4.0（build 8）验证记录

本次范围：AI 助手升级为可操控应用的全局代理（独立窗口、录制/编辑/导出工具、`wait` 节奏工具）、Codex 作为可选大脑、火山方舟密钥自动导入、密钥存储改为本地 0600 文件、语音输入与可选语音回复、程序化 3D 数字人与面板动效。验证机器：Apple Silicon、macOS 26.2、Swift 6.2.4。

## 自动化

| 检查 | 结果 |
| --- | --- |
| `zsh scripts/test-ai-assistant.sh`（协议、代理循环、确认门、模型解析、`update_settings` / `set_chapters`、应用控制：列源/开始/停止/项目库、缩放工具、音频工具、导出路径、拼接、Ark 请求体与夹具往返） | PASS |
| `bash scripts/test-codex-connection.sh`（新增 `assistant-turn` 夹具：`completeText` 批量完成、线程复用、新指令、取消、失败回合、未登录） | PASS |
| `bash scripts/test-ai-gateway.sh`（含新增 `FileSecretStore` 往返与 0600 权限） | PASS |
| `swift scripts/test-localization.swift` | PASS（708 个键，中英一致） |
| `zsh scripts/test.sh`（单元、E2E 渲染、本地化、语言偏好、应用回归、Codex fixture + 真实连接、网关、助手，全部串行） | PASS，退出码 0 |

## 关键问题与修复：钥匙串导致界面卡死

首个 1.4.0 候选在实机上出现"助手窗口内容半透明、请求永不完成"。`/usr/bin/sample` 显示主线程阻塞在 `SecItemCopyMatching` → SecurityServer 解密：macOS 正在等待"Focus Studio 想访问钥匙串"对话框，因为每次重新构建的 ad-hoc 签名应用对钥匙串都是新的身份。这也是用户反馈"助手不能用"的原因。修复：`AIGatewayStore` 默认改用 `FileSecretStore`（`~/Library/Application Support/FocusStudio/secrets.json`，目录 0700、文件 0600、原子写入），不再触发任何授权对话框；`SecurityKeychainStore` 保留但不作为默认。

## 实机检查（候选应用 `dist/candidates/1.4.0/Focus Studio.app`）

- 启动即用：无需任何钩子，网关从 `~/.config/focus-studio/ark.env` 自动导入火山方舟密钥并测试，默认文本模型自动选为 `doubao-seed-2-0-pro-260215`，助手窗口标题栏显示该模型。
- `FOCUS_STUDIO_ASSISTANT_PROMPT="列出现在可以录制的窗口和显示器，然后告诉我哪个最适合录产品演示"`：助手调用 `list_recording_sources`（工具卡片列出 1 台显示器与 13 个窗口的 id、应用、标题、尺寸），随后用中文回答并给出三条后续建议芯片（`.artifacts/qa/1.4.0/assistant-list-sources.png`）。
- 完整流程（`FOCUS_STUDIO_ASSISTANT_PROMPT="录制 Focus Studio 的主窗口 6 秒后停止，然后在第 2 秒处添加一个 1.6 倍的缩放（焦点 0.5, 0.5），再导出为 mp4。每一步完成后简短汇报。"`）：助手依次调用 `list_recording_sources` → `start_recording`（3 秒倒计时后进入录制）→ `wait`（6 s）→ `stop_recording`（生成项目 "Recording 2026年9月22日 上午 3:11"，17.5 s，2880 × 1800；时长包含模型每步思考的间隔）→ `add_zoom`（2.0–3.5 s，焦点 0.5/0.5，×1.60，手动）→ `export_project`（`ai/export-20260922-031207.mp4`，17.5 s，1920 × 1080，工具卡片显示缩略图），最后给出后续建议芯片。截图：`.artifacts/qa/1.4.0/assistant-record-edit-export.png`。
- 数字人：程序化 SceneKit 角色（圆润紫青渐变身体、大而有神的眼睛、腮红、发光天线与光环）在窗口顶部持续呼吸、眨眼与转动视线；风格化设计无恐怖谷。
- 语音：面板具备麦克风按钮（本地语音识别、电平表、静音自动停止）与"语音回复"开关；因无法在无人值守下提供麦克风输入，仅验证权限描述、编译与降级路径（识别器不可用时显示提示而不崩溃）。

## 安装包

`FOCUS_STUDIO_APP_DIR="$PWD/dist/candidates/1.4.0/Focus Studio.app" zsh scripts/build-app.sh` 与 `scripts/package-release.sh --skip-build` 通过：arm64 + x86_64 Universal 2、macOS 15.0 最低系统版本、仅系统框架、图标与 708 键双语资源、12 个音频素材验证通过，DMG 完整性校验 VALID。ad-hoc 本地签名，未经 Apple 公证；Intel 切片仅经交叉编译。用户正在运行的 1.3.0 候选应用未被替换或重启。

- `dist/candidates/1.4.0/Focus Studio.app`
- `dist/releases/Focus-Studio-1.4.0-universal-local.dmg`（SHA-256 `076485a179bd06693fc50b9ef034c23c533ff8714e89c84e068dac96fbed637d`）
- `dist/releases/Focus-Studio-1.4.0-universal-local.zip`（SHA-256 `42d04866f8a0c2e15c60c79edc1195d9dde7523e52ac586f56cd019342ef48e1`）
- `dist/releases/Focus-Studio-1.4.0-universal-local.sha256`

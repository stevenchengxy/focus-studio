# Focus Studio 1.2.0（build 6）验证记录

本次范围：Codex 连接的版本择优与可见诊断、录制源实时预览、Cinematic 镜头曲线与相邻点击链接、界面动效与项目库海报、两首新增 CC0 曲目，以及 `skills/` 目录下的火山引擎 Seedance / Seedream Skills。验证机器为 Apple Silicon、macOS 26.2，Swift 6.2.4。

## 自动化

| 检查 | 结果 |
| --- | --- |
| `swift run FocusStudioPermissionTests`（含新增 `ZoomMotionTests`：曲线端点速度/加速度为零、pan 无速度突变、重叠交接不弱于最强单段、链接规则、1.1.x 设置解码） | PASS |
| `swift run FocusStudioE2E`（合成网格视频 → 正式渲染管线；zoomFrameDifference 23.76，returnFrameDifference 0.85；8 首 BGM / 4 种 SFX catalog 完整性） | PASS |
| `swift scripts/test-localization.swift` | PASS（546 个键，中英一致，占位符一致） |
| `zsh scripts/test-app-regression.sh --skip-build` | PASS（50 次打开/编辑/返回、逐段缩放编辑、项目库多选/重命名/废纸篓） |
| `bash scripts/test-codex-connection.sh`（fixture：版本排序、多候选择优、失败/挂起候选、符号链接去重、凭据泄漏 tripwire、stderr 脱敏、config-error 退出诊断） | PASS |
| `bash scripts/test-codex-connection.sh --live-read-only`（真实 Codex，不设置 `CODEX_EXECUTABLE`，自动择优命中 ChatGPT.app 内置 0.155.0-alpha.9.2） | PASS（5 个模型，不修改登录状态，不发起模型请求） |
| `zsh scripts/test.sh`（以上全部串行） | PASS，退出码 0 |

## Codex 登录与配置

根因：本机 `/opt/homebrew/bin/codex` 为 0.42.0，而 `~/.codex/config.toml` 由 ChatGPT.app 内置的 0.155.0-alpha.9.2 写入（`model_reasoning_effort = "ultra"`）。旧版 app-server 解析配置失败即退出，应用只显示 "app-server exited with status 1"。1.2.0 起 `CodexExecutableDiscovery` 对所有候选执行 `--version`（3 秒超时、探测环境剥离凭据）并选择最高版本；显式路径仍然优先。app-server 在握手前退出时，最近三行脱敏后的 stderr 会与提示一起显示，例如：

```
Codex app-server exited with status 1: Error loading configuration: unknown variant `ultra`, expected one of `minimal`, `low`, `medium`, `high` in `model_reasoning_effort`
Update Codex CLI or fix ~/.codex/config.toml.
```

Connection 面板新增 **Detected installations** 列表（路径、版本、Recommended / Last used 标记、Use 按钮、Detect again）。

## 实机检查（候选应用 `dist/candidates/1.2.0/Focus Studio.app`）

- 以 `open -n … --env FOCUS_STUDIO_START_DESTINATION=recorder` 启动，录制页所有窗口卡片在 1 秒内显示真实内容，选中卡片实时刷新；截图见 `.artifacts/qa/1.2.0/picker-live-previews.png`（3054 × 1974）。
- 项目库 24 个项目全部显示经正式渲染管线生成的带背景海报；截图见 `.artifacts/qa/1.2.0/library-posters.png`。
- 用户正在运行的 `dist/Focus Studio.app`（1.1.2）全程未被替换、退出或重启；候选应用运行于独立路径。

## 缩放动效

- `TimelineMath.zoomState` 的包络并集与缓动 pan 由 `Tests/FocusStudioPermissionTests/ZoomMotionTests.swift` 以 2.5 ms 采样验证：pan 的二阶差分小于一阶差分的 35%，链接交接期间 scale 始终保持目标值。
- 渲染器新增按 pan 位移的方向性运动模糊，E2E 输出尺寸、时长、缩放帧差异与回退帧差异不变。

## 构建与安装包

`FOCUS_STUDIO_APP_DIR="$PWD/dist/candidates/1.2.0/Focus Studio.app" zsh scripts/build-app.sh` 与 `scripts/package-release.sh --skip-build` 均通过：arm64 + x86_64 Universal 2、macOS 15.0 最低系统版本、仅系统框架、图标与 557 键双语资源、12 个音频素材（8 首 BGM + 4 种 SFX）验证通过，DMG 完整性校验 VALID。当前机器没有签名身份，采用 ad-hoc 本地签名，未经 Apple 公证；Intel 切片仅经交叉编译与结构验证。

交付文件：

- `dist/candidates/1.2.0/Focus Studio.app`
- `dist/releases/Focus-Studio-1.2.0-universal-local.dmg`（SHA-256 `dfd9a57f3ced57c1204cbbf445bc893e5950aa28a9b23e52a5896e34af8fe4ed`）
- `dist/releases/Focus-Studio-1.2.0-universal-local.zip`（SHA-256 `d8326565b54f3504b94f7d643ad9bea9403cdec0be4b29e66576c9854bdc2f18`）
- `dist/releases/Focus-Studio-1.2.0-universal-local.sha256`

## 待补充

Skills 的真实 API 调用记录见下一节（Skills 工作流完成后填写）。

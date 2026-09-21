# Focus Studio 1.2.0（build 6）验证记录

本次范围：Codex 连接的版本择优与可见诊断、录制源实时预览、Cinematic 镜头曲线与相邻点击链接、界面动效与项目库海报、两首新增 CC0 曲目，以及 `skills/` 目录下的火山引擎 Seedance / Seedream Skills。验证机器为 Apple Silicon、macOS 26.2，Swift 6.2.4。

## 自动化

| 检查 | 结果 |
| --- | --- |
| `swift run FocusStudioPermissionTests`（含新增 `ZoomMotionTests`：曲线端点速度/加速度为零、pan 无速度突变、重叠交接不弱于最强单段、链接规则、1.1.x 设置解码） | PASS |
| `swift run FocusStudioE2E`（合成网格视频 → 正式渲染管线；zoomFrameDifference 23.76，returnFrameDifference 0.85；8 首 BGM / 4 种 SFX catalog 完整性） | PASS |
| `swift scripts/test-localization.swift` | PASS（546 个键，中英一致，占位符一致） |
| `zsh scripts/test-app-regression.sh --skip-build` | PASS（50 次打开/编辑/返回、逐段缩放编辑、项目库多选/重命名/废纸篓） |
| `bash scripts/test-codex-connection.sh`（fixture） | 见下文 Codex 小节 |
| `bash scripts/test-codex-connection.sh --live-read-only`（真实 Codex，自动择优） | 见下文 Codex 小节 |

## 缩放动效

- `TimelineMath.zoomState` 的包络并集与缓动 pan 由 `Tests/FocusStudioPermissionTests/ZoomMotionTests.swift` 以 2.5 ms 采样验证：pan 的二阶差分小于一阶差分的 35%，链接交接期间 scale 始终保持目标值。
- 渲染器新增按 pan 位移的方向性运动模糊，E2E 输出尺寸、时长、缩放帧差异与回退帧差异不变。

## 待补充

以下小节在对应工作流完成后填写：Codex 连接、实时预览实机截图、候选应用构建与安装包、Skills 的真实 API 调用记录。

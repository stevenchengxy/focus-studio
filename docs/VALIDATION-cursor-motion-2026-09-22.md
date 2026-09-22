# 光标与镜头动画优化验证（2026-09-22，1.8.0 / build 15）

范围：自定义光标路径平滑与点击落位、箭头 ↔ I-beam 交叉淡入、放大期间镜头跟随光标。所有计算在 `FocusStudioCore` 中完成，预览与导出共用同一路径。

## 实现

| 项目 | 做法 |
| --- | --- |
| 光标路径 | `CursorMotion.smoothedPath`：把原始鼠标采样按 120 Hz 重采样（单调 Hermite），对 x/y 做零相位高斯平滑（Smooth σ=85 ms、Medium 45 ms、Rapid 22 ms、None 不处理），再以 smootherStep 权重把每次点击 ±max(120 ms, 3σ) 邻域回拉到精确点击坐标，箭头在点击时刻与点击涟漪重合 |
| 形状切换 | `CursorMotion.kindTransition`：箭头与 I-beam 之间 140 ms 交叉淡入，入场形状从 0.9 缩放到 1，两层同一热点对齐；也掩盖了输入框焦点抖动造成的一帧闪烁 |
| 焦点转移 | `TimelineMath.zoomState`：交接时新区域的 pan 时长 = Zoom in + min(0.25 s, 距离 × 0.6 s)，仅作用于焦点插值，scale 仍走原包络；打字来源的镜头不延长（及时回到输入框）；E2E 的交接落定断言相应改为 easeIn + 0.25 s |
| 镜头跟随 | `CursorFollow.offsets`：放大期间若光标离开视口中央 62% 安全区，按 60 Hz 计算所需偏移，σ=220 ms 零相位平滑，乘以缩放包络（回到全景时归零）与强度（Animation → Follow cursor，默认 60%）；光标隐藏时不跟随，保证与无光标元数据的渲染完全一致 |

## 过渡时刻手动调节（1.8）

- `ZoomTimingEdit.fullZoomAt` / `.zoomOutAt`：以绝对时间设置放大完成时刻与缩小开始时刻，块的起止不变，另一段过渡长度保持，越界时夹紧到彼此不交叉；编辑后标记为手动。
- 检查器 Timing 新增两个字段；时间线缩放块显示过渡阴影区并提供内侧把手拖动（含无障碍调节）。
- `ZoomBoundaryTests`：边界解析、两种编辑的起止保持与手动标记、越界夹紧、非有限值忽略。

## 自动化

- `swift run FocusStudioPermissionTests`：新增 `CursorMotionTests`（平滑后二阶差分能量小于原始一半、端点保持、点击时刻位置误差 < 0.002 且渐入不跳变、σ=0 原样返回；形状切换索引与 0.5 进度；跟随在安全区内不漂移、越界后漂移 > 0.15、回到全景后 < 0.02、漂移无速度突变、强度 0 关闭）— PASS
- `CursorMotionTests` 追加：远距离交接在 Zoom in 结束时仍在 pan（< 90%）、在 easeIn + 0.25 s 落定、近距离几乎与 scale 同步、pan 单调。
- `swift run FocusStudioE2E`：首轮因"隐藏光标必须与无光标元数据渲染一致"失败，修复为隐藏光标时不跟随后 PASS（`zoomFrameDifference` 32.2，`returnFrameDifference` 0.85，`cursorChangedPixels` 68）
- `zsh scripts/test.sh`（含你新增的 RecordingLifecycleRegression、InstallationTests、CodexPlanRunnerTests）：全部 PASS，退出码 0

## 实机抽帧（真实录制 F785D0E7…，7.09 s，点击 0.43/1.23/2.79/3.96 s，I-beam 首次出现 0.89 s）

通过 AI 助手的 `capture_frame` 用正式渲染管线截取 0.82 / 0.96 / 1.10 / 2.65 / 2.79 / 3.10 / 3.60 s：

- 0.96 s：箭头与 I-beam 同时可见、处于交叉淡入中；1.10 s 数据又切回箭头，同样以淡入过渡而非一帧跳变（`.artifacts/qa/cursor-motion/ibeam-crossfade.png`）。
- 2.79 s 点击时刻箭头位于自动填充项上；3.10 s 点击涟漪中心与箭头重合，说明平滑路径在点击点精确落位（`.artifacts/qa/cursor-motion/click-frames.png`）。

## 交付

- 候选应用：`dist/candidates/1.5.0/Focus Studio.app`（目录名沿用本次构建，内容为工作树 1.7.1 + 本次优化，原生架构）。
- 本次没有提交或推送：工作树中还有你自己的未提交改动（暂停/续录、缩放意图排序、助手面板等），我没有替你提交。

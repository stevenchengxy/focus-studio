# 光标与镜头动画优化验证（2026-09-22，1.8.0 / build 15 → 1.9.0 / build 16）

范围：自定义光标路径平滑与点击落位、箭头 ↔ I-beam 交叉淡入、放大期间镜头跟随光标。所有计算在 `FocusStudioCore` 中完成，预览与导出共用同一路径。

## 实现

| 项目 | 做法 |
| --- | --- |
| 光标路径 | `CursorMotion.smoothedPath`：把原始鼠标采样按 120 Hz 重采样（单调 Hermite），对 x/y 做零相位高斯平滑（Smooth σ=85 ms、Medium 45 ms、Rapid 22 ms、None 不处理），再以 smootherStep 权重把每次点击 ±max(120 ms, 3σ) 邻域回拉到精确点击坐标，箭头在点击时刻与点击涟漪重合 |
| 形状切换 | `CursorMotion.kindTransition`：箭头与 I-beam 之间 140 ms 交叉淡入，入场形状从 0.9 缩放到 1，两层同一热点对齐；也掩盖了输入框焦点抖动造成的一帧闪烁 |
| 焦点转移 | `TimelineMath.zoomState`：交接时新区域的 pan 时长 = Zoom in + min(0.25 s, 距离 × 0.6 s)，仅作用于焦点插值，scale 仍走原包络；打字来源的镜头不延长（及时回到输入框）；E2E 的交接落定断言相应改为 easeIn + 0.25 s |
| 镜头跟随 | `CursorFollow.offsets`：放大期间若光标离开视口中央 62% 安全区，按 60 Hz 计算所需偏移，σ=220 ms 零相位平滑，乘以缩放包络（回到全景时归零）与强度（Animation → Follow cursor，默认 60%）；光标隐藏时不跟随，保证与无光标元数据的渲染完全一致 |

## 小手光标、弹簧追踪与时间线操作（1.9）

- `CursorKind.pointingHand`；`SystemCursorMatcher` 以 24×24 灰度+覆盖指纹比对 `NSCursor.currentSystem` 与系统箭头/I-beam/小手（阈值 0.06），录制时优先使用，辅助功能 `AXLink` / `AXURL` 后备；渲染器提供系统小手、高对比度小手与圆点三种外观。
- `CursorFollow` 改为临界阻尼弹簧（响应 0.5 s，60 Hz 半隐式欧拉）：软区（视口半宽 62%）内按 smootherStep 渐进拉动，硬区（90%）外强制保持光标在画面内；乘以缩放包络与强度。
- 时间线：Zoom 泳道 **+** 按钮、Delete 键删除选中块（时间线获得焦点后）、右键菜单添加/复制/移除。
- 测试：链接语义、`pointingHand` JSON 往返、系统光标指纹自匹配与两两距离 > 2×阈值（需初始化 NSApplication）、十字光标不匹配；弹簧跟随用例沿用（区内不动、越界跟随、回全景归零、无速度突变）。

### 验证（1.9）

- `swift run FocusStudioPermissionTests`：`CursorMotionTests` 小手部分（链接语义、`pointingHand` JSON 往返、系统光标指纹自匹配、箭头/I-beam/小手两两距离 > 2×阈值、十字光标不匹配）与弹簧跟随用例、`ZoomBoundaryTests` 全部 PASS。
- `swift run FocusStudioE2E`：PASS（`zoomFrameDifference` 39.2，较 1.8 的 32.2 上升来自弹簧跟随在放大期间的额外位移；`returnFrameDifference` 0.85、`cursorChangedPixels` 68 与 1.8 一致，隐藏光标仍与无光标元数据渲染一致）。
- `zsh scripts/test.sh`：全部 PASS，退出码 0（含 RecordingLifecycleRegression、FocusStudioAppRegression、InstallationTests、Codex、AI 网关与助手用例，本地化 792 键对齐）。
- 实机抽帧：复制真实录制 F785D0E7… 为 QA 工程 E881BD7E…，把 2.225–2.492 s 的光标样本改为 `pointingHand`，用 1.9.0 候选构建通过 AI 助手 `export` 走正式渲染管线导出（1920×1196，7.09 s），ffmpeg 抽 2.15 / 2.22 / 2.26 / 2.30 / 2.40 / 2.48 / 2.51 / 2.54 s：2.22 s 前为 I-beam，2.26–2.30 s 为 I-beam 与小手交叉淡入，2.40–2.51 s 为完整的系统小手，2.54 s 淡回 I-beam（`.artifacts/qa/cursor-motion/pointing-hand-crossfade.png`）。
- 说明：真实录制中的小手来自录制时对系统光标（`NSCursor.currentSystem`）的指纹匹配与 `AXLink`/`AXURL` 语义，1.9 之前录制的工程没有这类样本，需要新录制才会出现；QA 工程可删除。

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

## 安装包与安装（1.8.0 / build 15）

- Universal 2 构建与打包通过：`dist/releases/Focus-Studio-1.8.0-universal-local.dmg`（SHA-256 `9bbda0b225616da03ebb6266851f946cbb6ba327411c7c40f2713dc4931879ea`）、`.zip`（`0ec3ad6d590a4189eaff3c83c969f5452111c13949d0a5050eaf14a310dbe74c`）、`.sha256`。
- 用 `scripts/install-app.sh … --yes` 安装到 `/Applications/Focus Studio.app`（此前 1.7.1 build 13 先退出），安装校验通过。
- 旧版本清理：所有 `dist/candidates/*`、`dist/Focus Studio.app`（1.1.2）、1.8.0 之前的 `dist/releases/*` 以及安装器保留的 `/Applications/.focusstudio-install-*` 恢复副本已移入废纸篓（`~/.Trash/focus-studio-old-versions-*`），本机只保留 `/Applications/Focus Studio.app` 1.8.0 与 1.8.0 的安装包。

## 安装包与安装（1.9.0 / build 16）

- Universal 2 构建与打包通过（`scripts/package-release.sh`，含 `verify-release.sh --require-universal`）：`dist/releases/Focus-Studio-1.9.0-universal-local.dmg`（SHA-256 `51f8da963dd3b65f1d92ec302ec8228dfb5934d09c80d0c3820b96c70d3bc9b9`）、`.zip`（`b0a703b6ca342fab74f71aea975b1c5ee0abe0b1fe3dd4d6f8fe6121f5119224`）、`.sha256`。
- `/Applications/Focus Studio.app` 1.8.0 build 15 处于空闲（只读打开工程、无录制）时先退出，再用 `scripts/install-app.sh … --yes` 安装 1.9.0 build 16；安装校验与 `codesign --verify --deep --strict` 通过，已重新启动。
- 旧版本清理：`dist/candidates/1.9.0-native`、`dist/Focus Studio.app`（本次 universal 构建副本）、1.8.0 的 `dist/releases/*` 以及安装器保留的 `/Applications/.focusstudio-install-*` 恢复副本（内含 1.8.0）已移入废纸篓 `~/.Trash/focus-studio-old-versions-20260922-225110`（275 MB），本机只保留 `/Applications/Focus Studio.app` 1.9.0 与 1.9.0 的安装包。

## 交付

- 已随 1.8.0 一起提交并推送到 `main`（含此前工作树中的暂停/续录、缩放意图排序、助手面板等改动）。
- 1.9.0 已作为 `a452b12` 提交并推送到 `main`；本安装记录随后续 docs 提交推送。

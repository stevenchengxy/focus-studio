# 光标样式、精简录制条与录制流程修复验证（2026-09-23，1.10.0 / build 17）

## 1. 光标样式与点击按压

| 项目 | 做法 |
| --- | --- |
| 样式集合 | `CursorAppearance` 增加 `elevated` / `light` / `accent`，连同原有 `system` / `highContrast` / `dot` 共六种，声明顺序即画廊顺序 |
| 素材 | 新文件 `Sources/FocusStudioCore/Rendering/CursorArtwork.swift`：箭头 / I-beam / 小手三种形状按同一调色板绘制（填充、描边、阴影），在 64×80 画布上以参考网格的 2 倍密度绘制，放大到 3× 仍锐利 |
| 尺寸一致 | `Graphic.supersample` 表示每个参考像素对应的图像像素，渲染时 `scale = baseScale / supersample`。切换样式不再改变光标大小 |
| 热点修正 | `NSCursor.image.size` 以点为单位而位图是 2 倍，`NSCursor.hotSpot` 也是点。现在统一换算成像素，系统箭头尖端不再比点击点偏右下约 8 px |
| 主题色 | `accent` 取点击反馈颜色；该颜色选择器在选中 accent 时出现在 Appearance 卡片内，不再只藏在「动画点击」开关后面 |
| 按压动画 | `ClickPressStyle`：`press`（先缩后回弹，与旧版逐点一致）、`pop`（先放大再回落）、`none`。新增 `pressAmount` 幅度滑杆。两条曲线首尾都是 1 且速度为零，逐帧定位精确 |
| 解耦 | 按压不再受「动画点击」开关控制，它现在有自己的控件。选 `none` 时形状切换的缩放脉冲也一并关闭 |
| 画廊 | 检查器 Cursor → Appearance 用 3×2 的缩略图网格，绘制的就是渲染器用的同一份素材；选中项显示勾选并在下方注明名称 |
| 容错解码 | `CursorAppearance` / `ClickPressStyle` / `ClickAnimationStyle` 增加宽容的 `init(from:)`，新版本写入的取值在旧版本里退回默认值而不是让整个工程无法读取 |

## 2. 精简录制条

- `RecordingPanelLayout` 以纯函数给出尺寸与位置：展开 760×116，录制中 324×46，圆角 22 / 15。
- 倒计时开始就收起，动画（0.22 s）在第一帧被捕获前就结束；`辅助功能 → 减弱动态效果` 时直接跳变。
- 位置锚定在当前窗口的底边中点，因此用户拖动过的位置不会被改回去；每块屏幕记住自己的 `visibleFrame`，不依赖会变成 nil 的 `panel.screen`。
- 面板只改大小、从不重建，`ignoredWindowNumbers` 的排除关系因此始终成立。
- 条上内容：状态点（切换中显示进度指示）、等宽定宽时钟、暂停 / 继续、Finish（保留文字）、丢弃、展开箭头。展开后回到完整控制台，可再收起。
- 丢弃是两步：点 ✕ 后就地询问「要丢弃这次录制吗？」，6 秒无操作自动取消，录制结束或离开录制态也会取消。面板 `canBecomeKey == false`，弹窗会把焦点从被演示的 App 上抢走，所以不用弹窗。
- Codex 计划驱动的录制中禁用丢弃：`StudioModel.cancelRecording` 在该状态下只取消计划，一个按钮不能有两种含义。
- 主窗口里的取消按钮改为带确认对话框（该窗口是 key 窗口，用对话框才合适）。

## 3. 录制流程修复

| 问题 | 原因 | 修复 |
| --- | --- | --- |
| 新开的窗口 / 网页在来源列表里看不到，必须重开软件 | 只有 `showRecorder()` 调用过一次 `refreshAvailableTargets()`；而且列表视图读的是 `model.captureEngine.availableTargets`，却只观察 `model`，引擎自己发布的变化不会触发重绘 | 新增 `refreshAvailableTargetsQuietly()`（失败不清空列表、不弹错误、保留已注册的区域目标、内容不变就不发布），录制页每 1.5 秒轮询一次并在 App 重新激活时立即刷新；`StudioModel.sourceListVersion` 把变化转发给观察 model 的视图 |
| 区域框选完就无法重新框选 | `AreaSelectionController.finish(localSelection:)` 在坐标换算失败时直接 `return`，continuation 永远不恢复：`isSelectingArea` 卡在 true，之后每次都抛 `selectionAlreadyActive`，只能重启 | 该分支改为 `finish(throwing:)` 并新增 `selectionOutsideDisplay` 错误；每次开始选择前先清理上一次留下的浮层 |
| 框选时没有确认 / 重画的入口 | 浮层只支持拖动、Return、双击、Esc，全部是不可见的约定 | 浮层底部加控件条：取消 / 整个屏幕 / 重新框选 / 使用此区域，未框选时后两个禁用 |
| 录完看不到软件 | 结束录制只切换 `destination`，App 仍在别的窗口后面 | `StudioModel.bringToFront()` 在保存成功后激活 App 并把主窗口带到前面 |

## 4. 自动化

- `zsh scripts/test.sh`：全部 PASS，退出码 0。快照套件已并入该脚本。
- 新增 `Tests/FocusStudioPermissionTests/CursorStyleTests.swift`：旧 JSON 解码、按压风格往返、`press` 与旧曲线逐点一致（误差 < 1e-9）、两条曲线首尾为 1 且无速度突变、幅度线性缩放、`none` 不动、六种样式的三种形状都有素材且渲染高度落在同一区间、各样式箭头互不相同、只有 accent 跟随点击色、画廊缩略图尺寸正确。接线方式用一次故意失败验证过。
- `ToolbarSnapshotTests` 扩展为四张离屏快照：760×116 与 640×116 控制台、324×46 录制条、Cursor 检查器、区域框选浮层。
- 实机验证来源刷新：启动候选版停在录制页截图，打开一个新的文本编辑窗口，7 秒后再截图，新窗口已出现在列表中，未重启 App。

## 5. 需要你确认的一件事

`~/Library/Application Support/FocusStudio/Projects` 在 2026-09-22 23:11 被清空，只剩 `Incoming`。这些工程都在废纸篓里（`mdfind` 在 `~/.Trash` 找到 36 个 `raw.mp4` 和对应的 `project.json`，含 `F785D0E7…` 与 QA 用的 `E881BD7E…`），可以直接从废纸篓拖回原目录恢复。删除动作来自 App 自身的删除流程（`ProjectStore.deleteProject` 用 `trashItem`），测试套件不会碰真实目录：所有测试都用 `ProjectStore(projectsDirectory:)` 指向隔离的临时目录。

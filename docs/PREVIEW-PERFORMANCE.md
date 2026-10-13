# 预览播放诊断

`FocusStudioE2E --preview-benchmark /绝对路径/project.json --output-dir /输出目录`

该命令只读加载保存的项目，使用与编辑器相同的 `ProjectVideoRenderer.prepare` 和 `AVPlayer` 合成路径，通过 `AVPlayerItemVideoOutput` 检查按播放时钟交付的帧。不会修改项目、原素材或导出额度。生成 `playback-benchmark.json`。

统计使用 4 ms 轮询，排除播放首秒，通常观察接下来的 8 秒。记录实际像素尺寸、缺失的帧时间间隔、帧交付间隔、帧相对播放时钟的迟到时间，以及 composition 准备、播放器就绪、播放后的首帧耗时。交付间隔包含轮询和调度误差，不能把 35 ms 的 p95 解释为每帧 GPU 耗时。

这是脱离编辑器 UI 的实时合成诊断，**不是 SwiftUI 界面帧率**，也不覆盖所有硬件、4K/高帧率项目和长时间播放。可用 `--preview-scale 0.75` 做显式降采样对照；这个诊断参数不会改变应用的默认预览或导出画质。

## 2026-10-14 基线

本机全分辨率 1920×1080、30 fps、`renderScale = 1`，第二次独立进程测试：

| 项目 | 观察帧数 | 缺失帧间隔 | 交付间隔 p95 | 迟到 p95 | 准备 composition | 播放后首帧 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Aster 产品特效项目 | 240 | 0 | 36.14 ms | 4.43 ms | 115.82 ms | 65.22 ms |
| 2992×1866 原始录屏项目 | 240 | 0 | 35.37 ms | 4.50 ms | 116.10 ms | 83.15 ms |

日志：`.artifacts/studio-launch/playback-composition-baseline.log`、`.artifacts/studio-launch/playback-recording-composition-baseline.log`。前一轮独立测试两种项目也均为 240 帧、0 缺失帧间隔。

这些项目的 Core 合成没有复现编辑器卡顿，因此本轮保持其输出分辨率、渲染算法与画质，优先修复活跃播放采样中确认的主线程 UI 刷新与本地化解析开销。这里的稳定交付数据本身不能作为 UI 已修复的证据；原生编辑器的独立采样见下文。

## 原生编辑器：build 60 → build 61

在同一台 ARM64 Mac、macOS 26.2、同一中文界面及「缩放 2」检查面板中保持实际播放，使用系统 `sample` 以 1 ms 间隔抓取主线程调用栈。两次采样时间分别为 01:04:21 与 01:13:34；build 61 的 7 秒采样结束后，界面仍处于播放状态，时间码为 13.63 秒，因此这次结果不是停在片尾后的空闲窗口。

| 主线程调用栈 | build 60（5515 个样本） | build 61（5159 个样本） |
| --- | ---: | ---: |
| SwiftUI RunLoop 更新回调 | 4590（83.23%） | 1087（21.07%） |
| 下拉菜单延迟刷新回调 | 3052（55.34%） | 未命中（0） |
| 字符串表 plist 解析 | 2672（48.45%） | 未命中（0） |
| 主事件循环等待分支 | 未命中（0） | 2550（49.43%） |

对应符号依次为 `@objc closure #1 in static NSRunLoop.addObserver(_:)`、`closure #2 in AppKitPopUpAdaptor.PlatformView.updateNSView(_:context:)`、`__CFBundleCreateStringsFromPlistData`、`__CFRunLoopServiceMachPort`。字符串表解析合并了三处互不嵌套的调用分支：2362、211、99。

这支持以下结论：播放时钟只更新时间码、滑块、指针和少量依赖时间的按钮后，整个编辑器及检查面板的重复更新负担明显降低；随应用打包的 `.strings` 转为二进制 plist 后，本次窗口中不再采到原先昂贵的字符串表解析路径。两个修复一起测试，不能凭此区分它们各自贡献了多少改善。主线程恢复了事件等待余量，合成分辨率及导出画质没有降低。

**统计限制：**这些数字是各自窗口内主线程调用栈的命中占比，不是 CPU 使用率、每帧渲染耗时或显示 FPS。表中父子调用栈有重叠，不能相加；「未命中」也不证明以后绝不会执行该路径。它是同一场景的一组短窗口前后对照，不代表所有项目、硬件或长期播放已无卡顿。剪辑、定位、快速播放/暂停及片尾重播仍须单独验收。

原始日志：`.artifacts/studio-launch/playback-active-before.sample.txt`、`.artifacts/studio-launch/playback-active-after.sample.txt`。提取计数：`.artifacts/studio-launch/playback-active-comparison.json`。

### build 61 交互验收

原生应用中已验证以下操作：

- 16 秒项目到达片尾后自动暂停；单击播放从开头继续，观察到时间码从 0.30 秒推进至 3.56 秒。
- 空格暂停；右箭头逐帧前进至 3.60 秒；快速连续两次空格后保持暂停（3.746 秒）。
- 快进 5 秒后立即播放，时间推进至 9.067 秒，未卡在定位后的暂停状态。
- 在自动创建的剪辑副本中临时裁为 4 秒，播放准确停在 4.000 秒，片尾拆分按钮禁用；撤销后恢复 16 秒，原有「缩放 2」仍保留。

以上为实机操作结果；时间码用于辨认测试步骤，不构成帧延迟或性能承诺。

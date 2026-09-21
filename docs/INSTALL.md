# Focus Studio 安装与首次使用

支持 macOS 15 Sequoia 及以上版本的 Apple Silicon 和 Intel Mac。应用使用系统自带的录屏、视频和音频框架；录制、编辑、导出无需安装 Xcode、Homebrew、FFmpeg 或 Node.js。Windows / Linux 不支持此原生 macOS 版本。

## 安装

1. 打开 `Focus-Studio-…-universal-….dmg`。
2. 将 **Focus Studio.app** 拖到 **Applications（应用程序）**。
3. 从“应用程序”打开 Focus Studio，然后退出磁盘映像。

也可解压 ZIP，将其中的 Focus Studio.app 移入“应用程序”。请勿直接在 DMG 内长期运行应用。包中的 `Release-Status.plist` 记录架构、最低系统版本及本次签名、公证状态。

文件名包含 `local` 的版本采用本地签名，**尚未通过 Apple 公证**。首次打开时可能被 Gatekeeper 拦截。确认文件来自可信发送者后，按 macOS 界面提示，在“系统设置 → 隐私与安全性”中选择“仍要打开”。请勿关闭 Gatekeeper 或批量清除隔离属性。正式对外分发版本应使用 Developer ID 签名并经 Apple 公证。Apple 的说明：https://support.apple.com/102445

## 管理录屏库（1.1.3）

点击 **Select recordings / 选择录屏** 进入选择模式，然后点击卡片或复选框选择多个录屏。底部固定的工具栏提供 **Select all / 全选**、**Deselect all / 取消全选**；按住 Shift 点击可连续选择，按住 Command 点击可切换单个项目的选择状态。**Done selecting / 完成选择** 退出选择模式，不删除任何内容。

点击 **Delete selected / 删除所选项** 后，会显示数量和确认提示；选择 **Move to Trash / 移到废纸篓** 才执行操作。删除范围仅为所选项目的文件夹及其中的录制和媒体，不会删除项目文件夹外的原始导入文件或已导出视频。成功移到废纸篓的项目会从列表中消失，失败项目保留并显示原因；不会因为批量操作中某一个失败而把所有项目当作删除成功。

删除是可恢复的“移到废纸篓”，不是永久删除。需要恢复时，在 Finder 的废纸篓中找到原项目文件夹，使用系统提供的“放回原处”，或将完整的 UUID 项目文件夹移回 `~/Library/Application Support/FocusStudio/Projects` 后重新打开应用。请保留项目文件夹里的 `project.json`、`raw.mp4` 及媒体文件；清空废纸篓后，应用不能替你恢复这些文件。

每个录屏卡片的 **Recording actions / 录屏操作** 菜单提供 **Rename / 重命名**，单选时也可使用底部工具栏的 **Rename / 重命名**。名称不能为空，最多 120 个字符。保存后只更改项目的展示名称，录制内容、文件路径和剪辑参数保持不变；点击取消不保存修改。

## 录屏权限

每台新 Mac 都要由使用者单独授权；安装包不会携带另一台电脑的权限或账号。

- **录屏与系统录音**：首次录制所选屏幕或窗口时授权；按系统提示重新打开应用。
- **输入监控**：需要记录其它应用中的鼠标位置和点击、自动生成缩放时授权。
- **麦克风**：仅在用户启用解说录音时需要。
- **辅助功能**：用于识别其它应用中的可编辑输入框、自动显示输入光标，以及在打字期间保持放大；也用于 Codex Director 执行鼠标点击和滚动。需要这些功能时，请手动开启此权限；普通屏幕录制不依赖此权限。

开始录制前，请检查录制面板显示的 **Accessibility（辅助功能）** 和 **Input Monitoring（输入监控）** 两项状态。完整的鼠标、键盘交互追踪需要两项权限都开启。开启 **Automatic zooms** 而权限不完整时，可以通过提示中的 **Open Accessibility Settings** 或 **Open Input Monitoring Settings** 手动授权，再返回应用录制；也可选择 **Record with limited tracking**，保留视频录制但接受部分点击或输入效果可能缺失。系统要求重新打开应用时，请先退出再启动“应用程序”中的同一份 Focus Studio。

只开启辅助功能时，对提供无障碍编辑通知的输入框，软件仍可根据焦点和编辑活动保持输入区域放大。这不能替代完整的全局鼠标、键盘追踪；是否记录到点击和输入，应以完成录制后编辑器中的交互数据为准。权限检查只读取当前授权状态，不会在开始录制时主动触发额外的输入监控授权弹窗。

Chrome 产品演示：选择 **Window → Chrome 窗口**，开启 **Webpage only**；显示书签栏时同时开启 **Hide bookmarks bar**。局部固定画面选择 **Area**，拖动选框并回车确认。所有录制都需要手动点击开始，倒计时后才开始计时。背景音乐和音效在编辑器内手动添加。

输入演示可在编辑器 **Animation → Typing focus** 中开启 **Hold zoom while typing**，并通过 **Wait after typing** 调整停止打字后等待多久再缩回。此功能使用新录制中的时间和焦点位置数据，不保存输入文字或按键内容。旧录制没有这些数据时，可以手动拉长时间线上的缩放块。

如果编辑器提示没有捕获点击或输入活动，说明该段视频缺少生成自动缩放所需的交互数据。稍后授权无法补回已经录制的视频事件：请完成权限设置后新录一段，或在原视频的 **Zoom** 时间线上双击添加并调整缩放块。

## 录制后逐段调整缩放（1.1.2）

点击底部任一紫色 **Zoom / 缩放** 块，右侧会显示对应编号。片段重叠时，也可通过右侧 **Selected zoom / 当前缩放** 下拉框逐个选中。

- 拖左侧把手改变开始时间；拖右侧把手延长或缩短结束时间；拖中间整体移动。
- 右侧可输入 **Start / 开始**、**End / 结束**、**Total duration / 总时长**、**Hold at full zoom / 完全放大后停留**。按回车或离开输入框提交；时间自动限制在视频范围内。
- **Speed for this zoom / 当前缩放的速度** 单独控制该片段放大、缩回的秒数。秒数越小越快；可选快速、自然、舒缓预设。过短的片段会等比例缩短两端过渡。
- 手动编辑的片段会保留，不会被自动缩放或打字等待设置重新生成覆盖。保存并重新打开后仍保留；预览与 MP4 导出使用同一套计时。

## 界面语言与图标（1.1.2）

点击项目库或编辑器顶栏的地球图标，选择 **English**、**简体中文** 或跟随系统，也可以在应用设置中切换。选择会记住并即时更新应用界面，不重启、不重建录制会话。项目名、用户输入、文件名和视频内容保持原样；macOS 自身的界面及外部服务返回内容遵循其自身语言设置。

应用现已包含原创紫色聚焦画框与播放符号图标，已打包为原生多尺寸 ICNS，供 Finder、Dock 和应用窗口使用。

## 在新电脑连接 Codex

录屏和剪辑本身无需 Codex。要使用 AI Director，请在该 Mac 安装官方 Codex CLI，或准备已安装的 Codex.app / ChatGPT.app。

1. 进入 **Codex Director → Connection**，或点击 **Set up Codex**。
2. 在 **Codex installation** 中使用自动检测，或通过 **Choose…** 选择 `codex` 可执行文件 / Codex.app / ChatGPT.app。
3. 点击 **Save & test connection**，再选择 **Sign in with ChatGPT** 并完成浏览器登录；也可点击 **Use API key → Save key & sign in** 手动输入自己的密钥。
4. 在 **Planning model** 选择账号支持的模型或保留 **Account default**，保存后即可发送任务。

默认的 **Sign in for Focus Studio** 使用独立的应用登录，凭据由 macOS 钥匙串保存。已经在终端登录 Codex 的用户可选择 **Use existing Codex sign-in**。连接测试只读取账号和模型信息，不发起计费任务；使用 API Key 生成任务时按自己的 OpenAI API 账号计费。ChatGPT / Codex 账号和权限不会随安装包转移。官方安装与认证说明：https://developers.openai.com/codex/cli/

## 数据与更新

项目和原始录制保存在当前用户的 `~/Library/Application Support/FocusStudio/Projects`。此安装包仅包含应用及静态素材，不含录制、浏览记录、项目、Codex 账号或 API Key。更新时退出应用，再替换“应用程序”里的 app；项目保留在当前用户的应用支持目录。

macOS 壁纸来自当前电脑系统中已安装的图片，因此不同电脑的壁纸列表可能不同。自选背景、音频和项目迁移请一并保留对应媒体文件。Apple Silicon 上的真实录制流程经过验证；Intel 切片完成编译与结构验证，但仍需 Intel 实机验收。

本地签名的不同构建可能触发 macOS 再次请求权限。使用同一个 Developer ID 证书发布签名版本可保持稳定的发布身份。

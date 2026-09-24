# Focus Studio 安装与首次使用

支持 macOS 15 Sequoia 及以上版本的 Apple Silicon 和 Intel Mac。应用使用系统自带的录屏、视频和音频框架；录制、编辑、导出无需安装 Xcode、Homebrew、FFmpeg 或 Node.js。Windows / Linux 不支持此原生 macOS 版本。

## 安装

1. 打开最新的 `Focus-Studio-…-universal-….dmg`，运行其中的 **Focus Studio.app**；也可先解压 ZIP。
2. 返回项目库的空闲状态，打开 **Settings → Installation / 设置 → 安装**。确认“当前副本”的版本、build 和路径，然后点击 **Install this copy to Applications / 将此副本安装到应用程序** 并确认。
3. 安装验证完成后，点击 **Open installed copy / 打开已安装副本**。以后固定从 `/Applications/Focus Studio.app` 启动。
4. 手动退出下载目录、磁盘映像或开发目录里的旧窗口，再退出磁盘映像。如果 Dock 固定了旧路径，请移除旧图标，再从“应用程序”把最新版拖入 Dock。

请勿直接在 DMG 或历史版本目录内长期运行应用。包中的 `Release-Status.plist` 记录架构、最低系统版本及本次签名、公证状态。Finder 手动拖入“应用程序”仍可用，但会绕过应用内的版本、防降级和回滚检查，更新时优先使用上述安装操作。

文件名包含 `local` 的版本采用本地签名，**尚未通过 Apple 公证**。首次打开时可能被 Gatekeeper 拦截。确认文件来自可信发送者后，按 macOS 界面提示，在“系统设置 → 隐私与安全性”中选择“仍要打开”。请勿关闭 Gatekeeper 或批量清除隔离属性。正式对外分发版本应使用 Developer ID 签名并经 Apple 公证。Apple 的说明：https://support.apple.com/102445

## 纯聊天助手（1.7.1）

数字人、男女形象选择和 3D 动画已移除，安装包不再包含人物模型。Demo 导演与 AI 助手采用紧凑聊天界面，保留聊天记录、模型配置、附件、语音输入、可选语音回复和录制计划。此次更新不会删除录屏项目或现有对话。

## 录前工具栏、暂停与鼠标显示（1.6.0）

进入“新录制”后，浮动工具栏处于 **Ready to record / 准备录制** 状态，不会自动开始。可从工具栏选择屏幕、窗口或区域，并调整鼠标显示、自动缩放、麦克风和系统音频。选好来源后，手动点击 **Start recording / 开始录制**；倒计时期间可取消。录前也可截取所选来源的 PNG，不必先录一段视频。

录制期间，工具栏提供 **Screenshot / 截图**、**Pause recording / 暂停录制**、**Resume recording / 继续录制** 和 **Finish / 完成**。暂停时不写入新的视频、音频或交互事件，显示时长不包含暂停时间；继续会重新验证同一来源，来源已关闭时不会自动改录其它窗口。可在暂停状态直接完成，保存已有片段。保存期间请等待完成，不要强制退出。连接的各显示器都有一个工具栏，录制时排除本应用的工具栏画面。

录前的 **Show cursor / 显示鼠标** 控制录后项目的鼠标展示，编辑器中仍可更改。隐藏鼠标不会关闭自动缩放或点击效果，这些效果可单独编辑。该开关不能擦除已经烧录在导入视频或截图像素中的鼠标。它也不会补回未被权限或输入监听捕获的鼠标轨迹。

## 固定安装位置与更新（1.5.0）

设置页同时显示当前运行副本和 `/Applications/Focus Studio.app` 的版本、build 与完整路径；新版本从其它目录运行时会显示提示。如果正式安装位置已有更新版本，旧副本不能覆盖它，可以明确点击打开已安装副本。此提醒只能由支持该功能的 1.5.0 及后续版本显示，不能改写已经存在的旧版本程序。

更新时下载并打开新的可信安装包，再用新版本自己的安装操作。应用按照数字比较版本和 build，拒绝降级，也拒绝“版本号和 build 相同但内容不同”的覆盖。录屏、倒计时、导出、编辑或助手任务未完成时请先完成操作并返回项目库。若安装位置的应用仍在运行，安装器会要求使用者自行退出，不会强制关闭或覆盖运行中的应用。

安装先在目标目录暂存并验证副本，再替换正式安装位置；验证失败时尝试恢复旧版。更新成功后，旧版保留在设置页列出的隐藏恢复目录中的 `previous.bundle`，不作为另一个可启动的 `.app` 注册。恢复时请先退出正式应用，并由熟悉文件管理的使用者将该完整 bundle 恢复为 `/Applications/Focus Studio.app`；不要改动项目目录。

安装不删除其它位置的旧 app、不更改项目和账号、不自动启动或退出应用，也不静默联网自更新。尚未配置经过签名验证的更新源。若 `/Applications` 无写入权限，请联系管理员正常安装；软件不会请求 sudo 或关闭系统安全机制。固定安装位置有助于避免误启动旧副本，但 ad-hoc 签名的应用移动或重新构建后，macOS 仍可能要求重新授权。

## 统一聊天与 Demo 导演（1.5.0）

项目库的 **Demo Director / Demo 导演** 和独立 **AI Assistant / AI 助手** 窗口共用一段对话，可使用已经配置的 AI 模型，或在 **设置 → AI 模型 → Assistant brain** 选择 Codex。聊天不会仅因打开导演页而访问网页、截屏或开始录制。

先讨论目标、时长和演示步骤，再请助手生成录制计划。右侧显示草稿；继续在聊天中修改，检查后点击 **Run recording plan / 执行录制计划** 并确认。直接通过聊天开始或停止录制也需要确认。目前文本聊天没有实时网页视觉观察能力，因此不执行仅凭模型猜测坐标的实时点击计划；可规划跳转、滚动、等待。需要真实点击/输入交互时先使用手动录制，录后再让助手编辑。截图演示中的点击仅生成缩放，不操作桌面。

聊天保存在本机 `~/Library/Application Support/FocusStudio/Assistant/conversation.json`；“新建对话”清除聊天与计划草稿，不清除录屏。可停止生成、重试失败回复；重试不会重复执行已经尝试过的同一工具。切换模型后重置隐藏的模型会话，仍以可见历史作为上下文。尚未配置模型时输入仍保留，配置后可重试。

本地镜头算法按时间顺序处理点击与输入：近处重复点击去抖，远处点击交接镜头，继续输入重新聚焦，动态增高的输入框保持焦点稳定。手动修改过的缩放不会因算法更新被重置。

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

## 让 Claude Code / Codex 使用 Focus Studio（MCP，1.5.0）

Focus Studio.app 内附带 MCP server `Contents/MacOS/focus-studio-mcp`。接入后，Claude Code 和 Codex 可以在 Focus Studio 里录制、编辑和导出：所有操作都在应用里执行，你能看到每一步，也可以随时接手。录屏和剪辑本身不需要接入。

开始前：

1. 按上文把 Focus Studio 装进“应用程序”，从那里手动打开一次，完成 Gatekeeper 确认和录屏授权。录制沿用 Focus Studio 自己的权限，不需要给终端、Claude Code 或 Codex 授予录屏权限。
2. 安装 Claude Code（`claude`）或 Codex CLI（`codex`）。只装了 Codex.app / ChatGPT.app 时，一键接入会自动找到其内置的 `codex`；它不在 PATH 中，手动接入时要把命令开头的 `codex` 换成完整路径（见下文）。

### 一键接入

1. 打开 **Focus Studio → Settings… / 设置…**（⌘,），选择 **AI tools / AI 工具** 标签页。
2. 确认 **Allow AI tools to control Focus Studio / 允许 AI 工具控制 Focus Studio** 已开启，下方显示 **Ready for AI tools. / 已准备好接受 AI 工具的调用。**
3. 在 **Connect AI tools / 接入 AI 工具** 中，对 Claude Code 或 Codex 点 **Connect / 接入**。应用调用它们自己的命令（`claude mcp add` / `codex mcp add`）注册名为 `focus-studio` 的 MCP server，不改动其他设置；Claude Code 注册在 user 作用域，所有项目都能用。显示 **Connected. / 已接入。** 后，开始新的 Claude Code 或 Codex 会话即可。
4. 显示 **Connected to another copy / 已接入另一个副本** 时，说明登记的是别处的 Focus Studio（例如旧的开发构建），点 **Update / 更新** 改为当前这一份。
5. 应用在登录 shell 的 PATH 和常见安装目录中查找 `claude` / `codex`。每个客户端下方显示一条可复制的命令，里面已经是当前这份应用的 helper 路径；找到了命令行工具时，命令开头就是它的完整路径（例如 ChatGPT.app 内置的 `codex`），在“终端”里可以直接运行。找不到时 **Connect / 接入** 不可用，命令开头是 `claude` / `codex`：装好命令行工具后点 **Check again / 重新检查**；也可以点 **Copy command / 拷贝命令** 粘贴到“终端”，命令行工具不在 PATH 中时把开头换成它的完整路径再运行。

### 手动接入

应用在“应用程序”里时：

```sh
claude mcp add --scope user focus-studio -- "/Applications/Focus Studio.app/Contents/MacOS/focus-studio-mcp"
codex mcp add focus-studio -- "/Applications/Focus Studio.app/Contents/MacOS/focus-studio-mcp"
```

终端里没有 `codex` 命令、只有 ChatGPT.app 内置的 `codex` 时，用完整路径（Codex.app 为 `/Applications/Codex.app/Contents/Resources/codex`）：

```sh
/Applications/ChatGPT.app/Contents/Resources/codex mcp add focus-studio -- "/Applications/Focus Studio.app/Contents/MacOS/focus-studio-mcp"
```

检查：`claude mcp get focus-studio`（或在 Claude Code 里运行 `/mcp`）、`codex mcp list`（内置的 `codex` 同样用完整路径）。helper 自己回答握手和工具列表，这一步不会启动 Focus Studio。

### 第一次调用：批准

- Focus Studio 没在运行时，第一次工具调用会在后台启动它，不抢键盘焦点。
- 新的 AI 工具第一次调用时，Focus Studio 弹出 **Allow AI tool? / 允许 AI 工具？**：显示 AI 工具自报的名称（例如 Claude Code）、它要运行的工具，以及实际启动 helper 的程序路径和签名者。这和下文的 **Record sound? / 录制声音？** 询问是外部调用仅有的两个会把应用切到前台的时刻；回答声音询问后，键盘焦点回到你原来使用的应用。
- 点 **Allow / 允许** 后记住，之后不再询问；点 **Don't Allow / 不允许**、关闭面板或 2 分钟内没有处理，这次调用不执行。拒绝后约 10 分钟内同一程序不会再弹窗，可以在设置页 **Recently declined / 最近拒绝的** 里改为 **Allow / 允许**。
- 每个调用都有自己的时间：从到达 Focus Studio 算起约 200 秒，并扣除 helper 启动应用、建立连接已经用掉的时间（见下文“Codex 超时”）。面板还开着、这段时间先用完时，这次调用不执行，先返回“仍在等待批准”（`structuredContent.status` 为 `waiting_for_approval`），面板保持打开；AI 工具再调用一次会继续等同一个面板，你点允许后立即执行。按默认设置，上一条的 2 分钟通常先到，只有 helper 启动应用、建立连接用了很久时才会先遇到这种情况。
- 批准按程序记住：有开发者签名的程序按签名身份（更新后仍然有效），其他程序按可执行文件路径，node、python 运行的脚本按“解释器 + 脚本路径”。由 shell 直接启动 helper 时（例如自己在终端里测试），面板用橙色说明这次批准只在本次连接有效，不会记住。

### 撤销与关闭

- **AI tools / AI 工具 → Approved AI tools / 已批准的 AI 工具** 列出每个已批准的程序（名称、路径、签名、批准时间和上次使用时间），点 **Revoke / 撤销** 即可。已经在排队的调用会被拒绝；该程序再次调用时，会重新弹出批准面板。
- 关闭 **Allow AI tools to control Focus Studio / 允许 AI 工具控制 Focus Studio** 后，所有外部调用都被拒绝，helper 也不会再在后台启动应用。
- 取消接入：`claude mcp remove focus-studio`、`codex mcp remove focus-studio`。

### 使用中会看到什么

- 编辑和导出时，主窗口回到最前（不抢键盘焦点），编辑器打开 AI 工具指定的项目，顶栏下方显示 “Claude Code is working… / Claude Code 正在操作…”。开着别的项目时先保存再切换；录制中或应用正忙时，编辑工具会返回错误，不会丢掉修改。
- 录制：每个显示器底部居中的录制控制条先显示 3 秒倒计时，Focus Studio 在后台或没有打开主窗口时也一样。✦ 旁是请求录制的 AI 工具名称（悬停或 VoiceOver 读出“哪个 AI 工具请求录制什么”），要录声音时有黄色的麦克风 / 扬声器图标，带 **Cancel / 取消**；展开控制条可看到完整说明。之后收起为录制条；设置了时长时，录制条在计时器图标旁显示剩余的录制时间。随时可以 **Pause recording / 暂停录制**、**Resume recording / 继续录制**：暂停时不录任何画面、声音和点击，暂停的时间不计入时长，剩余时间也不减少。点 **Finish / 结束** 结束录制（暂停中也可以），或点 ✕ 后确认 **Discard / 丢弃**（丢弃的录制移到废纸篓，可以恢复）。控制条不会录进视频；结束的录制都会保存到项目库，没有静默录制。
- 录制时的声音：AI 工具要为某次录制打开麦克风或系统音频，而你在录制器里没有打开它们时，倒计时之前会弹出 **Record sound? / 录制声音？**，写明哪个 AI 工具想录哪种声音、要录制什么，以及实际启动这个 AI 工具的程序（**Started by / 启动它的程序**，与批准面板相同；AI 工具自报的名称可以随意填写）。三个按钮：**Allow for this recording / 仅本次允许**（按它的要求录制）、**Record without sound / 无声录制**（只录画面、不录任何声音，录制器里本来打开的声音这次也不录；AI 工具会在结果里看到你的选择）、**Cancel recording / 取消录制**（不录制；按 Esc 或关闭面板也一样）。询问期间你在录制器里关掉的声音，这次录制也不会录。没有默认按钮，在别的应用里按回车不会替你选择；60 秒内没有回答就不录制，面板自动关闭。每次这样的录制都会重新询问，不会记住，也不会改动录制器里的设置；回答后键盘焦点回到你原来使用的应用。AI 工具不额外要求声音时（或要的声音你本来就开着），录制直接开始、不会弹窗；应用内的 AI 助手由你自己操作，也不会询问。
- 导出不会覆盖已有文件（除非 AI 工具明确要求覆盖），也不会写项目自己的原始录像。删除项目只移到废纸篓。

### 常见问题

- **应用不在 /Applications**：helper 路径是 `<Focus Studio.app 所在位置>/Contents/MacOS/focus-studio-mcp`，例如 `~/Applications/Focus Studio.app/Contents/MacOS/focus-studio-mcp`。设置页 **Connect AI tools / 接入 AI 工具** 下方显示当前这份应用的 helper 路径和完整命令，一键接入也用这个路径。移动或替换应用后，回到设置页点 **Update / 更新**，或重新运行手动命令。用 **Settings → Installation / 设置 → 安装** 把其他位置的副本装进“应用程序”后，从已安装的副本打开 **AI tools / AI 工具** 页；显示 **Connected to another copy / 已接入另一个副本** 时点 **Update / 更新**。AI 工具正在调用或后台任务（例如导出）还在进行时，安装页会要求先等它们完成。
- **从 DMG 或解压位置直接运行**：在磁盘映像里（`/Volumes/…`）运行，或 macOS 把刚下载的应用放到临时位置运行（App Translocation）时，这个路径之后会失效，所以设置页会提示并禁用接入。请把 Focus Studio 移到“应用程序”，从那里重新打开再接入。如果 helper 启动的是一份从未打开过的副本，macOS 可能先询问是否打开；30 秒内没有确认，这次调用会返回说明，确认后再试一次即可。
- **Codex 超时**：Codex 0.141.0（2026 年 6 月）起，MCP 工具调用默认最多等 300 秒，一般不需要修改配置：等待录制和等待后台任务的工具每次最多等 240 秒，导出或拼接超过约 200 秒会返回 `job_id` 转为后台任务；握手和列工具由 helper 立即回答，不等应用启动。更早的 Codex 默认只等 120 秒（更老的版本为 60 秒），长时间的导出或等待会先在 Codex 端超时：请更新 Codex（`codex --version` 查看版本），或在 `~/.codex/config.toml` 的 `[mcp_servers.focus-studio]` 下加一行 `tool_timeout_sec = 300`，再开始新的 Codex 会话。这约 200 秒从调用到达 Focus Studio 算起，并扣除 helper 在后台启动应用、建立连接已经用掉的时间；等待批准、排队和等你回答声音询问的时间也都算在内，所以新 AI 工具的第一次调用同样会在 300 秒之内得到回答。批准面板 2 分钟内没人处理时，调用返回“没人回答”的错误（极少数情况下先返回 `waiting_for_approval`）；排队等另一个调用时时间用完，返回 `waiting_for_turn`；这两种情况调用都没有执行，AI 工具再调用一次即可。还在等你回答声音询问时，调用返回 `job_id`，AI 工具用 `wait_for_job` 取得录制结果。
- **“Focus Studio could not be reached”**：helper 连不上应用。先手动打开 Focus Studio，看 **AI tools / AI 工具** 页是否显示 **Ready for AI tools.**；显示 “AI tools cannot connect: … / AI 工具无法连接：…” 时按其中的原因处理（控制通道在 `~/Library/Application Support/FocusStudio/Control/`）。再确认 MCP 配置里没有给 helper 设置 `FOCUS_STUDIO_MCP_NO_LAUNCH=1`（设置后 helper 不会自动打开应用）或 `FOCUS_STUDIO_CONTROL_SOCKET`（只用于测试）。
- **“Focus Studio is set not to accept AI tools”**：总开关已关闭，打开即可。
- **“Another copy of Focus Studio … is running but is not accepting AI tools”**：另一份不提供 AI 工具的 Focus Studio（例如 1.4.0 或更早版本）正在运行。两份应用会同时编辑同一个项目库，所以 helper 不会再打开第二份；退出那一份或更新它即可。
- **查看 helper 日志**：helper 的日志只写到标准错误。Claude Code 连上 MCP server 之后不再保留它的标准错误，Codex 默认也不会把终端里 `export` 的变量传给 helper，所以在 AI 工具的会话里一般看不到这些日志。需要排查时，按源码仓库 `docs/MCP-QA.md` 中“一个可以手动发消息的 MCP 会话”，在终端里带 `FOCUS_STUDIO_MCP_LOG_LEVEL=debug` 直接运行 helper：日志包括连接、启动应用、hello 和每个调用。Codex 也可以先 `codex mcp remove focus-studio`，再 `codex mcp add --env FOCUS_STUDIO_MCP_LOG_LEVEL=debug focus-studio -- "<helper 路径>"` 重新登记，这些行会以 `MCP server stderr` 开头记进 Codex 自己的日志；排查完同样先 remove，再用不带 `--env` 的命令登记回来。

## AI 助手操控应用、Codex 大脑与语音

点击编辑器或项目库顶栏的 **AI** 打开独立的助手窗口。直接说需求，例如"录一段 Chrome 窗口的操作，停止后自动加缩放和章节字幕，导出 1080p"，助手会逐步执行并汇报；开始录制前有 3 秒倒计时，付费生成（Seedance）前会弹出费用确认。

大脑二选一（设置 → AI 模型 → Assistant brain）：**默认文本模型**（已配置的 API Key 提供商）或 **Codex**（在"Codex"页登录 ChatGPT 后即可，无需 API Key）。首次启动时如果 `~/.config/focus-studio/ark.env` 存在火山方舟密钥，应用会自动导入并选定默认模型。

语音：按下麦克风按钮说话，识别结果实时写入输入框，停顿约 1.5 秒自动结束；首次使用需要允许"语音识别"和"麦克风"权限。可在面板中开启"语音回复"让助手朗读答案。

## AI 模型、章节字幕与 AI 助手（1.3.0）

**设置 → AI 模型**：在左侧选择提供商（OpenAI、Anthropic、DeepSeek、智谱 GLM、Kimi、OpenRouter、火山方舟或自定义 OpenAI 兼容端点），粘贴 API 密钥并保存（写入 `~/Library/Application Support/FocusStudio/secrets.json`，权限 600，不会进入项目或安装包；本地签名的应用不再使用钥匙串，避免每次重新构建后弹出授权对话框），点击 **Test / 测试** 拉取模型列表，然后在顶部选择 **Default text model / 默认文本模型**。OpenRouter 只需一把密钥即可使用多家厂商的模型；火山方舟的密钥同时用于豆包文本模型和 Seedance / Seedream 生成。Codex Director 仍在 **Codex** 页单独配置。

**章节字幕**：编辑器时间线新增 **Chapters / 章节** 泳道，双击添加、拖动移动或改变起止；右侧 **Captions / 字幕** 工具可编辑标题、字幕、样式（位置、大小、章节编号、强调色）并导出 SRT。字幕在预览与导出中一致显示。填写"这个演示展示了什么"后，**Generate chapters / 生成章节** 会根据点击、缩放与输入时间由 AI 生成章节，**Polish captions / 润色字幕** 精简改写；未配置 AI 模型时这些按钮禁用。

**AI 助手**：编辑器顶栏的 **AI** 按钮打开对话面板。用自然语言描述意图（例如"为这段录屏生成一张深紫色科技感背景图"、"把当前画面做成 5 秒片头"、"按我的点击生成章节字幕"），助手会先理解意图、必要时追问，再调用工具：Seedream 生图、Seedance 生视频（付费前显示预估费用并等待确认）、截取当前画面作为参考图、修改背景与外观设置、写入章节、导出并拼接片头 + demo + 片尾。生成的素材保存在项目目录的 `ai/` 文件夹，随时可以手动修改。

## 录制源实时预览与镜头动效（1.2.0）

进入 **New recording / 新建录制** 后，每张显示器或窗口卡片都会显示约每秒刷新一次的缩略图；当前选中的卡片以 12 fps 实时预览，并带有 **LIVE** 标记。区域模式会在所选显示器缩略图上标出已框选的矩形。预览只保存在内存中，返回项目库或开始倒计时时立即停止。缩略图需要录屏权限；未授权时卡片保留图标占位，不影响录制流程。

编辑器 **Cursor → Smoothing** 决定自定义箭头的平滑程度：Smooth / Medium / Rapid 会把原始鼠标采样重采样到 120 Hz 并做零相位平滑，同时保证每次点击时箭头精确落在点击点；None 保持原始采样。箭头与输入框的 I-beam 之间会交叉淡入。**Animation → Follow cursor** 控制放大期间镜头跟随光标的强度（默认 60%）。

编辑器 **Animation → Screen animation** 新增 **Cinematic / 电影感** 曲线并作为新项目默认：镜头先快速切入，再长时间平缓落定，起止两端没有速度突变。**Link nearby clicks / 链接相邻点击**（默认 1.0 秒，可调 0–2.5 秒）决定上一段缩放结束后多久内的下一次点击会让镜头保持放大并平移过去；设为 0 恢复逐段独立缩放。旧项目保留原有曲线设置，打开后不会被改写。

## 录制后逐段调整缩放（1.1.2）

点击底部任一紫色 **Zoom / 缩放** 块，右侧会显示对应编号。片段重叠时，也可通过右侧 **Selected zoom / 当前缩放** 下拉框逐个选中。

- 拖左侧把手改变开始时间；拖右侧把手延长或缩短结束时间；拖中间整体移动。
- 右侧可输入 **Start / 开始**、**End / 结束**、**Total duration / 总时长**、**Hold at full zoom / 完全放大后停留**，以及 1.8 新增的 **Zoom in ends / 放大完成于** 和 **Zoom out starts / 缩小开始于**（绝对时间）。选中的缩放块上还有两个内侧把手，可直接拖动这两个时刻，块的起止保持不变。按回车或离开输入框提交；时间自动限制在视频范围内。
- **Speed for this zoom / 当前缩放的速度** 单独控制该片段放大、缩回的秒数。秒数越小越快；可选快速、自然、舒缓预设。过短的片段会等比例缩短两端过渡。
- 手动编辑的片段会保留，不会被自动缩放或打字等待设置重新生成覆盖。保存并重新打开后仍保留；预览与 MP4 导出使用同一套计时。

## 界面语言与图标（1.1.2）

点击项目库或编辑器顶栏的地球图标，选择 **English**、**简体中文** 或跟随系统，也可以在应用设置中切换。选择会记住并即时更新应用界面，不重启、不重建录制会话。项目名、用户输入、文件名和视频内容保持原样；macOS 自身的界面及外部服务返回内容遵循其自身语言设置。

应用现已包含原创紫色聚焦画框与播放符号图标，已打包为原生多尺寸 ICNS，供 Finder、Dock 和应用窗口使用。

## 在新电脑连接 Codex

录屏和剪辑本身无需 Codex，Demo 导演也可使用已配置的 AI 网关模型。若选择 Codex 作为聊天模型，请在该 Mac 安装官方 Codex CLI，或准备已安装的 Codex.app / ChatGPT.app。

1. 进入 **Demo Director → Connection**，或 **Settings → Codex**。
2. 在 **Codex installation** 中使用自动检测，或通过 **Choose…** 选择 `codex` 可执行文件 / Codex.app / ChatGPT.app。
3. 点击 **Save & test connection**，再选择 **Sign in with ChatGPT** 并完成浏览器登录；也可点击 **Use API key → Save key & sign in** 手动输入自己的密钥。
4. 在 **Planning model** 选择账号支持的模型或保留 **Account default**，保存后，在 **AI 模型 → Assistant brain** 选择 **Codex (ChatGPT sign-in)**，即可在聊天中使用。

默认的 **Sign in for Focus Studio** 使用独立的应用登录，凭据由 macOS 钥匙串保存。已经在终端登录 Codex 的用户可选择 **Use existing Codex sign-in**。连接测试只读取账号和模型信息，不发起计费任务；使用 API Key 生成任务时按自己的 OpenAI API 账号计费。ChatGPT / Codex 账号和权限不会随安装包转移。官方安装与认证说明：https://developers.openai.com/codex/cli/

## 数据与更新

项目和原始录制保存在当前用户的 `~/Library/Application Support/FocusStudio/Projects`。此安装包仅包含应用及静态素材，不含录制、浏览记录、项目、Codex 账号或 API Key。更新时退出应用，再替换“应用程序”里的 app；项目保留在当前用户的应用支持目录。

macOS 壁纸来自当前电脑系统中已安装的图片，因此不同电脑的壁纸列表可能不同。自选背景、音频和项目迁移请一并保留对应媒体文件。Apple Silicon 上的真实录制流程经过验证；Intel 切片完成编译与结构验证，但仍需 Intel 实机验收。

本地签名的不同构建可能触发 macOS 再次请求权限。使用同一个 Developer ID 证书发布签名版本可保持稳定的发布身份。

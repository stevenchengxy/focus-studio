# MCP 控制通道与后台自动启动：手动验收

`zsh scripts/test.sh` 已自动覆盖 helper 与应用之间的协议：hello 握手与协议版本检查、调用转发、进度、取消、应用中途退出、重连、批准流程，以及一次真实链路的端到端调用（`focus-studio-mcp` → `ControlServer` → `StudioModel`，使用临时项目库，见 `Tests/FocusStudioAppRegression/MCPEndToEndRegression.swift`）。启动应用的逻辑也用替身启动器测过：多个调用只启动一次、启动失败、超时、已在运行。

但 **通过 LaunchServices 真正打开 Focus Studio.app** 的环节只能在有图形界面的会话里手动验证：后台启动、不抢焦点、窗口出现、批准面板、应用退出后再次启动。本文说明怎么验证。

## 开始前

- 应用没有“临时项目库”开关，下面的步骤会使用 **真实的项目库**（`~/Library/Application Support/FocusStudio`）和 **真实的偏好设置**（批准列表）。建议在一个单独的 macOS 测试用户下验证；否则验证完后到“设置 › AI 工具”里撤销测试时批准的客户端。
- 构建本次的应用：`FOCUS_STUDIO_ARCHS=native ./scripts/build-app.sh`。下文用到：

```sh
APP="$PWD/dist/Focus Studio.app"
HELPER="$APP/Contents/MacOS/focus-studio-mcp"
```

- 需要看到 helper 在做什么时，加上 `FOCUS_STUDIO_MCP_LOG_LEVEL=debug`，日志写到 stderr（连接、启动、hello、每个调用）。

### 一个可以手动发消息的 MCP 会话

helper 在 stdin 关闭后就会退出，所以用一个命名管道让会话保持打开：

```sh
QA="$(mktemp -d)"
mkfifo "$QA/in"
FOCUS_STUDIO_MCP_LOG_LEVEL=debug "$HELPER" < "$QA/in" > "$QA/out" 2> "$QA/log" &
exec 3> "$QA/in"
send() { print -r -- "$1" >&3; }
send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"claude-code","version":"qa"}}}'
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
# 另开一个终端看输出：tail -f "$QA/out"  和  tail -f "$QA/log"
```

结束会话：`exec 3>&-`（helper 随即退出），然后 `rm -rf "$QA"`。

## 1. 只列工具不启动应用

1. 退出 Focus Studio，确认 `pgrep -x FocusStudio` 没有输出。
2. `send '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'`

期望：`$QA/out` 里返回 24 个工具（与 `Tests/MCPTests/v1-tools.txt` 一致）；`pgrep -x FocusStudio` 仍然没有输出，Dock 里没有 Focus Studio。

## 2. 第一次调用时在后台启动应用

1. 应用仍未运行。键盘焦点留在终端里。
2. `send '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_status","arguments":{},"_meta":{"progressToken":"qa"}}}'`

期望：

- Focus Studio 出现在 Dock 里，但 **不会** 变成前台应用：菜单栏还是终端的，继续打字仍然进入终端。
- 主窗口被创建，可能位于其他窗口后面。
- `ps -o ppid= -p "$(pgrep -x FocusStudio)"` 输出 `1`：应用由 launchd 启动，不是 helper 的子进程，所以录屏权限仍属于 Focus Studio 自己。
- 会弹出批准面板。外部调用只在这里和第 9 节的声音询问时激活应用（声音询问回答后焦点回到原应用）。面板显示客户端自报的名字（Claude Code），以及启动 helper 的程序路径（这里是运行管道的 shell，例如 `/bin/zsh`）。shell、node、python 这类程序会运行许多不同的程序，所以面板上用橙色写明 “zsh runs many programs, so this approval lasts only until this AI tool disconnects.”：这次批准只对这一个 helper 连接有效，不会记住，也不会出现在“设置 › AI 工具”的已批准列表里（node/python 运行某个脚本时，批准按“解释器 + 脚本路径”记住，面板上会多一行 “Script: …”）。
- 等待期间，`$QA/out` 里有 `notifications/progress`：数值很小且递增，消息依次是 “Opening Focus Studio in the background…”、“Waiting for Focus Studio to load its library…”；显示批准面板时是 “Waiting for the person to allow Claude Code in Focus Studio…”。
- 点 **允许** 后，调用返回 `structuredContent`（项目数、录制状态、权限）。在同一个会话里再调用一次不会再弹出面板。打开“设置 › AI 工具”：已批准列表里 **没有** zsh。

请记录：从发出调用到返回用了多久（冷启动加上加载项目库，应在 30 秒以内），以及批准面板上显示的程序。

可选（约 4 分钟）：结束会话、重新开一个（shell 的批准只对一个连接有效），发出 `get_status` 后不理会批准面板。期望：面板自己的 2 分钟超时先到，调用返回 `isError`，说明没人回答（“nobody answered within 120 seconds”），面板仍然开着；再发一次 `get_status` 并继续不理会，它加入同一个面板。调用的时间（从到达应用算起约 200 秒，扣除 helper 启动应用和连接的时间）先用完时返回的则是 `structuredContent.status` 为 `waiting_for_approval` 的 `isError`（`scripts/test.sh` 用缩短的时间覆盖了这种情况）；之后点 **允许**，下一次调用立即执行。

## 3. 编辑时窗口可见但不抢焦点

1. `send '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_projects","arguments":{"limit":1}}}'`，从结果里取一个 `project_id`。
2. 把 Focus Studio 的窗口放到其他窗口后面，或用 ⌘W 关掉所有窗口（应用继续运行）。
3. 用这个 `project_id` 调用 `add_zoom`，例如 `"arguments":{"project_id":"…","start":1,"end":2,"x":0.5,"y":0.5}`。

期望：主窗口回到最前（窗口都关了的话会新开一个），编辑器里打开的就是这个项目，新的缩放能在时间线上看到；键盘焦点仍在终端。编辑器顶部工具栏的按钮不被 “Claude Code is working…” 提示挡住（提示在工具栏下方，点击会穿过它）。验证完后可以在编辑器里删掉这个缩放。

再验证隐藏和最小化：

4. 在 Focus Studio 里按 ⌘H 隐藏应用，然后用同一个 `project_id` 连续调用两次 `add_zoom`。期望：应用重新显示但不变成前台应用，**始终只有一个** 主窗口（`osascript -e 'tell application "System Events" to count windows of process "FocusStudio"'` 在调用前后结果相同），没有叠出第二个编辑器。
5. 把主窗口最小化到 Dock，再调用一次 `add_zoom`。期望：窗口从 Dock 恢复，并且恢复后位于其他应用窗口的前面（不是被压在后面）；键盘焦点仍在终端。

## 4. 应用中途退出，下次调用再次启动

1. 对一个较长的项目调用 `export_project`（例如 `"arguments":{"project_id":"…","path":"/tmp/fs-qa-export.mp4"}`）。
2. 导出过程中用 ⌘Q 退出 Focus Studio。

期望：这次调用返回 `isError`，文字以 “Focus Studio quit before export_project finished; check get_status/list_projects” 开头，而且没有自动重试。应用在几秒内退出，导出目标文件夹里没有留下 `.fs-qa-export-….partial.mp4` 之类的隐藏临时文件（`ls -la /tmp | grep partial`）。接着 `send` 一个 `get_status`：应用再次在后台启动（不抢焦点），调用成功。因为这个会话的 helper 是 shell 启动的，重新连接后会再弹出一次批准面板；用真实客户端（第 8 节）时不会再弹出。

## 5. `FOCUS_STUDIO_MCP_NO_LAUNCH=1`

退出应用，按上面的方法开一个会话，但用 `FOCUS_STUDIO_MCP_NO_LAUNCH=1 "$HELPER"` 启动 helper，然后调用 `get_status`。

期望：返回 `isError` “Focus Studio could not be reached … started with FOCUS_STUDIO_MCP_NO_LAUNCH=1, so it does not open it”，应用没有启动。

### 关闭 “允许 AI 工具控制 Focus Studio” 时不启动应用

1. 打开 Focus Studio，在“设置 › AI 工具”里关掉 “Allow AI tools to control Focus Studio”。开关下方的状态应变成 “AI tools are turned off. Focus Studio refuses their calls.”（中文界面：“已关闭 AI 工具控制，Focus Studio 会拒绝它们的调用。”），而不是 “Ready for AI tools.”。
2. 退出 Focus Studio，用正常的会话（不设 `FOCUS_STUDIO_MCP_NO_LAUNCH`）调用 `get_status`。

期望：立即返回 `isError` “Focus Studio is set not to accept AI tools, so get_status did not run …”，应用 **没有** 启动，Dock 里没有 Focus Studio。验证完后打开应用，把开关重新打开。

## 6. 多个副本

- 同时装有别的副本时（例如 `/Applications/Focus Studio.app`，bundle id 相同）：退出所有副本，再用 `dist/` 里的 helper 发起调用。期望启动的是 `dist/` 里的副本：`ps -o command= -p "$(pgrep -x FocusStudio)"` 显示的路径在 `dist/` 下。helper 按 bundle URL 启动，并且只在没有别的副本运行时才启动自己的副本。
- 另一个副本正在运行，但它没有控制通道（1.11.0 及更早的版本）时：helper **不会** 再启动自己的副本（两个副本会同时编辑同一个项目库）。它等待最多 30 秒，看那个副本是否开始提供 AI 工具，然后返回 `isError` “Another copy of Focus Studio (<路径>, version <版本>) is running but is not accepting AI tools … Ask the person to quit that copy of Focus Studio (or to update it)”。Dock 里始终只有一个 Focus Studio。
- 另一个副本正在运行，并且已经在提供 AI 工具时：helper 直接连接它（协议相同即可），不会再启动新的副本。协议不同时，调用返回 `isError`，说明正在运行的是哪个副本（路径和版本）。

## 7. Gatekeeper：从 DMG 首次安装

从 DMG 安装一个从未打开过的副本（它带隔离属性），然后由 helper 触发启动。期望 macOS 弹出是否打开的确认框。如果 30 秒内没有处理，调用返回 `isError`，其中包含 “macOS may be asking the person whether to open it”。确认打开后再调用一次，应该成功。

## 8. 真实客户端

1. 设置 › AI 工具 › 接入 AI 工具，对 Claude Code 和 Codex 分别点“接入”（Connect）。每个客户端下方的命令应以找到的命令行工具的完整路径开头（例如 `/Applications/ChatGPT.app/Contents/Resources/codex`，和“Uses …”一行一致），找不到时才是 `claude` / `codex`；找不到命令行工具时，点“拷贝命令”，把界面上显示的命令粘贴到终端执行。
2. 退出 Focus Studio。在 Claude Code 里运行 `/mcp`，确认 `focus-studio` 已连接；这一步不应启动应用。
3. 让 Claude Code “用 Focus Studio 看一下状态”。期望：应用在后台启动，弹出批准面板，面板上是 Claude Code 和它的可执行文件路径；允许之后返回结果。
4. 用 Codex 重复一遍（`codex mcp list` 确认已连接）。
5. 验证结束后，在“设置 › AI 工具”里撤销这两个测试时批准的客户端（如果不是在单独的测试用户下验证的话）。

## 9. 通过 MCP 录制

`zsh scripts/test.sh` 用脚本化的采集和手动时钟覆盖了录制流程（`Tests/FocusStudioAppRegression/RecordingSessionRegression.swift`）：倒计时、从第一帧算起的 `duration`、暂停（暂停的时间不计入 `duration`，`get_status` / `wait_for_recording` 报告 `paused`，暂停中也能停止和丢弃）、自动停止与“结束”/`stop_recording`/`wait_for_recording` 共用一次停止、选项只对本次录制有效、等待期间 `get_status` 照常返回、取消，以及用脚本化的声音询问走完仅本次允许、无声录制（录制器本来打开的声音也不录）、取消录制、60 秒无回答、期间关闭 AI 工具或应用内助手开始工作、询问期间在录制器里关掉声音、调用被取消、不需要询问的情况和询问超过调用时间时转为后台任务；也用脚本化的 macOS 麦克风权限（状态和授权对话框都是假的）覆盖了倒计时之前的麦克风权限确认：从没问过时允许 / 不允许、之前已关闭、受限、60 秒无回答（之后的回答不再开始录制）、调用被取消、等待期间关闭 AI 工具、录制器本来开着的麦克风、等待超过调用时间时转为后台任务，以及你自己点录制和应用内助手在倒计时之前等 macOS 的回答。真实的 ScreenCaptureKit 时序（包括暂停和继续的分段）、声音询问面板、macOS 真正的麦克风授权对话框和录制控制条的外观只能手动验证（麦克风授权见第 9 步）。这一节会真的录屏，并在项目库里新建项目，验证完后可以删掉；需要已授予屏幕录制权限。

1. 让终端保持前台（Focus Studio 在后台，或被其他窗口挡住）。确认录制器里“系统音频”和“麦克风”都是关闭的（默认如此）。
2. `send '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"start_recording","arguments":{"source":"display","duration":8,"system_audio":true},"_meta":{"progressToken":"rec"}}}'`

   期望：
   - 倒计时之前先弹出声音询问 **Record sound? / 录制声音？**（Focus Studio 这时被切到前台）：扬声器图标，标题 ““Claude Code” wants to record system audio / “Claude Code”想录制系统音频”，下面一行 “Started by zsh / 启动它的程序：zsh”（与批准面板上的程序相同），写明要录制的来源、“Record without sound” 只录画面不录任何声音，以及“60 秒内没有回答就不会录制”；按钮 **Cancel recording / 取消录制**、**Record without sound / 无声录制**、**Allow for this recording / 仅本次允许**，没有蓝色的默认按钮。等待期间 `$QA/out` 里每 5 秒左右有一条递增的 `notifications/progress`（数值 0.01 以上，消息 “Waiting for the person to answer Focus Studio's sound prompt…”）。点 **仅本次允许**：面板关闭，键盘焦点回到终端，然后才开始倒计时。
   - 每个显示器底部居中的录制控制条显示倒计时（3、2、1，带“取消”）：✦ 旁是客户端名，悬停提示 “<客户端名> asked to record <来源>”，黄色扬声器图标的悬停提示是 “Recording system audio”；展开控制条（⌃）可以看到整句说明。键盘焦点仍在终端，菜单栏仍是终端的，主窗口没有被提到前面。倒计时结束后控制条保持收起的录制条，计时旁的计时器图标显示剩余录制时间（0:08），逐秒减少，并有扬声器图标；“暂停”、“结束”和 ✕ 可用。
   - 调用在倒计时结束、录制真正开始后就返回（点允许之后约 3–4 秒，而不是 11 秒），`structuredContent` 为 `state: "recording"`，带 `started_at`、`duration: 8`、比 `started_at` 晚 8 秒的 `auto_stop_at`，以及 `audio_consent: {asked: ["system_audio"], answer: "allowed"}`。
   - 录下的视频里看不到倒计时条和控制条（显示器录制排除 Focus Studio 的所有窗口，包括之后新开的）。
   - 录制器里的“系统音频”开关没有被打开：调用的选项只对这一次录制有效。
3. 立即 `send` 一个 `wait_for_recording`（`"arguments":{"timeout_seconds":60}`，带 `_meta.progressToken`）。等待期间 `send` 一个 `get_status`：它马上返回，`recording.state` 为 `recording`，`remaining` 递减。再 `send` 一个 `list_recording_sources`：它返回来源列表，Focus Studio 的主窗口不会被提到终端前面。

   期望：从录制真正开始算起录满约 8 秒后自动停止，和点“结束”一样保存项目并打开编辑器；`wait_for_recording` 返回 `state: "finished"` 和 `project_id`，等待期间有递增的 `notifications/progress`；项目时长约 8 秒，不含倒计时。
4. 再 `start_recording`（不带 `duration`），录制中点控制条上的 ✕，再点 **Discard / 丢弃** 确认，然后 `send` 一个 `wait_for_recording`。期望：返回 `state: "idle"`，`last_recording.state` 为 `cancelled`；项目库里没有新项目，录下的文件在废纸篓里。录制中先发 `wait_for_recording` 再丢弃时，它返回 `state: "cancelled"`。
   - 暂停：`start_recording` 带 `"duration":8`，录制约 3 秒后点控制条的“暂停”，等 10 秒。期间 `get_status` 返回 `recording.paused: true`，`elapsed` 和 `remaining` 不变；`wait_for_recording`（`timeout_seconds` 为 1）返回 `state: "recording"`、`paused: true`，没有 `auto_stop_at`。点“继续”后再录约 5 秒自动停止；项目时长约 8 秒，不含暂停的 10 秒。再录一次，暂停中 `stop_recording`，返回 `state: "finished"`。
5. 再 `start_recording`，倒计时期间点控制条上的“取消”。期望：调用返回 `isError`，说明倒计时被取消；没有开始录制。
6. 再 `start_recording`，倒计时结束前 `send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":<这次调用的 id>}}'`。期望：倒计时消失，没有开始录制，录制器显示出来。
7. 关闭 Focus Studio 的主窗口（应用继续运行），再 `start_recording` 一次：控制条照样在每个显示器底部显示倒计时和录制条。然后 `stop_recording`，返回 `state: "finished"`；主窗口不会在停止前被提到前面，停止后应用也不会被激活（键盘焦点仍在终端）。在控制条上自己点“结束”时，Focus Studio 才会被带到前面并显示编辑器；应用内 AI 助手的 `stop_recording`（确认之后）和它开始的录制到时自动停止，也会这样把编辑器带到前面。
8. 声音询问的其他回答（每次都用 `"microphone":true`；Focus Studio 还没问过麦克风权限时，macOS 的授权对话框会在声音询问之后、倒计时之前出现，按需允许，详见第 9 步）：
   - 点 **无声录制**：照常倒计时并录制，控制条上没有麦克风图标；结果里 `options.microphone` 为 `false`，`audio_consent.answer` 为 `"without_sound"`，文字说明对方选择了无声录制。录下的视频没有音轨（或只有静音）。之后 `stop_recording`。
   - 按 **Esc**（或点 **取消录制**、关闭面板）：没有倒计时，调用返回 `isError`，文字以 “The person did not allow sound” 开头，写明对方选了 Cancel recording。
   - 不理会面板 60 秒：面板自动关闭，调用返回 `isError`，说明 60 秒内没人回答；之后再点任何地方都不会开始录制。
   - 面板开着时在另一个应用里按回车：面板没有反应（没有默认按钮）。
   - 在录制器里打开“系统音频”，再用 `"microphone":true` 调用，点 **无声录制**：询问只提到麦克风；录下的视频没有任何声音（系统音频这次也不录），结果里 `options.microphone` 和 `options.system_audio` 都是 `false`。录完后关掉“系统音频”。
   - 在录制器里打开“麦克风”，用 `"microphone":true,"system_audio":true` 调用：询问只提到系统音频；面板开着时在录制器里关掉“麦克风”，再点 **仅本次允许**：录下的视频有系统音频、没有麦克风，结果里 `options.microphone` 为 `false`，文字说明对方在录制前关掉了麦克风。
   - 在录制器里打开“麦克风”，再用 `"microphone":true` 调用：不弹询问，直接倒计时；录完后关掉“麦克风”。不带 `microphone`/`system_audio` 的调用也不弹询问。
   - 录制器里的“系统音频”“麦克风”开关始终是你自己设的样子，没有被任何回答改动。
9. macOS 的麦克风权限（1.12.0 实机检查发现：第一次录麦克风时 macOS 的授权对话框出现在倒计时之后、录制已经开始时，现在改为倒计时之前）。这一步要重置 Focus Studio 的麦克风授权，建议在单独的测试用户下做；做完后到 **系统设置 › 隐私与安全性 › 麦克风** 把 Focus Studio 恢复成原来的设置。重置：退出 Focus Studio，运行 `tccutil reset Microphone com.local.focusstudio`（只重置 Focus Studio 这一项）。
   - 重置后，录制器里的“麦克风”保持关闭，`send` 一个 `start_recording`（`"arguments":{"source":"display","duration":5,"microphone":true}`，带 `_meta.progressToken`）。期望：先出现声音询问，点 **仅本次允许**；随后 macOS 的麦克风授权对话框出现，这时控制条还没有倒计时；等待期间 `$QA/out` 里每 5 秒左右有一条递增的 `notifications/progress`（数值 0.02 以上，消息 “Waiting for the person to answer macOS's microphone access prompt for Focus Studio…”）。在 macOS 对话框里点允许之后才开始 3 秒倒计时；调用在录制开始后返回，文字里有 “Before the countdown, macOS asked the person whether Focus Studio may use the microphone, and they allowed it.”。录下的视频里没有 macOS 的对话框，麦克风的声音从头开始，时长约 5 秒。
   - 在 **系统设置 › 隐私与安全性 › 麦克风** 里关掉 Focus Studio，再用同样的参数调用一次并点 **仅本次允许**：不出现 macOS 对话框，也没有倒计时；调用立即返回 `isError`，文字说明 Focus Studio 的麦克风权限已在 System Settings › Privacy & Security › Microphone 里关闭、可以用 `microphone` 为 `false` 重试，`structuredContent` 为 `status: "microphone_unavailable"`、`microphone_access: "denied"`、`asked_now: false`、`retry_with: {microphone: false}`。改用 `"microphone":false` 再调用：不询问，正常录制（没有麦克风声音）。录制器里打开“麦克风”、不带 `microphone` 调用：同样返回 `microphone_unavailable`。
   - 重置后调用，在 macOS 对话框里点不允许：没有倒计时，返回 `isError`，文字说明对方选了 Don't Allow，`asked_now` 为 `true`。
   - 重置后调用，不理会 macOS 对话框 60 秒：调用返回 `isError`（“nobody answered its dialog within 60 seconds”，`microphone_access` 为 `"not_determined"`）；这时再在对话框里点允许，不会开始倒计时或录制。
   - 重置后在录制器里打开“麦克风”，自己点录制：macOS 对话框在倒计时之前出现，回答（允许或不允许）之后才开始倒计时，之后和以前一样录制。

## 开发构建的 helper

用 `swift build` 构建出来的 helper 不在 .app 里面，所以需要设置 `FOCUS_STUDIO_APP_PATH="$APP"` 才知道要启动哪个应用；这个变量必须指向 bundle id 为 `com.local.focusstudio` 的 .app。只有开发构建会把 `FOCUS_STUDIO_CONTROL_SOCKET` 传给它启动的应用，其他环境变量都不传。release 构建的 helper 什么环境变量都不传：如果它自己设置了 `FOCUS_STUDIO_CONTROL_SOCKET`，它启动的应用仍然监听默认路径，这时调用会在 30 秒后返回说明原因的 `isError`。

## 记录模板

| 检查 | 结果 | 备注 |
| --- | --- | --- |
| 1 只列工具不启动 | | |
| 2 后台启动、不抢焦点、ppid 为 1、批准面板（shell 只批准本次连接）、进度 | | 耗时： |
| 3 编辑时窗口可见、不抢焦点、无窗口时新开；隐藏时不多开窗口；最小化后恢复到最前 | | |
| 4 中途退出返回 isError，不重试，不留临时文件；再次启动 | | |
| 5 NO_LAUNCH；开关关闭时不启动应用 | | |
| 6 多副本 | | |
| 7 Gatekeeper | | |
| 8 Claude Code / Codex | | |
| 9 MCP 录制：声音询问（写明启动它的程序；仅本次允许/无声录制（不录任何声音）/取消录制/Esc/60 秒无回答/无默认按钮/不需要时不问，询问期间关掉的声音不录，录制器设置不变，回答后焦点回到原应用）、macOS 麦克风授权在倒计时之前（允许后才倒计时、已关闭时返回 microphone_unavailable、不允许、60 秒无回答、自己点录制）、控制条倒计时不抢焦点、说明谁请求录制和录哪些声音、没有主窗口时也出现、录制中主窗口不被提前、录制开始即返回、剩余时间、暂停不计入 duration、duration 自动停止、wait_for_recording、各种取消、不进视频 | | |

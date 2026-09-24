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

期望：`$QA/out` 里返回 23 个工具；`pgrep -x FocusStudio` 仍然没有输出，Dock 里没有 Focus Studio。

## 2. 第一次调用时在后台启动应用

1. 应用仍未运行。键盘焦点留在终端里。
2. `send '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_status","arguments":{},"_meta":{"progressToken":"qa"}}}'`

期望：

- Focus Studio 出现在 Dock 里，但 **不会** 变成前台应用：菜单栏还是终端的，继续打字仍然进入终端。
- 主窗口被创建，可能位于其他窗口后面。
- `ps -o ppid= -p "$(pgrep -x FocusStudio)"` 输出 `1`：应用由 launchd 启动，不是 helper 的子进程，所以录屏权限仍属于 Focus Studio 自己。
- 会弹出批准面板。这是唯一允许激活应用的时刻。面板显示客户端自报的名字（Claude Code），以及启动 helper 的程序路径（这里是运行管道的 shell，例如 `/bin/zsh`）。shell、node、python 这类程序会运行许多不同的程序，所以面板上用橙色写明 “zsh runs many programs, so this approval lasts only until this AI tool disconnects.”：这次批准只对这一个 helper 连接有效，不会记住，也不会出现在“设置 › AI 工具”的已批准列表里（node/python 运行某个脚本时，批准按“解释器 + 脚本路径”记住，面板上会多一行 “Script: …”）。
- 等待期间，`$QA/out` 里有 `notifications/progress`：数值很小且递增，消息依次是 “Opening Focus Studio in the background…”、“Waiting for Focus Studio to load its library…”；显示批准面板时是 “Waiting for the person to allow Claude Code in Focus Studio…”。
- 点 **允许** 后，调用返回 `structuredContent`（项目数、录制状态、权限）。在同一个会话里再调用一次不会再弹出面板。打开“设置 › AI 工具”：已批准列表里 **没有** zsh。

请记录：从发出调用到返回用了多久（冷启动加上加载项目库，应在 30 秒以内），以及批准面板上显示的程序。

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
- 另一个副本正在运行，但它没有控制通道（1.4.0 及更早的版本）时：helper **不会** 再启动自己的副本（两个副本会同时编辑同一个项目库）。它等待最多 30 秒，看那个副本是否开始提供 AI 工具，然后返回 `isError` “Another copy of Focus Studio (<路径>, version <版本>) is running but is not accepting AI tools … Ask the person to quit that copy of Focus Studio (or to update it)”。Dock 里始终只有一个 Focus Studio。
- 另一个副本正在运行，并且已经在提供 AI 工具时：helper 直接连接它（协议相同即可），不会再启动新的副本。协议不同时，调用返回 `isError`，说明正在运行的是哪个副本（路径和版本）。

## 7. Gatekeeper：从 DMG 首次安装

从 DMG 安装一个从未打开过的副本（它带隔离属性），然后由 helper 触发启动。期望 macOS 弹出是否打开的确认框。如果 30 秒内没有处理，调用返回 `isError`，其中包含 “macOS may be asking the person whether to open it”。确认打开后再调用一次，应该成功。

## 8. 真实客户端

1. 设置 › AI 工具 › 连接到 Claude Code / 连接到 Codex（找不到命令行工具时，复制界面上显示的命令手动执行）。
2. 退出 Focus Studio。在 Claude Code 里运行 `/mcp`，确认 `focus-studio` 已连接；这一步不应启动应用。
3. 让 Claude Code “用 Focus Studio 看一下状态”。期望：应用在后台启动，弹出批准面板，面板上是 Claude Code 和它的可执行文件路径；允许之后返回结果。
4. 用 Codex 重复一遍（`codex mcp list` 确认已连接）。
5. 验证结束后，在“设置 › AI 工具”里撤销这两个测试时批准的客户端（如果不是在单独的测试用户下验证的话）。

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

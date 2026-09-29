# 新用户连接 Codex

Focus Studio 有两种独立的连接：**应用内 AI 助手**使用 Codex 登录来理解你的指令；**外部 Codex**通过 Focus Studio 的本机 MCP 服务来操作录制、素材和剪辑。只用其中一种时，无需配置另一种。

## 先准备

1. 安装并打开 [ChatGPT 桌面应用或 Codex CLI](https://learn.chatgpt.com/docs/codex/cli)，登录 Codex。
2. 将 Focus Studio 安装到 `/Applications/Focus Studio.app`，从“应用程序”打开它。录屏权限仍由 Focus Studio 向 macOS 请求。

## 在 Focus Studio 中使用 AI 助手

1. 打开 **设置 → Codex**。页面会自动查找 Codex；正常情况下无需填写可执行文件路径。
2. 选择 **使用已有 Codex 登录**，或选择 **为 Focus Studio 单独登录**。后者需要先点 **连接并测试**，再点 **使用 ChatGPT 登录**；浏览器登录完成后返回应用。
3. 点 **连接并测试**。显示 **就绪** 后，可以在 AI 助手中发送请求。模型保持“账户默认”即可；只有需要指定模型时才展开“高级选项”。

若没有自动找到 Codex，可在“高级选项”中选取安装的应用或可执行文件。新版 ChatGPT.app 的 Codex CLI 可能位于 `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`，Focus Studio 会自动检测该位置。

## 让外部 Codex 控制 Focus Studio

1. 打开 **设置 → AI 工具**，开启 **允许 AI 工具控制 Focus Studio**，确认状态为“已准备好”。
2. 在 **接入 AI 工具** 的 **Codex** 行点 **接入**。Focus Studio 用 Codex 自己的 `mcp add` 命令登记随应用提供的 `focus-studio-mcp`，不会覆盖其它 MCP 服务器。若显示“已接入另一个副本”，点 **更新**。
3. 新开一个 Codex 会话。首次调用 Focus Studio 工具时，在 Focus Studio 弹出的面板中审阅并批准；此后可让 Codex 先调用 `get_status` 或 `list_projects` 查看状态，再执行录制或剪辑。

可以在终端用 `codex mcp list` 检查登记，在 Codex 中用 `/mcp` 查看已连接工具。若自动接入不可用，展开页面中的“手动配置”，复制针对当前安装位置生成的命令。官方的 [Codex MCP 说明](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) 介绍了桌面应用、CLI 和 IDE 扩展共用的本地配置。

**两种“已连接”含义不同：**“设置 → Codex”的就绪状态表示应用内 AI 助手可使用 Codex 账户；“设置 → AI 工具”的已接入表示外部 Codex 知道 Focus Studio 的 MCP 地址。`codex mcp list` 只验证配置已登记；工具能否执行还取决于 Focus Studio 正在运行的版本、AI 工具总开关以及首次调用的批准结果。

# Focus Studio 1.5.0（build 9）验证记录

本次范围：通过 MCP 让 Claude Code、Codex 直接使用 Focus Studio（GitHub issue #1，M1–M7）。应用内附带的 `Contents/MacOS/focus-studio-mcp`（官方 MCP Swift SDK 0.12.1，stdio）经本机 Unix socket 控制通道连接应用；应用没在运行时在后台启动它；新的 AI 工具第一次调用时需要用户批准；设置新增 **AI 工具** 页（总开关、已批准列表、一键接入 Claude Code / Codex）；24 个 MCP 工具（`Tests/MCPTests/v1-tools.txt`），编辑按 `project_id` 在编辑器里前台可见地进行；录制开始即返回，支持 `duration` 和 `wait_for_recording`，外部发起的录制显示悬浮倒计时和剩余时间。另含 M1 的工具加固（导出不覆盖原始录像、编辑被丢弃时报错、导出宽度与帧率、原子读改写、项目库加载完成后才算启动完成、停止录制只执行一次、缺少录屏权限时如实报告）。验证机器：Apple Silicon、macOS 26.5.2、Swift 6.1（Xcode 工具链）。

第二轮（2026-09-24 中午，同一候选版本号重新构建）追加三项：

1. **录声音先征得同意**：外部（MCP）`start_recording` 要打开录制器里没有打开的麦克风或系统音频时，倒计时之前弹出 **Record sound? / 录制声音？**（`AutomationAudioConsentPanel`，风格同批准面板，中英文），写明 AI 工具名称、要录的声音和来源；按钮 **Allow for this recording / 仅本次允许**、**Record without sound / 无声录制**、**Cancel recording / 取消录制**，Esc 与关闭面板等同取消，没有默认按钮。允许：按要求录制；无声录制：把这些声音关掉后照常录制，结果的文字和 `structuredContent.audio_consent`（`asked`、`answer: "without_sound"`）与 `options` 都写明；取消或 60 秒无回答：面板关闭，不录制，返回 `isError`（“The person did not allow sound…”）。每次都问、不记住，不改录制器设置；不额外加声音的录制和应用内助手不询问。等待期间每 5 秒发一次递增的心跳进度（0.01 起，高于批准面板的心跳）。回答后若 AI 工具已被关闭/撤销，或应用内助手开始工作、编辑器在导出、有对话框，仍然拒绝。
2. **调用时间从到达应用算起**：helper 在 `call` 里附带自己已经花掉的秒数（`elapsed`，从收到 `tools/call` 起算：启动应用、连接、hello），应用把“到达时间减去 `elapsed`”作为这次调用的起点。约 200 秒的转后台阈值、批准面板的等待（面板未回答、时间先到时返回 `isError` + `structuredContent.status: "waiting_for_approval"`、`retry: true`，面板保留，重试加入同一面板）、排队和声音询问（在任务内部，到时转为 `job_id`，运行状态的 `activity` 写明“waiting for the person to answer Focus Studio's sound prompt”）都按这个起点计算；`wait_for_recording`、`wait_for_job` 这类自带等待上限的调用改为从起点算最多 240 秒。`elapsed` 是可选字段，控制协议仍为 1：旧应用忽略它，旧 helper 不发送时按 0 计；应用把它截断在 0–600 秒。
3. **文档复核的文字修正**：server instructions 不再说所有编辑/输出工具都会打开项目（写明 `get_project`、`list_assets`、`assemble_video` 不打开），并加入声音询问和 `waiting_for_approval`，共 1,991 个 UTF-16 单位；`wait_for_recording` 的描述列出超时时可能返回的 `countdown` / `recording` / `stopping`，以及 `finished` / `cancelled` / `idle`（`last_recording`）；设置页的可复制命令改用找到的命令行工具完整路径（按需 shell 引号），找不到时才用 `claude` / `codex`。

第三轮（2026-09-24 下午，同一候选版本号重新构建）修正复核确认的问题：

1. **无声录制不录任何声音**：面板写的是“只录制画面”，第二轮却只关掉询问的那种声音，录制器里本来打开的声音（例如系统音频）照样录。现在选 **无声录制** 时麦克风和系统音频都关闭（结果的 `options` 两者都是 `false`，`audio_consent.asked` 仍只列出问过的声音），面板说明改为 ““Record without sound” records the screen only, with no sound at all. / 选择“无声录制”只录制画面，不录任何声音。”；给模型的文字、`start_recording` 的描述、README、INSTALL、skill 同步。取消、无回答和无法询问时给模型的提示改为“`microphone` 和 `system_audio` 为 false 时只录画面”（第二轮写“不带这两个参数就只录画面”，录制器开着声音时不对）。
2. **询问期间在录制器里关掉的声音不会被录**：第二轮在询问前读取录制器的声音设置，开始录制时才套用；AI 要求的某种声音若因录制器当时已打开而没有被问到，之后在询问期间被关掉，仍会被录（`true` 覆盖录制器的关闭）。现在在调用 `startRecording` 的同一次主线程操作里重新读取录制器：没有被这次询问允许的声音，只有录制器此刻仍打开时才录，否则关闭；结果的 `options` 写明实际录什么，文字说明原因（“the person turned it off in their recorder settings before the recording started”）。
3. **排队也按调用的时间截止**：第二轮只给批准面板的等待设了截止时间，排队（等另一个改变界面的调用让出）没有；批准得晚的调用可能排在一个更晚到达、要到它自己的约 200 秒才让出的调用后面，第一次回答超过 300 秒。现在排队最多等到“调用起点 + 约 200 秒 + 最多 1 秒宽限”（`AutomationCallQueue.acquire(until:)`），到时不执行，返回 `isError` + `structuredContent: {status: "waiting_for_turn", tool, retry: true}`，模型再调用一次即可。选择返回可重试的结果而不是 `job_id`：此时什么都没有执行，与 `waiting_for_approval` 同理；若转为后台任务，工具会在模型不知情时晚些才改变界面，且被让出的队列位置需要另行管理。排队期间发送心跳进度（0.005 起，介于批准面板的心跳（最多约 0.0025）和声音询问的心跳（0.01 起）之间，同一调用的进度始终递增）。server instructions 加入 `waiting_for_turn`，现为 1,987 个 UTF-16 单位。控制协议仍为 1：这只是新的结果内容。
4. **声音询问写明实际启动 AI 工具的程序**：AI 工具自报的名称可以随意填写（例如自称 “Focus Studio”）。面板现在与批准面板一样显示 “Started by <程序> / 启动它的程序：<程序>”（`ControlServer` 把识别出的 `programName` 经 `AutomationBridge` 传给询问）。
5. **文档**：INSTALL、MCP-QA 和 `AutomationApprovalPanel` 的注释不再说批准面板是外部调用唯一会激活应用的时刻（声音询问也会，回答后焦点回到原应用）；README、INSTALL、skill 改为批准面板 2 分钟无人处理时返回“没人回答”的错误（默认设置下它先于 `waiting_for_approval` 到来，后者只在 helper 启动和连接用了很久时出现），并写明 `waiting_for_turn`；MCP-QA 第 9 节加入“启动它的程序”、录制器已开系统音频时的无声录制、询问期间关掉麦克风三项手动检查。本记录第二轮中两处超出测试实际覆盖的说法已在下表更正（`RecordingSessionRegression` 的“60 秒”、`ControlServerRegression` 的“被截断”）。
6. **测试补强**（见下表各行的“第三轮”）：上述每项修改都有回归测试；另补上 helper 的 `elapsed` 包含启动应用和等待 hello 的下限检查、声音询问回答后应用内助手开始工作时仍拒绝、声音询问默认 60 秒与目录描述一致、心跳区间的先后关系、服务端对 `elapsed` 的截断。新增的应用层断言都在临时副本里用变异验证过：去掉回答后的 `automationNavigationRefusal` 检查、去掉排队截止时间、`ControlServer` 不截断 `elapsed`、不传 `programName`、把声音询问心跳起点改为 0.000001，以及（`AIAssistantTests`）去掉开始录制时重新读取录制器、无声录制只关问过的声音，都会让对应测试失败。

## 自动化

`zsh scripts/test.sh` 第一轮完整运行三次（2026-09-24 01:51–01:53；文档复核修改后 02:31–02:36，全部修改完成后 02:38–02:43），第二轮的代码修改完成后又完整运行两次（12:03:47–12:06:39，重新构建和打包之后 12:10:42–12:13:39），第三轮的代码和测试修改完成后再完整运行一次（13:10:34–13:13:08），退出码都是 0。各项输出（以最后一次为准）：

| 检查 | 结果 |
| --- | --- |
| `swift build`（全部 target，含 `focus-studio-mcp` 与 MCP SDK 依赖） | 通过（有 Swift 6 语言模式下的并发警告，无错误） |
| `FocusStudioPermissionTests`（权限、启动、区域几何） | PASS |
| `FocusStudioE2E`（合成网格视频 → 点击 → 自动缩放 → 正式渲染管线导出，含章节字幕与音频） | PASS（960 × 540、24 fps、2 段缩放、音视频轨各 1） |
| `swift scripts/test-localization.swift` | PASS（第二轮 777 个键（新增声音询问面板的 9 个），中英一致，占位符一致；第三轮仍为 777 个键，改写了无声录制说明那一条） |
| `test-language-preferences.sh`（隔离的语言偏好，不改用户设置） | PASS |
| `test-app-regression.sh` → `ProjectLibraryRegression`（多选、重命名、移到废纸篓、过期绑定保护） | PASS |
| 同上 → `AssistantControlRegression`（被丢弃的编辑报错、导出目录保护、并发 bootstrap、停止只执行一次、缺少权限如实报告） | PASS |
| 同上 → `RecordingSessionRegression`（手动时钟下的倒计时与自动停止、`duration` 从第一帧计时、完成/取消与 `stop_recording` / `wait_for_recording` 共用一次停止、等待期间 `get_status` 不阻塞、选项只对本次录制有效、悬浮倒计时生命周期、录制中不把主窗口提到前面；第二轮：经 `AutomationBridge` 在真实 `StudioModel` 上用脚本化的声音询问录制一个区域来源——仅本次允许（采集带麦克风，询问写明 Claude Code、麦克风、来源和注入的等待时间（测试中 5 秒））、无声录制（采集和结果都不带声音，其他选项保留）、取消录制（没有倒计时和采集）、等待时不倒计时且心跳递增（0.01 起）、回答时总开关已关闭则拒绝、调用被取消时面板关闭、60 秒（测试中 0.3 秒）无回答时面板关闭且不录制、无声音/声音关闭/录制器已开的声音/应用内助手都不询问，每种情况录制器设置不变；询问的等待从调用到达算起转为后台任务（`activity` 写明在等声音询问），允许后 `wait_for_job` 返回录制结果；到达已久的 `wait_for_recording` 缩短到从到达算起的上限，无效的 `timeout_seconds` 仍被拒绝；第三轮：默认等待 60 秒且与 `start_recording` 描述一致，批准面板、排队、声音询问三段心跳的区间依次递增，询问写明启动它的程序，录制器已开系统音频时无声录制的采集和结果都不带任何声音、录制器设置不变，询问期间关掉录制器的麦克风后无论允许还是无声录制都不录麦克风） | PASS |
| 同上 → `AutomationBridgeRegression`（按 `project_id` 打开编辑器并保存、切换项目先保存、并行调用排队、录制中/忙碌/应用内助手工作时拒绝、隐藏和最小化窗口的恢复、导出进度、导入/截图/重命名/废纸篓、中文界面下仍返回英文结果、后台任务与 `wait_for_job`；第三轮：声音询问开着时应用内助手开始工作，之后点允许仍被拒绝、不倒计时、编辑器不变；比持有队列的调用更早到达的调用在约 1.1 秒（阈值 1 秒 + 宽限）返回 `waiting_for_turn`、工具没有执行、期间心跳递增且在批准与声音询问的心跳之间，再调用一次即执行） | PASS |
| 同上 → `ControlServerRegression`（hello 与协议版本、畸形消息、进度只在请求时发送、取消与断线取消工具、其他用户的连接被拒、socket 目录与文件权限、过期 socket 替换、批准允许/拒绝/超时/撤销/总开关、shell 与解释器按脚本或按连接批准；第二轮：调用时间从到达算起——面板未回答、1 秒的测试时限先到时约 1 秒内返回 `waiting_for_approval`（期间有心跳，面板保留），带 `elapsed: 0.8` 的调用约 0.2 秒返回，重试加入同一面板、允许后执行且不再询问，带 `elapsed: 0.6` 的慢工具约 0.4 秒转为后台任务，`elapsed` 为 10⁹ 时快速调用仍直接返回结果；第三轮：`elapsed` 为 −10⁹ 时按 0 计，慢工具约 1 秒转为后台任务；阈值 601 秒、面板未回答、`elapsed` 为 10⁹ 时按 600 秒计，约 1 秒后返回 `waiting_for_approval`（这两项才真正检查服务端的截断，第二轮的 10⁹ 用例不经过截断也会通过）；新客户端的 `start_recording`（带麦克风）经批准面板再到声音询问，同一调用的心跳始终递增，询问写明 Claude Code 和识别出的程序，取消录制后返回 `isError` 且没有录制） | PASS |
| 同上 → `MCPClientConnectorRegression`（假的 `claude` / `codex` 与登录 shell：PATH 查找、坏掉的安装被跳过、精确的 add/remove/get 参数、已接入不重复、另一副本先 remove 再 add、超时与错误文本、可复制命令（第二轮：以找到的命令行工具完整路径开头、含空格时加引号，找不到时用命令名）、临时位置/磁盘映像/缺少 helper 的提示） | PASS |
| 同上 → `MCPEndToEndRegression`（真实 `focus-studio-mcp` → `ControlServer` → `StudioModel`，临时项目库：initialize、tools/list、`get_status`、相对路径 `import_video`、`get_project`、`add_zoom`、`update_settings`、导出到客户端目录并发送进度通知（条数随耗时变化，第一轮最后一次 6 条，第二轮最后一次 2 条，第三轮 2 条）、`rename_project`、`list_projects`、`delete_project` 到测试废纸篓） | PASS |
| `FocusStudioAppRegression` 汇总（50 次打开/编辑/返回循环、自动保存、缩放计时等既有项目） | PASS |
| `bash scripts/test-codex-connection.sh`（fake codex） | PASS |
| `bash scripts/test-ai-gateway.sh` | PASS |
| `zsh scripts/test-ai-assistant.sh`（含自动化 API、MCP 目录与结果形状、后台任务、调用队列、录制会话；第二轮：假应用上的声音询问——允许、无声录制（只关掉询问的那种声音）、取消、无回答、期间被拒、调用取消、无法询问时拒绝、无需询问与应用内助手不询问、录制器设置不变；等待中的后台任务在 `activity` 里写明在等什么，回答后不再写；`wait_for_job` 从到达算起不超过 240 秒；instructions 不超过 2,000 个 UTF-16 单位且不再说所有输出工具都打开项目，`wait_for_recording` 描述列出全部状态；第三轮：无声录制不录任何声音（录制器已开的声音也不录，只问录制器没开的那种），询问期间录制器的麦克风被关掉时允许或无声录制都不录麦克风且文字说明原因，录制器本来开着的声音不询问，队列的截止时间（到时离开、之前轮到则取得、已过期立即返回、取消），instructions 与描述里的 `waiting_for_turn` 和 “no sound at all”） | PASS |
| `zsh scripts/test-mcp.sh` → `MCPTests`（v1 目录名称与保守的 schema、SDK 适配层、按协议版本映射结果、stdout 隔离、进度转发、协议握手、转发工作目录/客户端/版本/roots、取消、未知与未开放的工具、-32602 / -32600、控制通道帧与消息、helper 端转发器：调用、进度、应用中途退出、重连、协议不一致、打开应用、取消、关闭；第二轮：`call` 的可选 `elapsed`（往返、缺省按 0、负数/无穷/过大被截断、旧解码器跳过它、协议仍为 1），转发的调用带上 helper 已用的秒数（等了 3 秒的调用报告 3–5 秒）；第三轮：`elapsed` 包含后台启动应用的时间（应用 0.4 秒后才监听，三个调用都报告 ≥ 0.4 秒）和等待迟到 hello 的时间（≥ 0.6 秒）） | PASS |
| 同上 → `mcp_client.py`（开发构建的 helper，真实 stdio） | PASS（见下节；第二轮起还检查 fake-app 收到的每个 `call` 都带 0–5 秒的 `elapsed`；第三轮起 hello 迟到 2.5 秒时 `elapsed` 至少 2.4 秒） |
| 同上 → `mcp_client.py --handshake-only`（helper 放进最小的 Focus Studio.app，以及通过符号链接启动） | PASS，两次都报告 `serverInfo.version 1.5.0` |

所有 helper 测试都设置 `FOCUS_STUDIO_MCP_NO_LAUNCH=1` 和临时 socket，没有打开或连接真实的 Focus Studio；一键接入只针对假的命令行工具，没有改动本机的 Claude Code / Codex 配置。

## MCP 协议检查

- 协议版本协商：请求 2025-11-25、2025-06-18、2025-03-26、2024-11-05 时原样返回；请求未知的 2099-01-01 或过旧的 2024-10-07 时返回 2025-11-25。
- `tools/list` 返回 24 个工具，顺序和名称与 `Tests/MCPTests/v1-tools.txt` 一致；`generate_image`、`generate_video`、`wait`、`export_demo`、`reveal_in_finder`、`open_project`、`close_editor` 不开放，调用返回 -32602。server `instructions` 第三轮后为 1,987 个 UTF-16 单位（第一轮 1,978，第二轮 1,991），测试要求不超过 2,000，低于 Claude Code 截断的 2,048。
- 未知参数被拒绝；畸形参数 -32602；批量请求 -32600；resources / prompts -32601；`ping`、进度 token、取消、解析错误都按规范处理。
- helper 空闲时不轮询（2 秒内 0 次唤醒）；日志只写 stderr，stdout 只有 JSON-RPC；stdin 关闭后正常退出（空闲 0.01–0.02 s，管道输入 0.02–0.05 s）。
- 对假的应用（`Tests/MCPTests/fake-app.py`）：先 hello（带客户端和工作目录）、参数原样转发、单一连接、进度转发、取消只转发不重复回复、应用中途退出返回 `isError` 且不重试、重连、崩溃和不存在时返回“could not be reached”、协议不一致、hello 迟到时 2 次心跳、关闭时取消正在运行的调用并在 2.0 s 内退出。
- **打包后的 helper**：对解压 ZIP 得到的 `Focus Studio.app/Contents/MacOS/focus-studio-mcp`（release 构建）再完整运行一次 `mcp_client.py --expect-version 1.5.0`：PASS，结论同上（“没有应用路径”的启动设置用例只针对开发构建，按设计跳过；其余 2 个启动设置用例在打开任何应用前被拒绝）。运行期间用户正在使用的 `dist/Focus Studio.app`（pid 44438）没有被连接或重启。
- `verify-release.sh` 的 stdio 冒烟测试在候选应用和解压后的 ZIP 上，对 arm64 和 x86_64（Rosetta）两个切片都通过：`protocol 2025-11-25, focus-studio 1.5.0, 24 tools`。

## 文档核对

- 工具名：README、`docs/INSTALL.md`、`skills/focus-studio-mcp/SKILL.md` 中所有反引号里的工具名与参数名都用脚本对照了 `MCPToolCatalog.v1` 导出的目录（`.artifacts/mcp-tests/catalog.json`），没有未知名称；README 与 skill 列出全部 24 个工具。
- 命令：`claude mcp add --scope user focus-studio -- <helper>` 对照 Claude Code 2.1.278 的 `claude mcp add --help`（`-s, --scope <local|user|project>`，`--` 之后是命令）；`codex mcp add focus-studio -- <helper>` 对照 codex-cli 0.155.0-alpha.16 的 `codex mcp add --help`（`<NAME> (--url <URL> | -- <COMMAND>...)`）；两者与 `MCPClientKind.addArguments` 生成的参数一致。本机 npm 安装的 `codex` 缺少其平台二进制、无法运行，一键接入会跳过它并使用 ChatGPT.app 内置的 `codex`（`--version` 能运行的第一个候选）。
- Codex 超时：codex-rs 中 `DEFAULT_TOOL_TIMEOUT` 为 300 秒（openai/codex 41db093，“Increase default tool timeout to 300 seconds”；用 GitHub API 核对各 tag：rust-v0.140.0 为 120 秒，首个包含它的正式版 rust-v0.141.0（2026-06-18）为 300 秒，更老的 rust-v0.50.0 为 60 秒；官方配置文档仍写 60 秒）。本机 ChatGPT.app 内置的 codex-cli 0.155.0-alpha.16 在此之后。等待类工具最多 240 秒、导出约 200 秒后转为后台任务，均在 300 秒以内。第一轮时批准面板的等待（最多 120 秒）和冷启动的 launch / hello（各最多 30 秒）都发生在 `AutomationBridge` 开始计这 200 秒之前，而 Codex 的超时只在 elicitation 时暂停、进度通知不会重置它，新客户端的第一次调用可能超过 300 秒；第二轮改为从调用到达应用算起并扣除 helper 报告的 `elapsed`，批准、排队和声音询问都计入（见开头第 2 项），最坏情况是 helper 的 launch + hello（最多 60 秒，已计入）加应用内约 200 秒（外加最多 1 秒的宽限），第一次调用也在 300 秒内回答。第三轮补上了排队这一段：第二轮的排队没有截止时间，批准得晚的调用可能排在更晚到达的调用后面（例如起点 −20 秒、第 110 秒获批，而另一个客户端第 100 秒开始的导出要到第 300 秒才让出，第一次回答约在 321 秒）；现在排队到“起点 + 约 200 秒 + 宽限”就返回 `waiting_for_turn`。按默认设置，批准面板 2 分钟的时限（`AutomationAccessController.defaultTimeout`）通常先于调用的时间到来，所以 README、INSTALL、skill 改为以“没人回答”的错误为主，`waiting_for_approval` 只在 helper 启动和连接用了很久时出现。INSTALL 与 README 相应改写，并保留：更早的 Codex 请更新，或在 `~/.codex/config.toml` 的 `[mcp_servers.focus-studio]` 下设置 `tool_timeout_sec = 300`（codex-rs `McpServerConfig` 的字段，`codex mcp add` 不会写入）。
- 设置页文字：**AI tools / AI 工具**、**Allow AI tools to control Focus Studio / 允许 AI 工具控制 Focus Studio**、**Ready for AI tools. / 已准备好接受 AI 工具的调用。**、**Connect AI tools / 接入 AI 工具**、**Connect / 接入**、**Update / 更新**、**Copy command / 拷贝命令**、**Check again / 重新检查**、**Approved AI tools / 已批准的 AI 工具**、**Revoke / 撤销**、**Recently declined / 最近拒绝的**、批准面板 **Allow AI tool? / 允许 AI 工具？**、**Allow / 允许**、**Don't Allow / 不允许**，声音询问 **Record sound? / 录制声音？**、**Allow for this recording / 仅本次允许**、**Record without sound / 无声录制**、**Cancel recording / 取消录制**，均与 `AutomationSettingsView.swift`、`AutomationApprovalPanel.swift`、`AutomationAudioConsent.swift` 和两份 `Localizable.strings` 对照。声音询问面板另用离屏渲染（`NSHostingView` + `cacheDisplay`，临时目录中的构建，不启动应用）检查了中英文三种情况（麦克风、系统音频、两者）：文字不截断，三个按钮在 500 pt 宽的面板里一行放下，都不是默认按钮。`docs/MCP-QA.md` 第 8 节原写“连接到 Claude Code / 连接到 Codex”，已改为界面上的实际文字。
- 复核后修正的文档（只改文档，不涉及代码）：
  - 控制条按钮中文界面是 **Finish / 结束**（`"Finish" = "结束"`，“完成”对应 Done）；✕ 是“取消并删除本次录制”。INSTALL 原写“点完成结束”“每次录制都会进项目库”，README 也写“每次录制都进项目库”，改为“结束的录制都保存到项目库，取消的会被删除，没有静默录制”。
  - skill 的 `wait_for_recording` 补上 `idle`（录制在调用前已经结束，结果和 `project_id` 在 `last_recording` 里）和超时时的 `countdown` / `stopping`，对照 `WaitForRecordingTool` 与 `AIToolSupport.lastRecordingReport`；README 同步一句。
  - `assemble_video`、`list_assets` 在目录中是 `.projectReadOnly`、`requiresProjectID: false`：`project_id` 可选，只决定默认目录，不打开项目。README 和 skill 原来说所有“编辑和输出工具”都按 `project_id` 打开项目，已区分。
  - 一键接入能找到 ChatGPT.app / Codex.app 内置的 `codex`（`MCPClientKind.standardLocations`），但手动命令和设置页的可复制命令都以 `codex` 开头，而它不在 PATH 中：INSTALL 与 README 给出完整路径的写法。skill 中 Codex 的接入命令原为省略路径，已补全，并指向 **Copy command**。（第二轮起可复制命令本身改用找到的完整路径，见开头第 3 项；三份文档同步。）
  - helper 日志：Claude Code 2.1.278 只在连接阶段记录 stdio server 的 stderr；Codex 只向 stdio server 传一组固定的环境变量（`HOME`、`PATH` 等），以 info 级别记录 `MCP server stderr (…)`，`codex mcp add --env` 可以加变量。设置页的 **Update / 更新** 只比较 helper 路径，不会去掉 `--env`。INSTALL 改为在终端里按 `docs/MCP-QA.md` 直接运行 helper，或用 `--env` 重新登记 Codex、排查完再登记回来。
  - 修改后重新用脚本对照目录：三份文档反引号里的名称要么是 24 个工具之一或其参数，要么是核对过的结果字段（`idle`、`last_recording`、`started_at` 等）、未开放的工具或命令名。
- 构建要求：MCP SDK 及其依赖的清单要求 Swift 6（`swift-sdk` 为 6.0/6.1，`swift-nio` 等为 6.1），README 和 RELEASE 中的最低要求由 Swift 5.10 改为 Swift 6.1。
- `skills/install.sh` 用临时的 `CLAUDE_SKILLS_DIR` 验证了软链和 `--copy` 两种方式（5 个 skill + `_shared`），没有写入 `~/.claude/skills`。

## 安装包

`FOCUS_STUDIO_APP_DIR="$PWD/dist/candidates/1.5.0/Focus Studio.app" zsh scripts/build-app.sh`（Universal）与同一变量下的 `scripts/package-release.sh --skip-build` 通过。`package-release.sh` 读取 `FOCUS_STUDIO_APP_DIR`，打包的是候选应用；输出写入 `dist/releases/`（第一次打包前不存在），临时目录在结束时删除。`docs/INSTALL.md` 会被复制进 DMG / ZIP，复核修改后用同样的命令对未改动的候选应用重新打包（2026-09-24 02:30），只替换了第一次打包生成的 1.5.0 DMG / ZIP。第二轮的代码修改完成、`scripts/test.sh` 通过后，用同样的两条命令重新构建候选应用（2026-09-24 12:06:57–12:08:58，Universal，构建期间源码摘要不变）并重新打包（12:09，替换 `dist/releases/` 中的 1.5.0 DMG / ZIP / .sha256）。第三轮的修改完成、`scripts/test.sh` 通过后，再用同样的两条命令重新构建候选应用（13:13:44–13:15:12，Universal）并重新打包（13:15:20–13:15:35，替换 1.5.0 DMG / ZIP / .sha256）；下面的大小和校验和是第三轮的。用户正在运行的 `dist/Focus Studio.app`（pid 44438）始终没有被替换、连接或重启。

- 版本 1.5.0（build 9），arm64 + x86_64 Universal 2，macOS 15.0 最低系统版本；应用与 helper 都只链接 `/System/Library` 与 `/usr/lib` 下的系统库。
- helper `focus-studio-mcp`（17.7 MB，第三轮 17,732,848 字节（第二轮 17,705,680），两个架构）：签名标识 `com.local.focusstudio.mcp`，指定要求 `identifier "com.local.focusstudio.mcp"`，无 entitlements；应用签名标识 `com.local.focusstudio`；`codesign --verify --deep --strict` 通过。ad-hoc 本地签名，未经 Apple 公证（`spctl` 拒绝，符合预期）；Intel 切片仅经交叉编译和 Rosetta 下的 stdio 冒烟测试。
- `Contents/Resources/ThirdPartyNotices.txt` 含 swift-sdk 0.12.1、swift-log 1.15.1、swift-system 1.8.1、eventsource 1.5.1 的许可证与声明，并随 DMG / ZIP 放在应用旁边。
- 777 键双语资源（第一轮 768 键）、图标、12 个音频素材验证通过；DMG 完整性校验 VALID；`Release-Status.plist`：1.5.0、`arm64 x86_64`、`local`、未公证、不含用户数据；第二轮、第三轮 DMG（只读挂载）和 ZIP 中的 `INSTALL.md` 都与当时的仓库 `docs/INSTALL.md` 逐字节一致（`cmp`）；第三轮 `hdiutil verify` 仍为 VALID。
- `scripts/verify-release.sh … --require-universal` 在候选应用和解压到临时目录的 ZIP 上分别重新运行，均通过；重新打包后又各运行一次，仍然通过（两个切片都是 `protocol 2025-11-25, focus-studio 1.5.0, 24 tools`）。第二轮重新构建和打包后，两处再各运行一次，仍然通过；解压后的应用 `codesign --verify --deep --strict` 通过；对解压 ZIP 得到的 helper 再完整运行 `mcp_client.py --expect-version 1.5.0`：PASS（`tools/list` 与 server `instructions` 与本轮源码导出的目录逐项一致，fake-app 收到的调用都带 `elapsed`）。第三轮重新构建和打包后，候选应用和解压到临时目录的 ZIP 再各运行一次 `verify-release.sh … --require-universal`，均通过；解压后的应用 `codesign --verify --deep --strict` 通过；对解压 ZIP 得到的 helper 再完整运行 `mcp_client.py --expect-version 1.5.0`：PASS（含 `waiting_for_turn` 的 instructions 与本轮目录一致，hello 迟到时 `elapsed` ≥ 2.4 秒）。

文件：

- `dist/candidates/1.5.0/Focus Studio.app`
- `dist/releases/Focus-Studio-1.5.0-universal-local.dmg`（54,778,430 字节，SHA-256 `5d94d60c44b5602ee46dfc710725c47e95d7d9086a48bc390a05138d494104c6`）
- `dist/releases/Focus-Studio-1.5.0-universal-local.zip`（52,137,953 字节，SHA-256 `9553d44774cdb4930ec362861d27fe50dbf88eaeeccc0b6f9934db1808d941fa`）
- `dist/releases/Focus-Studio-1.5.0-universal-local.sha256`（`shasum -a 256 -c` 通过）

## 实机检查（待完成）

以下检查需要有图形界面的会话，并会使用真实的项目库、偏好设置和 Claude Code / Codex 配置，要和使用者一起完成（步骤见 `docs/MCP-QA.md`，建议在单独的 macOS 测试用户下进行）。**本次都没有执行，结果待填。**

| 检查 | 对应 MCP-QA 章节 | 结果 |
| --- | --- | --- |
| 只列工具不启动应用 | 1 | 待完成 |
| 后台启动：不抢焦点、ppid 为 1、进度通知、冷启动耗时（应在 30 秒以内） | 2 | 待完成 |
| 首次连接批准面板：显示客户端名称和程序路径；shell 启动时只批准本次连接；允许后同一会话不再询问 | 2 | 待完成 |
| 编辑时窗口可见但不抢焦点；无窗口时新开；隐藏时不多开窗口；最小化后恢复到最前 | 3 | 待完成 |
| 导出中途退出应用：返回 `isError`、不重试、不留临时文件；下次调用再次后台启动 | 4 | 待完成 |
| `FOCUS_STUDIO_MCP_NO_LAUNCH=1`；关闭总开关后不启动应用 | 5 | 待完成 |
| 多个副本（`/Applications` 与 `dist/`、1.4.0 旧版本在运行） | 6 | 待完成 |
| 从 DMG 首次安装后由 helper 触发启动（Gatekeeper 询问、30 秒说明） | 7 | 待完成 |
| 设置 › AI 工具一键接入 Claude Code 和 Codex；`/mcp`、`codex mcp list` 显示已连接且不启动应用；撤销批准 | 8 | 待完成 |
| Claude Code 会话：列出源 → 录制 → 停止 → 加缩放 → 设置 BGM → 导出到工作目录（issue #1 验收标准） | 8 | 待完成 |
| Codex 会话：同上 | 8 | 待完成 |
| 真实录制：悬浮倒计时与控制条（写明谁请求录制、录哪些声音）、录制开始即返回、剩余时间、`duration` 自动停止、`wait_for_recording`、各种取消、倒计时和控制条不进视频 | 9 | 待完成 |
| 声音询问面板：倒计时前出现、写明 AI 工具/启动它的程序/声音/来源、仅本次允许 / 无声录制（不录任何声音，录制器已开的也不录）/ 取消录制 / Esc / 60 秒无回答、没有默认按钮、回答后焦点回到原应用、录制器开关不变、录制器已开的声音不询问、询问期间关掉的声音不录 | 9（第 2、8 步） | 待完成 |
| 可复制命令以找到的 `claude` / `codex` 完整路径开头 | 8 | 待完成 |
| Intel Mac 实机 | — | 待完成 |

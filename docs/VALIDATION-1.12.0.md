# Focus Studio 1.12.0（build 19）验证记录

## 范围

1.12.0 = 1.11.0（build 18，上游 `main` 的 `cc8aaac`）+ 通过 MCP 让 Claude Code、Codex 直接使用 Focus Studio（GitHub issue stevenchengxy/focus-studio#1，M1–M7）。代码来自 `feature/mcp-server` 分支的合并提交 `b0907fc`（Merge origin/main (1.8.0-1.11.0) into feature/mcp-server）；在它之上的发布准备（版本号、文档和 3 个不再使用的本地化键，见下文“1.12.0 发布准备”）是提交 `c493291`。实机检查用的是 `c493291` 的候选（见“实机检查”），检查中发现第一次录麦克风时 macOS 的授权对话框出现在倒计时之后；本记录现在对应的工作区在 `c493291` 之上修正了它（见“麦克风权限的修正”），“自动化”“MCP 协议检查”“安装包”三节是修正之后重新运行的结果，修正后的候选没有再做实机检查。验证机器：Apple Silicon（Apple M5）、macOS 26.5.2、Swift 6.1（Xcode 工具链）。

**来自上游 1.5.0–1.11.0 的部分**：合并基点 `13944da` 是 1.4.0（build 8）；上游把 1.5.0–1.7.1 的改动和 1.8.0 放在同一个提交 `adb82ec`（“1.8.0: …”）里，所以合并提交标题中的“1.8.0-1.11.0”指的是上游提交，带进来的功能从 1.5.0 开始：固定安装位置与应用内安装、统一聊天与 Demo 导演（1.5.0，见 [VALIDATION-1.5.0.md](VALIDATION-1.5.0.md)）；录前工具栏、真实暂停/继续、鼠标显示开关（1.6.0，见 [VALIDATION-1.6.0.md](VALIDATION-1.6.0.md)）；移除数字人、只保留聊天的助手（1.7.1，见 [VALIDATION-1.7.1.md](VALIDATION-1.7.1.md)；1.7.0 加入的 3D 人物已被它撤销）；光标动画与镜头跟随、按距离延长的焦点转移、手动调节过渡时刻、小手光标、缩放追踪鼠标、时间线缩放操作（1.8.0、1.9.0，见 [VALIDATION-cursor-motion-2026-09-22.md](VALIDATION-cursor-motion-2026-09-22.md)）；光标样式、精简录制条、实时来源、区域重选（1.10.0，见 [VALIDATION-cursor-styles-toolbar-2026-09-23.md](VALIDATION-cursor-styles-toolbar-2026-09-23.md)）；图标化录制控制条和 12 张自带背景图（1.11.0，见 [VALIDATION-toolbar-backgrounds-2026-09-23.md](VALIDATION-toolbar-backgrounds-2026-09-23.md)）。本次没有重做这些实机检查，只在合并后的代码上重新运行了全部自动化测试。

**MCP 部分（issue #1）**：

- 应用内附带 `Contents/MacOS/focus-studio-mcp`（官方 MCP Swift SDK 0.12.1，精确锁定，stdio），经本机 Unix socket 控制通道（目录 0700、socket 0600、只接受同一用户）连接应用，控制协议为 1；应用没在运行时在后台启动它（不抢焦点），只列工具不启动应用。
- 新的 AI 工具第一次调用时弹出批准面板（AI 工具自报的名称、实际启动 helper 的程序和签名者）；设置新增 **AI 工具** 页：总开关、已批准列表（撤销）、最近拒绝的、一键接入 Claude Code / Codex（调用它们自己的 `mcp add`，可复制命令以找到的命令行工具完整路径开头）。
- 24 个 MCP 工具（`Tests/MCPTests/v1-tools.txt`）；编辑按 `project_id` 在编辑器里前台可见地进行，改变界面的调用逐个排队；导出和拼接发送进度，约 200 秒后转为 `job_id` 后台任务（`wait_for_job`）。
- 录制：`start_recording` 在录制真正开始后返回，支持 `duration`（1–600 秒）、`wait_for_recording`、`stop_recording`；外部要打开录制器里没开的麦克风或系统音频时，倒计时之前先弹出 **Record sound? / 录制声音？**（仅本次允许 / 无声录制 / 取消录制，没有默认按钮，60 秒无回答不录制，每次都问、不改录制器设置）；要录麦克风时（询问里允许了，或录制器本来就开着麦克风），倒计时之前先确认 macOS 的麦克风权限（实机检查之后的修正）。
- 每个调用的时间从到达应用算起，并扣除 helper 报告的已用秒数（`elapsed`，0–600 秒）；批准面板、排队、声音询问和 macOS 的麦克风授权都计入，到时分别返回 `waiting_for_approval`、`waiting_for_turn`（都可重试，工具没有执行）或转为后台任务。
- M1 的工具加固：导出不覆盖原始录像、编辑被丢弃时报错、导出宽度与帧率、原子读改写、项目库加载完成后才算启动完成、停止录制只执行一次、缺少录屏权限时如实报告。

### 合并整合（`b0907fc`）

- **暂停与时长**：上游的暂停/继续与 MCP 的 `duration` 合在一起时，`duration` 计的是录下的时间：从第一帧算起，暂停的时间不算，剩余时间在暂停时不减少；`get_status` 和 `wait_for_recording` 报告 `paused`（暂停时没有 `auto_stop_at`），暂停中也能 `stop_recording` 和丢弃。
- **录制控制条**：MCP 原来单独的悬浮倒计时面板去掉了，倒计时、请求录制的 AI 工具名（✦，悬停和 VoiceOver 读出“<AI 工具> asked to record <来源>”）、要录的声音（黄色麦克风 / 扬声器图标）和剩余录制时间都放进上游 1.10–1.11 的录制控制条；带时长或声音的录制使用稍宽的 392 × 46 录制条。控制条跟随模型而不是窗口（`RecordingControlPanelCoordinator.follow`），没有打开主窗口时也会出现；倒计时和录制中按 ⌘H 隐藏应用时控制条保留，录制页空闲时的控制台随应用隐藏。录制页的大计时器下方也显示 “Stops automatically in …”。
- **AI 助手**：上游对应用内助手会话的修改搬进了已移到 `FocusStudioAutomation` 的会话，录制计划类型（`CodexRecordingPlan`）也移到那里。
- **设置**：保留上游的 **安装** 页，新增 **AI 工具** 页（顺序：AI 模型、Codex、AI 工具、安装）；安装和“打开已安装副本”在点击时重新读取是否有 AI 调用或后台任务在进行。
- **录制源**：录制页的显示器列表与控制条、`list_recording_sources` 一样主显示器在前。
- **文档**：上游的 `docs/VALIDATION-1.5.0.md` 保留不动；MCP 分支原来写在同名文件 `docs/VALIDATION-1.5.0.md` 里的验证记录移到本文件。

### 1.12.0 发布准备（`c493291`）

- `Resources/Info.plist`：`CFBundleShortVersionString` 1.12.0，`CFBundleVersion` 19。脚本和测试都从 `Info.plist` 读取版本（`package-release.sh`、`verify-release.sh`、`test-mcp.sh`），没有写死的版本号需要跟着改；MCP 测试里的 `1.5.0` 只是任意的示例版本字符串，与当前版本无关，未改。
- 文档：README、INSTALL、RELEASE、`skills/README.md`、`skills/install.sh`、`skills/focus-studio-mcp/SKILL.md` 和本地化文件注释里 MCP 功能的版本标注由 1.5 改为 1.12；INSTALL 和 MCP-QA 中“没有控制通道的旧版本”由“1.4.0 及更早”改为“1.11.0 及更早”。README 的版本章节沿用上游的由新到旧：MCP（1.12）紧接“已实现”，其后是 AI 助手、1.3、1.2。上游标注为 1.5 的光标动画、焦点转移、镜头跟随是上游自己的功能，未改。RELEASE 的发布状态和候选命令改为 1.12.0（`dist/candidates/1.12.0/Focus Studio.app`）。
- 本地化：删除合并后不再使用的 3 个键，中英两份目录同时删除，键集合仍一致（888 → 885）：`Focus Studio is about to record`、`Starting the recording…`（独立倒计时面板的标题，合并时随面板一起去掉）和 `This recording stops by itself when the time runs out. Finish or cancel it any time.`（旧的剩余时间悬停提示，现为 “Stops by itself after this much more recording. Paused time does not count; finish or cancel any time.”）。删除前用脚本把目录里每个键（含 `%@` / `%lld` 占位符对应的 Swift 字符串插值写法）在 `Sources`、`Tests` 中查找，并与合并的两个父提交（`f855187`、`cc8aaac`）对照：目录里有、上游 `main` 的目录里没有的 70 个键（MCP 分支的 68 个，加合并时新增的 2 个）中，只有这 3 个不再被引用（它们的文字在 `Sources`、`Tests`、`scripts` 里都找不到，合并前只在 MCP 分支的 `RecordingControlPanel.swift` 里使用）。`Recording countdown` 是上游的键，仍被录制页使用，保留。删除后目录里还有 111 个键在源码里找不到字面量，它们都来自上游目录、在上游 `main` 上同样没有引用：有的由数据动态查找（例如音频目录里的曲目名经 `LocalizedStringKey(asset.title)` 显示），22 个是 MCP 分支合并前的旧界面还在用的（旧的 Codex Director 面板、旧的区域框选提示等，上游已经去掉界面、保留了键）。它们不是这次合并造成的，未动。

### 麦克风权限的修正（本次工作区，在 `c493291` 之上）

实机检查第 4 项发现（详见“实机检查”）：这个 ad-hoc 构建第一次录麦克风时，macOS 的麦克风授权对话框在采集开始时才出现，即倒计时之后、录制已经开始时；3 秒的 `duration` 在使用者回答 macOS 时走完，声音的开头可能缺失。原因是 ScreenCaptureKit 只在采集开始时向 macOS 请求麦克风，录制路径上此前没有检查麦克风权限。

- **AI 工具的 `start_recording`**：这次录制会录麦克风时（使用者在声音询问里允许了，或录制器里本来就开着麦克风），在声音询问（如果有）之后、倒计时之前读取 `AVCaptureDevice.authorizationStatus(for: .audio)`。
  - `notDetermined`：调用 `AVCaptureDevice.requestAccess(for: .audio)`，macOS 的对话框在倒计时之前出现，回答之后才倒计时。等待期间约每 5 秒向客户端发一次递增的进度（从 0.02 起，高于声音询问的心跳；消息 “Waiting for the person to answer macOS's microphone access prompt for Focus Studio…”），等待结束时再发一条不带消息的。最多等 60 秒；没有回答就不录制，返回 `isError`（对话框关不掉，可能还开着；之后的回答只由 macOS 记住，不会再开始录制）。等待时间和批准面板、排队、声音询问一样计入调用约 200 秒的时间，超过时转为后台任务，运行状态的 `activity` 写明在等 macOS 的麦克风授权。同时有几个调用在等时共用一个对话框。使用者在对话框里允许后，和声音询问之后一样再检查一次调用是否仍可执行（总开关、批准被撤销、应用正忙）。
  - `authorized`：照常倒计时。
  - `denied` / `restricted`：不开始录制，返回 `isError`，文字告诉模型使用者已在 System Settings › Privacy & Security › Microphone 里关掉了 Focus Studio 的麦克风权限（刚在对话框里选了不允许时写明这一点；`restricted` 时写明受限、使用者无法打开），可以用 `microphone` 为 `false` 重试只录画面；`structuredContent` 为 `{status: "microphone_unavailable", microphone_access: "denied" | "restricted" | "not_determined", asked_now, settings, retry_with: {microphone: false}}`，60 秒无回答时另有 `waited`。
  - 为此新增 `AIToolFailure`：带结构化数据的工具错误，MCP 结果里是 `isError` 加 `structuredContent`，应用内助手只读文字。
  - 状态读取和授权请求都可注入（`MicrophoneAccessController` 的 `status` / `request`），测试用脚本化的状态和对话框覆盖每种状态，不会出现真的系统对话框。
- **应用内（使用者自己操作）的路径**：检查后确认有同样的问题：使用者开着麦克风自己点录制，以及应用内 AI 助手的 `start_recording`，第一次也是在倒计时之后、采集开始时才由 macOS 询问。只对 `notDetermined` 做了同样的修正：先问 macOS，回答之后才倒计时（不设时限；等待期间再点录制不会重复询问；使用者离开了录制页时回答后不开始倒计时）。回答之后以及 `authorized`、`denied`、`restricted` 时都和以前一样开始录制，没有新的提示或拒绝：这是使用者自己要录麦克风。权限关闭时 ScreenCaptureKit 具体怎样处理麦克风，本次没有实机验证，行为也没有改动。
- **模型看得到的变化**：`start_recording` 的说明加了一段麦克风权限（macOS 从没问过时在倒计时之前询问，60 秒无回答也取消；权限关闭时返回 `microphone_unavailable`，用 `microphone` 为 `false` 重试），`microphone` 参数说明加了“macOS 也必须允许”，`wait_for_job` 的说明把 macOS 的麦克风授权列为转为后台任务的原因之一；刚由 macOS 询问并允许时，结果文字多一句说明。server `instructions` 没有改动。
- **文档**：README（“麦克风权限先确认”、长操作、macOS 权限表和“点击 Start 不会主动请求可选权限”的例外）、`docs/INSTALL.md`、`docs/RELEASE.md`、`skills/focus-studio-mcp/SKILL.md`、`docs/MCP-QA.md`（第 9 节新增第 9 步：用 `tccutil reset Microphone com.local.focusstudio` 重置后的手动检查）。
- **测试**：`AIAssistantTests`（`RecordingSessionTests.microphoneAccess`：先声音询问后麦克风、已允许、刚允许的文字、四种拒绝的文字和结构化数据及 MCP 结果形状、等待期间被拒绝、调用被取消、不录麦克风 / 无声录制 / 询问期间关掉麦克风时不检查、录制器本来开着的麦克风也检查、应用内助手照常录制；`MCPAutomationTests` 的目录说明和带数据的错误结果）；`RecordingSessionRegression`（`microphoneAccessController`、`microphoneBeforeTheCountdown`、`microphoneWaitWithinTheCallsTime`、`microphoneForThePersonsRecord`，见下表）。临时去掉 bridge 的麦克风处理、或去掉点录制时的先询问，新测试都会失败（各试过一次后恢复）。

## 自动化

`./scripts/test.sh` 在麦克风修正完成后完整运行一次（2026-09-24 16:56:58–17:00:16），退出码 0。（`c493291` 的发布准备完成后也完整运行过一次，15:00:04–15:03:13，退出码 0。）各项输出：

| 检查 | 结果 |
| --- | --- |
| `swift build`（全部 target，含 `focus-studio-mcp` 与 MCP SDK 依赖） | 通过（增量构建；有 Swift 6 语言模式下的并发警告，无错误） |
| `FocusStudioPermissionTests`（权限、启动、区域几何） | PASS |
| `FocusStudioE2E` → `CursorVisibilityValidation`（旧编解码、光标可见性、箭头 / I-beam、点击反馈与缩放互不影响、预览 / 导出一致） | PASS |
| 同上 → `PauseRecordingValidation`（真实分段拼接、继续后的第一帧、音频连续、零长度区间、失败不破坏原片、串行切换；只用合成素材） | PASS |
| 同上 → 合成网格视频 → 点击 → 自动缩放 → 正式渲染管线导出（含章节字幕与音频） | PASS（960 × 540、24 fps、2.42 s、2 段缩放、音视频轨各 1，`zoomFrameDifference` 40.87，`returnFrameDifference` 0.95，`cursorChangedPixels` 62） |
| `swift scripts/test-localization.swift` | PASS（885 个键，中英一致，占位符一致，权限说明齐全） |
| `test-language-preferences.sh`（隔离的语言偏好，不改用户设置） | PASS |
| `test-app-regression.sh` → `ProjectLibraryRegression`（多选、重命名、移到废纸篓、过期绑定保护） | PASS |
| 同上 → `RecordingLifecycleRegression`（就绪 / 忙碌 / 来源同步、倒计时、取消与重开、空闲时暂停 / 结束、控制条排除；上游 1.11 的来源类型和区域重选守卫） | PASS |
| 同上 → `AssistantControlRegression`（被丢弃的编辑报错、导出目录保护、并发 bootstrap、停止只执行一次、缺少权限如实报告、`get_project` / `get_status` 不切换页面） | PASS |
| 同上 → `RecordingSessionRegression`（手动时钟下的倒计时与自动停止、`duration` 从第一帧计时、完成 / 取消与 `stop_recording` / `wait_for_recording` 共用一次停止、选项只对本次录制有效；合并后：暂停与继续（暂停的时间不计入时长、已录和剩余时间，`get_status` 与 `wait_for_recording` 报告暂停，暂停中停止和取消）、倒计时写明 AI 工具、控制条的页面（应用隐藏时只保留倒计时和录制条）、录制中不把主窗口提到前面；声音询问：仅本次允许、无声录制（不录任何声音）、取消录制、无回答、期间被关闭、询问期间关掉的声音不录、调用被取消、心跳递增、不需要询问的情况、录制器设置不变、从调用到达算起转为后台任务；macOS 的麦克风权限（脚本化的状态和授权对话框）：状态一一对应、已决定时不询问、从没问过时多个调用共用一个对话框、心跳高于声音询问、超时后对话框仍在且迟到的回答只被记住、被取消的等待立即结束；AI 工具的 `start_recording`：从没问过→允许（对话框在声音询问之后、倒计时之前，回答前不倒计时，进度一直递增）、之前已允许不询问、从没问过→不允许、之前已关闭、受限（都返回 `microphone_unavailable` 且不倒计时、不录制）、改用 `microphone: false` 照常录制、无声录制和不录麦克风时不询问、录制器本来开着的麦克风也先确认、调用被取消、等待期间关闭 AI 工具、60 秒（测试中缩短）无回答后迟到的允许不开始录制、等待计入调用时间并转为后台任务（`activity` 写明在等 macOS）；使用者自己点录制：从没问过时先等 macOS 的回答再倒计时（允许或不允许之后都照常录麦克风）、等待中再点不重复询问、已决定时立即倒计时、离开录制页后回答不开始倒计时；应用内助手先等 macOS 的回答再倒计时、之后照常录制） | PASS |
| 同上 → `AutomationBridgeRegression`（按 `project_id` 打开编辑器并保存、切换项目先保存、并行调用排队、录制中 / 忙碌 / 应用内助手工作 / 编辑器导出时拒绝、隐藏和最小化窗口的恢复、导出进度、导入 / 截图 / 重命名 / 废纸篓、中文界面下仍返回英文结果、后台任务与 `wait_for_job`、排队到时返回 `waiting_for_turn`、AI 调用和后台任务开始结束时重新发布安装页的忙碌状态） | PASS |
| 同上 → `ControlServerRegression`（hello 与协议版本、畸形消息、进度只在请求时发送、取消与断线取消工具、其他用户的连接被拒、socket 目录与文件权限、过期 socket 替换、批准允许 / 拒绝 / 超时 / 撤销 / 总开关、shell 与解释器按脚本或按连接批准、调用时间到时返回 `waiting_for_approval` 且重试加入同一面板、`elapsed` 被服务端截断、新客户端的 `start_recording` 经批准面板再到声音询问） | PASS |
| 同上 → `MCPClientConnectorRegression`（假的 `claude` / `codex` 与登录 shell：PATH 查找、坏掉的安装被跳过、精确的 add/remove/get 参数、已接入不重复、另一副本先 remove 再 add、超时与错误文本、以找到的完整路径开头的可复制命令、临时位置 / 磁盘映像 / 缺少 helper 的提示） | PASS |
| 同上 → `MCPEndToEndRegression`（真实 `focus-studio-mcp` → `ControlServer` → `StudioModel`，临时项目库：initialize、tools/list、`get_status`、相对路径 `import_video`、`get_project`、`add_zoom`、`update_settings`、导出到客户端目录（0.2 s，2 条进度通知）、`rename_project`、`list_projects`、`delete_project` 到测试废纸篓） | PASS |
| `FocusStudioAppRegression` 汇总（50 次打开 / 编辑 / 返回循环、过期绑定、自动保存、缩放计时编辑，以及以上各项） | PASS |
| `test-toolbar-snapshots.sh` → `ToolbarSnapshotTests`（760 × 116、640 × 116 的空闲控制条、324 × 46 录制条、窗口模式、AI 工具发起的倒计时与录制（工具名、声音、剩余录制时间）收起与展开、光标和背景检查器、区域框选浮层；隔离的离屏快照，不启动应用、不录屏） | PASS |
| `test-installation.sh` → `InstallationTests`（数字版本比较、首次安装、可恢复更新、拒绝降级、同 build 冲突、应用忙、回滚、身份与签名、加锁、拒绝符号链接；只用临时夹具） | PASS |
| `test-codex-plan-runner.sh` → `CodexPlanRunnerTests` | PASS |
| `bash scripts/test-codex-connection.sh`（fake codex） | PASS |
| `bash scripts/test-ai-gateway.sh` | PASS |
| `zsh scripts/test-ai-assistant.sh` → `AIAssistantTests`（助手协议与工具、自动化 API、MCP 目录与结果形状、后台任务、调用队列及其截止时间、录制会话（开始即返回、`duration`、`wait_for_recording` 各种结束方式、声音询问、macOS 麦克风权限（先声音询问后麦克风、已允许和刚允许、四种拒绝的文字与 `structuredContent`、等待期间被拒绝、调用被取消、不需要时不检查、录制器的麦克风也检查、应用内助手照常录制）、暂停的录制在 `get_status` / `wait_for_recording` / 应用内摘要中的表述）、带结构化数据的错误结果、`start_recording` / `wait_for_job` 的说明、Ark 请求） | PASS |
| `zsh scripts/test-mcp.sh` → `MCPTests`（v1 目录名称与保守的 schema、SDK 适配层、按协议版本映射结果、stdout 隔离、app 包内和符号链接下的身份、进度转发、协议握手、转发工作目录 / 客户端 / 版本 / roots、取消、未知与未开放的工具、-32602 / -32600、控制通道帧与消息及可选的 `elapsed`、helper 端转发器：调用、进度、应用中途退出、重连、协议不一致、hello 被拒或迟到、打开应用、取消、关闭） | PASS |
| 同上 → `mcp_client.py`（开发构建的 helper，真实 stdio，见下节） | PASS |
| 同上 → `mcp_client.py --handshake-only`（helper 放进最小的 Focus Studio.app，以及通过符号链接启动） | PASS，两次都报告 `serverInfo.version 1.12.0` |

所有 helper 测试都设置 `FOCUS_STUDIO_MCP_NO_LAUNCH=1` 和临时 socket，没有打开或连接真实的 Focus Studio；一键接入只针对假的命令行工具，没有改动本机的 Claude Code / Codex 配置。

## MCP 协议检查

`mcp_client.py` 对开发构建的 helper（`test-mcp.sh`）和打包后的 helper（见“安装包”）结果相同（都是修正之后的构建）：

- 协议版本协商：请求 2025-11-25、2025-06-18、2025-03-26、2024-11-05 时原样返回；请求未知的 2099-01-01 或过旧的 2024-10-07 时返回 2025-11-25。
- `tools/list` 返回 24 个工具，顺序和名称与 `Tests/MCPTests/v1-tools.txt` 一致；`generate_image`、`generate_video`、`wait`、`export_demo`、`reveal_in_finder`、`open_project`、`close_editor` 不开放，调用返回 -32602。server `instructions` 为 1,994 个 UTF-16 单位（合并前第三轮为 1,987；麦克风修正没有改动它），测试要求不超过 2,000，低于 Claude Code 截断的 2,048。修正只改了 `start_recording` 的说明和 `microphone` 参数说明、`wait_for_job` 的说明（见“麦克风权限的修正”），`tools/list` 的结果与 `.artifacts/mcp-tests/catalog.json` 一致。
- 未知参数被拒绝；畸形参数 -32602；批量请求 -32600；resources / prompts -32601；`ping`、进度 token、取消、解析错误都按规范处理。
- helper 空闲时不轮询（2 秒内 0 次唤醒）；日志只写 stderr，stdout 只有 JSON-RPC；stdin 关闭后正常退出（空闲 0.02 s，管道输入 0.02–0.03 s）。
- 对假的应用（`Tests/MCPTests/fake-app.py`）：先 hello（带客户端和工作目录）、参数原样转发并带上 helper 已用的时间、单一连接、进度转发、取消只转发不重复回复、应用中途退出返回 `isError` 且不重试、重连、崩溃和不存在时返回“could not be reached”、协议不一致、hello 迟到时 2 次心跳且等待计入 `elapsed`、关闭时取消正在运行的调用并在 2.0 s 内退出。
- 启动设置：开发构建的 3 个用例（没有应用路径、指向其他应用、相对路径）都在打开任何应用前被拒绝；打包后的 helper 在 .app 里，“没有应用路径”会打开所在的应用，按设计跳过，其余 2 个同样被拒绝。

## 文档核对

- 工具名：README 的 MCP 一节、`docs/INSTALL.md`、`skills/focus-studio-mcp/SKILL.md` 中反引号里的名称都用脚本对照了 `test-mcp.sh` 导出的目录（`.artifacts/mcp-tests/catalog.json`）：README 与 skill 列出全部 24 个工具；其余名称要么是工具参数，要么是源码里存在的结果字段（`paused`、`idle`、`last_recording`、`started_at`、`auto_stop_at`、`activity`、`has_more`、`waiting_for_approval`、`waiting_for_turn` 等）、命令名（`claude`、`codex`）或普通词。麦克风修正之后用本次导出的目录重新对照了这三份和 `docs/MCP-QA.md`、`docs/RELEASE.md` 中反引号里的蛇形名称（去掉代码块）：都是工具名、工具参数或源码里存在的名字（含新的 `microphone_unavailable`、`microphone_access`、`asked_now`、`retry_with`），只有 `mcp_servers`、`tool_timeout_sec` 是 Codex 配置文件里的键。
- 版本标注：`grep` 确认 README、INSTALL、RELEASE、MCP-QA、skills 中不再有把 MCP 标成 1.5 的地方；剩下的 1.5 / 1.5.0 都是上游自己的标注（固定安装位置、统一聊天是 1.5.0 的功能；README 把光标动画、焦点转移、镜头跟随标为 1.5，实际随 1.8.0 发布）或历史验证记录。
- `docs/MCP-QA.md` 新增的 `tccutil reset Microphone com.local.focusstudio` 中的 bundle id 与应用签名标识一致。
- `docs/INSTALL.md` 会被复制进 DMG / ZIP：打包后 DMG（只读挂载）和 ZIP 中的 `INSTALL.md` 与仓库里的逐字节一致（`cmp`）。
- 合并前（1.5.0 候选）做过的其他文档核对（Claude Code 2.1.278 / codex-cli 0.155.0-alpha.16 的 `mcp add` 参数、Codex 默认工具超时 300 秒、设置页和面板的中英文文字、helper 日志的排查方法、`skills/install.sh` 用临时 `CLAUDE_SKILLS_DIR` 的两种安装方式）这次没有重做；合并没有改动这些内容。

## 安装包

修正后重新构建的候选：`FOCUS_STUDIO_APP_DIR="$PWD/dist/candidates/1.12.0/Focus Studio.app" zsh scripts/build-app.sh`（Universal，2026-09-24 17:43 起）与同一变量下的 `scripts/package-release.sh --skip-build`（17:45 完成）通过。它们在提交 `2be0d78` 的源码上运行，那份源码已通过完整测试；测试中 `CodexConnectionTests` 有一次偶发的计时失败，单独重跑三次都通过。它替换了实机检查用过的 `c493291` 候选（同一路径），`dist/releases/` 里的 1.12.0 安装包也被覆盖；那一份的大小和 SHA-256 记在“实机检查”里。`package-release.sh` 读取 `FOCUS_STUDIO_APP_DIR`，打包的是候选应用；输出写入 `dist/releases/`，临时目录在结束时删除。构建和打包时 Focus Studio 没有在运行（`pgrep -x FocusStudio` 无输出），`dist/Focus Studio.app` 没有被替换；测试、构建和打包都不涉及 `/Applications`、真实的项目库和偏好设置、`~/.claude.json`、`~/.codex`（测试只用临时项目库、隔离的偏好、假的命令行工具和脚本化的麦克风权限）。实机检查时用 Claude Code 接入的 helper 路径就是候选里的 `Contents/MacOS/focus-studio-mcp`，重新构建后这个路径上是修正后的 helper。

- 版本 1.12.0（build 19），arm64 + x86_64 Universal 2，macOS 15.0 最低系统版本；应用与 helper 都只链接 `/System/Library` 与 `/usr/lib` 下的系统库。
- 应用可执行文件 29,544,608 字节，helper `focus-studio-mcp` 18,595,952 字节（都含两个架构）。helper 签名标识 `com.local.focusstudio.mcp`，指定要求 `identifier "com.local.focusstudio.mcp"`，无 entitlements；应用签名标识 `com.local.focusstudio`；`codesign --verify --deep --strict` 通过。本机没有签名身份，是 ad-hoc 本地签名，未经 Apple 公证（`spctl` 拒绝，符合预期）；Intel 切片只经过交叉编译和 Rosetta 下的 stdio 冒烟测试。
- `Contents/Resources/ThirdPartyNotices.txt` 含 swift-sdk 0.12.1、swift-log 1.15.1、swift-system 1.8.1、eventsource 1.5.1 的许可证与声明，DMG / ZIP 里应用旁边的副本与之逐字节一致。
- 构建时 12 张自带背景图的摘要校验通过；`verify-release.sh` 确认 885 键双语资源、图标、12 个音频素材、12 张背景图，且不含数字人资源。
- DMG `hdiutil verify` 为 VALID。DMG（只读挂载后卸载）和 ZIP（解压到临时目录）中：应用与候选逐文件一致（`diff -rq`）、`codesign --verify --deep --strict` 通过、版本 1.12.0 / 19；`INSTALL.md` 与仓库的 `docs/INSTALL.md`（含本次的麦克风说明）逐字节一致（`cmp`）；`Applications` 指向 `/Applications`；`Release-Status.plist`：1.12.0、`arm64 x86_64`、最低 15.0、`local`、未公证、不含用户数据。
- `scripts/verify-release.sh … --require-universal`：打包脚本里对候选应用和解压副本各运行一次，打包后又手动对候选应用和解压到临时目录的 ZIP 各运行一次，均通过（退出码 0，两个切片都是 `protocol 2025-11-25, focus-studio 1.12.0, 24 tools`）。
- 打包后的 helper：对解压 ZIP 得到的 `Focus Studio.app/Contents/MacOS/focus-studio-mcp`（release 构建）完整运行 `python3 Tests/MCPTests/mcp_client.py … --catalog .artifacts/mcp-tests/catalog.json --fixture Tests/MCPTests/v1-tools.txt --expect-version 1.12.0`（17:04:09–17:04:19）：PASS，`tools/list` 与本次 `test-mcp.sh` 导出的目录（含修正后的 `start_recording` / `wait_for_job` 说明）一致，结论见“MCP 协议检查”（stdin 关闭后空闲 0.02 s、管道输入 0.02 s 退出；2 个启动设置用例在打开任何应用前被拒绝）。

文件：

- `dist/candidates/1.12.0/Focus Studio.app`（约 98 MB）
- `dist/releases/Focus-Studio-1.12.0-universal-local.dmg`（65,584,296 字节，SHA-256 `cd8c554186d8cda9ccc242bee17f3488150c8ec92726e8ce7b66a9645ea0da98`）
- `dist/releases/Focus-Studio-1.12.0-universal-local.zip`（62,791,973 字节，SHA-256 `7eb66e55be79848545a77e8a63d73ed4f13f6f192511ffc093a8133831b0570c`）
- `dist/releases/Focus-Studio-1.12.0-universal-local.sha256`（`shasum -a 256 -c` 通过）

没有安装到 `/Applications`，也没有做旧版本清理：`dist/releases/` 里合并前的 1.5.0 安装包和 `dist/candidates/` 里的其他候选都还在。

## 合并前的验证（1.5.0 候选，已被取代）

MCP 功能合并前以 1.5.0（build 9）为版本号，在 2026-09-24 分三轮验证（第一轮 M1–M7；第二轮加入声音询问和“调用时间从到达应用算起”；第三轮修正无声录制、询问期间关掉的声音、排队截止时间和“启动它的程序”），每轮都完整运行 `scripts/test.sh` 并重新构建、打包 `dist/candidates/1.5.0`。那时的详细记录见提交 `f855187` 中的 `docs/VALIDATION-1.5.0.md`（合并提交 `b0907fc` 把它原样移到了 `docs/VALIDATION-1.12.0.md`，即 `b0907fc:docs/VALIDATION-1.12.0.md`；当前分支上的 `docs/VALIDATION-1.5.0.md` 是上游另一份 1.5.0 记录）；合并后的代码以本文件上面的结果为准，1.5.0 的候选和安装包不再代表当前代码。

## 实机检查

2026-09-24 和使用者一起在有图形界面的会话里完成，使用真实的项目库、偏好设置和 Claude Code 配置（步骤见 `docs/MCP-QA.md`）。

- 机器：Apple Silicon MacBook Pro，macOS 26（Darwin 25.5）；主显示器是外接的 DELL U2725QE（1920 × 1080），另有内建 Retina 显示屏。
- 应用：`c493291` 的候选 `dist/candidates/1.12.0/Focus Studio.app`（Universal，ad-hoc 签名），即 `c493291` 中本文件“安装包”一节记录的那一份，当时打出的 DMG 为 65,508,953 字节（SHA-256 `86955645ec2eb5ddc6debc3c9916203c7a0ef8a0e2e52523b10de090842eef87`），ZIP 为 62,743,153 字节（SHA-256 `5ece6295b017753207232e74fed455907bf986684b1a940b21665e7890fc9d6a`）。这一份不含上文“麦克风权限的修正”；候选和这两个文件都已被修正后重新构建、打包的同名文件替换（见“安装包”），修正后的候选没有再做实机检查。检查前退出了正在运行的旧版 1.4.0（`dist/` 里的应用）。
- 第 1–5 项的客户端：只用 Python 标准库写的 MCP 客户端（会话临时目录里的 `qa_live.py`，未放进仓库），通过 stdio 运行候选里真正的 `focus-studio-mcp`；完整的 JSON 日志在同一目录的 `qa_live.log`。第 6 项用真实的 Claude Code。

| # | 检查 | 对应 MCP-QA 章节 | 结果 |
| --- | --- | --- | --- |
| 1 | 后台启动与首次连接批准 | 2 | 15:30:27 `initialize` 协商到 2025-11-25，`serverInfo` 为 focus-studio 1.12.0。第一个 `get_status` 在后台启动了 Focus Studio（进度 “Opening Focus Studio in the background…”），之后约每 5 秒一条 “Waiting for the person to allow focus-studio-live-qa in Focus Studio…”。当时没人点，121.5 s 后调用返回 `isError`：“…nobody answered within 120 seconds, so get_status did not run and nothing was changed. Ask the person to click Allow…”，即设计的超时路径。批准面板仍然开着；使用者随后点了允许，这个迟到的允许被记住。控制通道：`~/Library/Application Support/FocusStudio/Control/` 为 0700，`control.sock` 为 0600，另有 `control.sock.lock`。 |
| 2 | 已批准的客户端、状态与录制源 | 2 | 16:13:15 `get_status` 用时 0.0 s，没有再弹出面板：1.12.0（build 19）、空闲、显示项目库、0 个项目；权限：屏幕录制已授予，辅助功能和输入监控未授予。`list_recording_sources`（0.2 s）列出 2 个显示器、14 个窗口，主显示器（DELL，`display-3`）排在最前并标为主显示器。 |
| 3 | 真实录制、编辑、导出 | 9 | `start_recording {source: display, duration: 5}` 在调用后 3.6 s 返回：底部录制控制条里 3 秒倒计时，然后状态为 `recording`。`wait_for_recording` 5.5 s 后返回 `finished`：项目 `A0909140…`，5.03 s，源 3840 × 2160，已在编辑器里打开。`get_project`、`add_zoom`（1–3 s，×1.8，居中）、`update_settings`（`backgroundPreset=ocean`）和 2 s 处的 `capture_frame` 各用 0.1–0.2 s；`capture_frame` 返回内嵌的 JPEG 图像块，并写出 1920 × 1080 的 PNG。截取的画面有 Ocean 渐变、留白、圆角和 1.8 倍缩放，录下的画面里没有 Focus Studio 自己的控制条。`export_project` 导出到绝对路径（`overwrite`）用时 1.6 s：1920 × 1080、60 fps、5.03 s、7.1 MB 的 MP4，没有音轨。 |
| 4 | 声音询问 | 9（第 2 步） | `start_recording {duration: 3, microphone: true}` 弹出 Focus Studio 的声音询问，使用者选 **仅本次允许**，结果里是 `audio_consent: {asked: [microphone], answer: allowed}`。原始文件含 H.264 和 MPEG-4 AAC 立体声，3.005 s；前面那段无声录制只有 H.264。**发现问题**，见下文。 |
| 5 | 设置 › AI 工具一键接入 Claude Code | 8 | 找到 `~/.local/bin/claude`，状态为 “Not connected”，可复制的命令以这个完整路径开头。点接入后状态为 “Connected. Start a new Claude Code session to use Focus Studio.”，按钮变为 “Connected”。`claude mcp get focus-studio`：Scope 为 User config，Status 为 ✔ Connected，Command 为候选里的 `Contents/MacOS/focus-studio-mcp`。 |
| 6 | 真实的 Claude Code 会话 | 8 | Claude Code 2.1.281，在临时目录里运行 `claude -p`，中文提示词：先看 `get_status`，录主显示器 4 秒，1–3 秒加居中的 1.6 倍缩放，导出 `./claude-demo.mp4`。第一次在任何工具调用之前就失败了，因为命令行的 OAuth 登录已过期；使用者重新登录后重跑。启动时 MCP server `focus-studio` 为 connected；Claude Code 用 ToolSearch 加载工具并调用 `get_status`，这时出现首次调用的批准面板，使用者允许了 “Claude Code · claude”。设置里显示它的签名者是 Anthropic PBC（Q6L2SF6YDW），所以以后 Claude Code 更新后批准仍然有效。之后依次：`start_recording {display, duration 4}` 约 4 s 返回；`wait_for_recording` 返回 `finished`，4.007 s；`add_zoom`；`export_project {path: "claude-demo.mp4"}` 按 Claude Code 的工作目录解析。Claude Code 随后自己用 ffprobe 检查：4.017 s、1920 × 1080、60 fps、5.9 MB；它还指出辅助功能和输入监控没有打开，所以没有自动缩放。会话成功结束：8 轮、54.2 s、$0.25。 |
| 7 | 清理 | — | `delete_project` 把 3 个测试项目移到废纸篓（每个 0.0–0.4 s，项目库显示 0 个项目）。Python 客户端的批准已在设置 › AI 工具里撤销；Claude Code 的批准和接入保留。 |

### 发现：第一次录麦克风时，macOS 的授权对话框出现在倒计时之后

第 4 项是这个 ad-hoc 构建第一次使用麦克风：macOS 在采集开始时才弹出自己的麦克风授权对话框。`start_recording` 直到 16:14:20 才返回，而第一帧是在 16:14:17；3 秒的录制时长是在使用者回答 macOS 的时候走完的，所以声音的开头可能缺失。

修正见上文“麦克风权限的修正”：AI 工具的 `start_recording` 要录麦克风时，在倒计时之前先确认 macOS 的麦克风权限（从没问过就先让 macOS 询问，回答之后才倒计时；权限关闭时不录制，返回 `microphone_unavailable`）；使用者自己点录制和应用内助手有同样的问题，也改为倒计时之前先让 macOS 询问。修正只经过自动化测试（脚本化的权限状态和对话框），没有在修正后的候选上重做这一项；手动步骤见 `docs/MCP-QA.md` 第 9 节第 9 步。

### 没有实机验证的

- **Codex**：本机用 npm 安装的 codex 命令行工具坏了（缺少它的平台二进制文件），Codex 的一键接入、`codex mcp list` 和 Codex 会话都没有做。
- **issue #1 验收流程中没有实机做过的步骤**：验收流程是“列出源 → 录制 → 停止 → 加缩放 → 设置 BGM → 导出”。第 6 项的 Claude Code 会话实际只调用了 `get_status` → `start_recording`（`duration: 4`）→ `wait_for_recording` → `add_zoom` → `export_project`；`list_recording_sources` 只在第 2 项由 Python 客户端调用过；两次实机录制都靠 `duration` 自动停止，`stop_recording` 没有实机调用过；`set_background_music` 也没有实机做过。整个实机检查只用到了 24 个工具中的 10 个（`get_status`、`list_recording_sources`、`start_recording`、`wait_for_recording`、`get_project`、`add_zoom`、`update_settings`、`capture_frame`、`export_project`、`delete_project`），其余只有自动化测试覆盖。
- **MCP 录制带 `duration` 时的暂停 / 继续**。
- **声音询问的其他回答**：**无声录制**（Record without sound）和 **取消录制**（Cancel recording）按钮只有自动化测试覆盖；Esc、60 秒无回答、没有默认按钮、回答后焦点回到原应用、询问期间在录制器里关掉声音，这次也都没有实机检查。
- **麦克风权限的修正**：修正后的候选没有实机运行过；macOS 真正的授权对话框在倒计时之前出现、权限关闭时的 `microphone_unavailable`、60 秒无回答、使用者自己点录制时先询问，都只有脚本化测试。权限关闭时 ScreenCaptureKit 对使用者自己的录制怎样处理麦克风，也没有实机验证（行为未改动）。
- **`docs/MCP-QA.md` 的其他项目**：只列工具不启动应用（第 1 节）；后台启动时不抢焦点、ppid 为 1 和冷启动耗时（第 2 节这次只记录了后台启动和进度通知）；编辑时窗口可见但不抢焦点、隐藏和最小化后的恢复（第 3 节）；导出中途退出应用（第 4 节）；`FOCUS_STUDIO_MCP_NO_LAUNCH=1` 和关闭总开关（第 5 节）；多个副本（第 6 节）；从 DMG 首次安装时的 Gatekeeper（第 7 节）；第 9 节里没有主窗口时的控制条、录制中不把主窗口提到前面、剩余录制时间的显示、丢弃 / 倒计时中取消 / 取消调用等各种取消。
- **Intel Mac 实机**。

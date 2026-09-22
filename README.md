# Focus Studio

Focus Studio 是一个原生 macOS 产品 Demo 录制与编辑器，核心工作流参考 Screen Studio：录制时保存原始画面、鼠标轨迹和点击坐标；录制后根据点击自动生成可编辑的缩放区块；预览与导出共享同一条 Core Image 与 AVFoundation 渲染管线。

所有录屏、截图、音频和项目元数据默认只保存在本机。

## 已实现

### 录制与控制

- 整屏或单窗口录制（ScreenCaptureKit）
- 录制源实时预览（1.2）：显示器和窗口卡片约每秒刷新一次缩略图，当前选中的卡片以 12 fps 实时流预览；区域模式在显示器缩略图上标出已框选的区域。预览只保留在内存中，离开录制页立即释放
- 固定区域录制：选择显示器后拖拽框选，`Esc` 取消、`Return`/双击确认；视频、截图与鼠标坐标共用同一范围
- 点击 **Start recording** 后先显示可取消的 3 秒倒计时，倒计时结束前不会启动录制或计时
- 跨显示器、跨 Space/全屏的悬浮录制控制条，包含计时、截图、完成和取消
- 录制中截图并保存到 `~/Pictures/Focus Studio Screenshots/`
- 系统音频和麦克风开关
- 独立采集鼠标轨迹与点击，不把低分辨率系统光标烘焙进原片
- Chrome、Edge、Brave、Chromium、Firefox、Safari 网页内容预设与可调四边裁剪，可隐藏标签栏、地址栏和书签栏；书签栏可单独关闭以避免裁掉未启用书签栏时的网页顶部，窗口模式不会录入 macOS 菜单栏，原始录制保持不变

### Demo 编辑与导出

- 点击自动缩放、连续点击焦点交接，以及 Cinematic / Focused / Smooth / Gentle / Snappy 五种动画节奏；新项目默认 **Cinematic**：镜头先快速切入、再长时间平缓落定，起止两端速度与加速度均为零
- 相邻点击 pan 链接（1.2）：上一段缩放结束后 1 秒内（可在 Animation 面板调整为 0–2.5 秒）出现的下一次点击，会让镜头保持放大并平滑移动到新目标，而不是先缩回再放大；目标相距过远时仍会先缩回
- 光标动画（1.5）：渲染的自定义箭头沿 120 Hz 零相位高斯平滑的路径运动（Smooth / Medium / Rapid 对应不同平滑宽度，None 保持原始采样），并在每次点击的时刻精确落在点击位置上；箭头与 I-beam（输入框）之间以 0.14 秒交叉淡入并带轻微缩放，不再一帧切换
- 小手光标与系统光标同步（1.9）：录制时按 15 Hz 读取系统当前光标并与箭头、I-beam、小手做指纹比对（不需要任何额外权限），网页链接/可点击处显示小手、输入框显示 I-beam；辅助功能语义（`AXLink` / `AXURL`）作为后备。渲染新增小手图形（系统光标或高对比度 SF Symbol 版本）
- 缩放追踪鼠标（1.9）：放大期间镜头用临界阻尼弹簧追踪光标：视口中央 62% 软区内几乎不动，越远拉力越大，且绝不让光标越出视口外缘 90%；响应约 0.5 秒无过冲，回到全景时随包络归零
- 时间线缩放操作（1.9）：Zoom 泳道标签旁的 **+** 在播放头处添加缩放；选中缩放块后按 Delete 删除；右键空白处"在播放头处添加缩放"，右键缩放块"复制缩放 / 移除缩放"
- 手动调节过渡时刻（1.8）：自动匹配的时间可以逐段修改。检查器 Timing 新增 **Zoom in ends / 放大完成于** 与 **Zoom out starts / 缩小开始于** 两个绝对时间字段；时间线上选中的缩放块会显示放大/缩小过渡的阴影区，并提供两个内侧把手直接拖动这两个时刻，块的起止不变，编辑后该段标记为手动，不会被自动规则覆盖
- 焦点转移（1.5）：两个放大区域之间的交接 pan 按距离延长（最多比 Zoom in 多 0.25 秒，且始终在链接重叠期内落定），远距离转移不再甩镜；缩放本身保持原曲线；打字接管的镜头不延长，保证输入框及时回到画面
- 镜头跟随（1.5）：放大期间若光标离开视口中央的安全区，镜头会平滑漂移跟随（Animation → Follow cursor，默认 60%，0 关闭），镜头回到全景时漂移随包络归零
- 重叠缩放的包络以平滑并集合成，焦点从全景中心按同一曲线缓动进入，消除了交接瞬间与画面边缘约束释放时的速度突变；pan 过程叠加方向性运动模糊
- 新录制持续输入时保持焦点放大，输入结束后按可调等待时间平滑缩回；仅记录活动时间与位置，不保存按键或文字
- 紫色 Zoom 时间线：新增、选择、移动、拉伸、禁用和删除
- Auto / Manual Zoom、焦点、倍率、起止时间、Instant 参数
- 光标大小、平滑档位、闲置隐藏，以及 System / High Contrast / Dot 三种外观；可编辑文本区域自动记录为 I-beam
- 点击反馈可选择 Ripple / Halo / Pulse，调整颜色、大小、强度、时长与光标按压回弹；连续点击的动画独立淡出，预览和导出一致
- 画布比例、8 组渐变预设、自定义颜色、macOS 系统壁纸/自定义背景图片、模糊度、亮度、内边距、圆角和阴影
- 24/30/60 fps 与 1280/1920/2560/3840 宽度导出参数
- 带源音频和产品 Demo 混音的 H.264 MP4 导出
- 项目自动保存与本地项目库
- 返回项目库时安全释放预览，不再因旧编辑器读取空项目而崩溃；按编辑顺序保存，防止旧回调覆盖新项目
- 导入现有 MP4/MOV 并手动添加缩放
- 从 PNG/JPEG 截图直接创建可编辑的 12 秒 Demo，并预置三段镜头移动

### 产品 Demo 音频 finishing

新录制、导入视频和截图 Demo **不会自动添加任何音乐或音效**。只有用户在 Audio 面板点击 **Add music or effects** 并明确选择后，才会启用非破坏式混音；预览与最终导出使用相同的音频配置：

- 单独调整原始录制音量
- 从 8 首内置 BGM 中手动选择，或导入自己的音频文件
- BGM 自动循环或裁切至视频时长，并支持音量、淡入和淡出
- 根据点击事件自动加入克制的确认音效
- 在每段 Zoom 的进入和退出点自动加入柔和的 whoosh
- 从 4 种音效中选择，并可分别开关点击/缩放音效和调整音量

4 首原创 BGM 和 4 种原创音效由 [`scripts/generate-audio-assets.swift`](scripts/generate-audio-assets.swift) 程序化生成；另外收录了作者页面明确标记为 CC0 的 `City Loop`、`Overworld (BGM)`、`Calm Loop` 与 `Loading Screen Loop`。完整作者、来源、许可、SHA-256 与编码信息见 [`Resources/Audio/README.md`](Resources/Audio/README.md)。构建脚本会生成原创资源、验证网络资源哈希并打包完整目录。

## 可操控应用的 AI 助手、Codex 大脑与语音

- **助手可以操控 Focus Studio**：独立的 AI 助手窗口跨页面存活。对话即可完成整条流程：列出可录制的窗口/显示器 → 开始录制（自动倒计时）→ 停止并进入编辑器 → 增删缩放、调整镜头风格、选择背景音乐/音效、写入章节字幕 → 导出 → 生成 AI 片头/片尾并拼接。
- **两种大脑**：设置 → AI 模型里选择"默认文本模型"（任意已配置的 API Key 提供商，含 OpenRouter）或 **Codex（ChatGPT 登录）**，后者复用本机 Codex app-server，无需 API Key。工具始终在本地执行，付费生成前必须确认。
- **开箱即用**：启动时若 `~/.config/focus-studio/ark.env` 里有火山方舟密钥而应用尚未配置，会自动导入、测试并选定默认模型；设置页也有"从 ark.env 导入"。
- **语音**：麦克风按钮按下即说话（本地语音识别，跟随界面语言，静音自动停止），可选让助手朗读回复。
- **紧凑聊天界面**：1.7.1 起移除数字人与形象选择，保留 AI 助手和 Demo 导演聊天、语音及计划执行能力，安装包不再包含人物模型。
- **交互动效**：消息弹簧入场、打字指示、工具卡片展开、确认卡片滑入、建议芯片错峰出现、麦克风电平表。

## AI 模型网关与 AI 编辑（1.3）

- **设置 → AI 模型**：为 OpenAI、Anthropic、DeepSeek、GLM（智谱）、Kimi（Moonshot）、OpenRouter、火山方舟或任意 OpenAI 兼容端点填入密钥（保存在 `~/Library/Application Support/FocusStudio/secrets.json`，仅本用户可读，不进入项目或安装包），一键测试并拉取模型列表，选择一个"默认文本模型"。OpenRouter 用一把密钥即可访问多家厂商模型。Codex Director 仍走本机 Codex。
- **章节与字幕**：时间线新增 Chapters 泳道，检查器新增 Captions 工具；字幕条在预览与导出中一致渲染（可选位置、大小、章节编号），支持导出 SRT。
- **AI 编辑**：填写"这个 demo 展示什么"，AI 依据录制的点击、缩放与输入时间生成章节与字幕，也可一键润色；所有结果都可以手动修改。没有配置 AI 模型时，这些按钮禁用，其余功能不受影响。
- **AI 助手（对话式）**：编辑器顶栏 **AI** 按钮打开面板，用自然语言描述意图，助手先理解与推理，再调用工具执行：Seedream 生成背景图/标题卡并直接应用、Seedance 生成片头/片尾/B-roll（付费前显示预估费用并等待确认，支持参考图、参考视频与参考音频）、截取当前画面作参考、修改外观设置、写入章节、导出 demo 并把片头 + demo + 片尾拼接成一个 MP4。生成素材保存在项目的 `ai/` 文件夹，随时可以手动修改。项目库也提供无项目上下文的助手入口。
- **界面**：说明性文字改为工具提示，保留控件与状态，降低信息密度。

## 界面动效（1.2）

页面切换、录制源卡片选中、项目库卡片悬停、编辑器工具栏高亮与检查器切换、时间线 Zoom 块选中、倒计时数字都使用统一的 `StudioMotion` 动效词汇（0.12–0.28 秒）。系统开启"减弱动态效果"时全部退化为淡入淡出。项目库卡片显示通过正式渲染管线生成的带背景样式的首帧海报。

## AI 视频与生图 Skills（火山引擎）

`skills/` 目录提供四个 Claude Code Skills：用火山方舟 Seedance 生成片头/转场/片尾镜头、用 Seedream 生成标题卡与主视觉、把 Focus Studio 项目转成分镜 JSON，以及用 ffmpeg 把 AI 片段与录屏导出合成为企业级产品演示视频。AI 片段是可选项，不影响录制与编辑。密钥只从环境变量或 `~/.config/focus-studio/ark.env` 读取，绝不写入仓库。详见 [`skills/README.md`](skills/README.md)。

## 截图转 Demo

在项目库点击 **Screenshot demo** 或 **Animate screenshot**，选择本机 PNG/JPEG 后，Focus Studio 会：

1. 保留图片完整比例并编码为 H.264 MP4；
2. 创建 12 秒、30 fps 的可编辑项目；
3. 添加三段 Manual Zoom 作为初始镜头；
4. 不自动添加音乐或音效；
5. 进入普通编辑器，由用户继续调整背景、裁剪、镜头、光标、音频与导出参数。

源截图不会被修改或覆盖。

## Codex Director

Codex Director 让用户用聊天描述想要的 Demo，例如：

> 打开产品 Dashboard，等待页面加载，点击 Analytics，向下滚动图表，然后停留在总结卡片。

Focus Studio 会通过本机 [`codex app-server`](https://developers.openai.com/codex/app-server) 请求一个符合 JSON Schema 的结构化录制计划。当前原生 Swift 客户端使用 app-server，是为了获得适合产品内深度集成的对话、结构化输出和事件流；并没有把 TypeScript `@openai/codex-sdk` 嵌入 macOS 可执行文件。需要在 Node.js/CI 中做无界面自动化时，可使用官方 [`Codex SDK`](https://developers.openai.com/codex/sdk)。

### 使用方式

1. 在项目库打开 **Codex Director**，进入 **Connection**，选择或自动查找本机 Codex 可执行文件。
2. 点击 **Save & test connection**，使用 Focus Studio 独立登录或明确选择已有 Codex 登录；连接后选择账户可用模型，再用自然语言说明目标 URL、窗口或截图以及展示步骤。
3. 等待 Codex 生成计划，并在右侧检查目标和每一步动作。
4. 点击 **Run plan** 后，Focus Studio 才会打开目标、开始录制并执行计划。
5. 录制结束后进入编辑器，继续微调 Zoom、背景、音效和导出参数。

支持的捕获模式：

- `url`：打开并录制一个 HTTP/HTTPS 网页；浏览器窗口默认使用内容区域裁剪
- `window`：按应用或窗口标题选择一个现有窗口
- `screenshot`：从本机 PNG/JPEG 创建镜头化 Demo

### 安全边界

- Codex 线程运行在 `read-only` sandbox，且只负责生成计划，不直接操控电脑或开始录制
- 必须先看到并确认计划，Focus Studio 才会执行
- 执行器只接受 `wait`、HTTP/HTTPS `navigate`、归一化坐标 `click` 和有限幅度 `scroll`
- 不支持键盘输入、表单提交、账号修改、购买、下载、Shell 命令或破坏性动作
- 点击和滚动被限制在选中的录制窗口；无效坐标和非 HTTP/HTTPS URL 会被拒绝
- 自动点击和滚动需要单独授予 macOS Accessibility 权限

新用户可在应用里手动选取可执行文件，无需通过终端传递环境变量。自动查找支持 PATH、Codex/ChatGPT 应用内置文件和常用安装目录。路径与模型偏好保存在本机，认证由官方 Codex 处理；账号、API Key 和项目不会包含在分发包里。录制和编辑不依赖 Codex，只有 AI Director 需要单独安装和登录。

## 安装到其他 Mac

使用 `dist/releases/` 中的 DMG 或 ZIP。DMG 中将 **Focus Studio.app** 拖入 **Applications**，然后从应用程序启动。支持 macOS 15+ 的 Apple 芯片和 Intel Mac；录屏、编辑、导出不要求安装 Swift、Node.js、Homebrew 或 FFmpeg。

每台机器分别授予录屏权限；需要外部应用点击跟踪时授予输入监控。完整步骤见 [安装与首次使用](docs/INSTALL.md)。当前没有 Developer ID 证书，生成的是标记为 `local` 的本地签名包，尚未 Apple 公证；正式签名、公证命令见 [发布指南](docs/RELEASE.md)。

## 构建与运行

要求：

- macOS 15 或更高版本
- Xcode Command Line Tools / Swift 5.10 或更新版本
- Codex Director 为可选功能；使用时需要本机 Codex CLI 或 ChatGPT macOS 应用内置 Codex

```bash
chmod +x scripts/build-app.sh scripts/test.sh
./scripts/build-app.sh
open "dist/Focus Studio.app"
```

`build-app.sh` 默认构建 arm64 + x86_64 通用应用、打包音频并验证动态依赖、最低系统版本与签名；输出 `dist/Focus Studio.app`。本机快速构建可设置 `FOCUS_STUDIO_ARCHS=native`。如果机器上没有签名证书，脚本使用绑定 `com.local.focusstudio` 的 ad-hoc 签名；重新构建后 macOS 可能再次要求授权。正式发布需要 `FOCUS_STUDIO_SIGNING_IDENTITY`，使用 Developer ID 签名。

```bash
./scripts/package-release.sh
```

该命令构建通用应用并生成 DMG、ZIP、SHA-256 校验文件。只打包应用及静态素材，不复制个人项目或登录凭据。

## macOS 权限

| 权限 | 何时需要 | 未授权时的影响 |
| --- | --- | --- |
| Screen Recording | 录制画面、枚举屏幕与窗口 | 无法开始录制或选择目标 |
| System Audio | 仅在手动开启 System audio 时；默认关闭 | 视频仍可录制，但不包含应用声音 |
| Input Monitoring | 采集其他应用中的鼠标轨迹与点击 | 视频仍可录制，但自动 Zoom 的点击元数据可能缺失 |
| Microphone | 仅在启用麦克风录音时 | 不会录入旁白 |
| Accessibility | 输入时保持缩放、识别输入光标，以及 Codex Director 点击/滚动计划 | 视频仍能录制；外部输入活动、I-beam 检测和自动操作不可用 |

进入录制页和点击 Start 不会主动请求可选权限。System audio 默认关闭；只有用户手动开启它时，macOS 才可能显示系统音频提示。Input Monitoring 未授权时只显示非阻断警告，不会自动打开系统设置。

首次授权 Screen Recording、Input Monitoring 或 Accessibility 后，macOS 可能要求重启应用。请完全退出 Focus Studio，再重新打开 `dist/Focus Studio.app`。如果 Screen Recording 已显示开启但应用仍提示无权限，可将对应开关关闭再打开一次，然后重启应用。

## 测试

```bash
./scripts/test.sh
```

测试会：

- 构建所有 Swift targets；
- 运行权限状态分类测试；
- 检查时间线、动画、六种浏览器内容裁剪、区域坐标换算与旧项目兼容性；
- 生成一段确定性合成网格视频、点击事件和对应自动 Zoom；
- 通过正式渲染管线验证预览/导出一致性；
- 验证源音频、循环 BGM、淡入淡出、点击音效和 Zoom 音效可进入最终 MP4；
- 验证新项目不自动配置 BGM/点击音/Zoom 音，并验证 8 首 BGM、4 种 SFX 的 catalog 完整性；
- 检查输出尺寸、时长、缩放帧差异、裁剪区域与音视频可读性。
- 用隔离的临时项目库反复测试打开、编辑、返回、旧绑定读取与过期回调，验证最新修改落盘。

端到端产物位于 `.artifacts/e2e/`。

## 项目与文件位置

实际项目保存在：

```text
~/Library/Application Support/FocusStudio/Projects/
```

每个项目包含原始 `raw.mp4`、非破坏式 `project.json`，以及项目使用的本地音频副本。所有视觉和音频调整只修改项目元数据或项目资源，原始录制不会被覆盖。

录制中保存的截图位于：

```text
~/Pictures/Focus Studio Screenshots/
```

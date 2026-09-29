# Finlyze AI 宣传短片视觉参考（2026-09-29）

这份调研针对用户反馈的「蓝紫光线片头不好看，也不像产品宣传片」。参考的是官方发布的影片和设计说明；下面的时间点来自对公开视频逐帧抽样，指向可观察的画面，**不是**精确剪辑点或可直接复用的素材。Finlyze 应建立自己的色彩、文字和动效系统，不复制其他公司的标志、界面或成片。

| 官方参考 | 观察到的画面 | 对 Finlyze 的设计推论 |
| --- | --- | --- |
| [Apple — Apple Intelligence | Privacy](https://www.youtube.com/watch?v=546ufMY7488) | [0:00](https://www.youtube.com/watch?v=546ufMY7488&t=0s) 白底、简短双色标题；[0:40](https://www.youtube.com/watch?v=546ufMY7488&t=40s) 单一芯片图形周围有柔和光晕；[1:10–1:30](https://www.youtube.com/watch?v=546ufMY7488&t=70s) 关系线、图标和设备轮廓围绕一个主题出现。 | 留白和单一主角比堆叠材质更有分量。将动效集中在一个真实的产品信息上。Apple 的[动效指南](https://developer.apple.com/design/human-interface-guidelines/motion)同样要求动效传达状态、反馈或指引，保持简洁。 |
| [Google — Introducing Gemini 2.0](https://www.youtube.com/watch?v=Fs0t6SdODd8) | [0:18–0:36](https://www.youtube.com/watch?v=Fs0t6SdODd8&t=18s) 深色背景中的细线、光点用于连接能力章节；[0:42–1:18](https://www.youtube.com/watch?v=Fs0t6SdODd8&t=42s) 转入真实使用场景；[1:30–1:48](https://www.youtube.com/watch?v=Fs0t6SdODd8&t=90s) 显示真实的 Agent 输入和执行界面。 | 抽象图形只是章节标点；真正使「AI」可信的是产品操作和结果画面。不要把整条片子做成光束穿梭。 |
| [Google DeepMind — A new era of intelligence with Gemini 3](https://www.youtube.com/watch?v=98DcoXwGX6I) | [0:42–0:48](https://www.youtube.com/watch?v=98DcoXwGX6I&t=42s) 输入框到实际结果；[0:54](https://www.youtube.com/watch?v=98DcoXwGX6I&t=54s) 品牌符号短暂充当段落铰链；[1:12–1:30](https://www.youtube.com/watch?v=98DcoXwGX6I&t=72s) 多种产出画面的蒙太奇。 | 让一次真实问题→真实结果形成短镜头的骨架；品牌动效只在换章时出现。 |
| [Google Workspace — Introducing Google Vids](https://www.youtube.com/watch?v=4SCjXcBeW1E) | [0:00–0:12](https://www.youtube.com/watch?v=4SCjXcBeW1E&t=0s) 白底大字、局部柔和蓝色过渡；[0:42](https://www.youtube.com/watch?v=4SCjXcBeW1E&t=42s) 真实的语音选择界面；[1:00](https://www.youtube.com/watch?v=4SCjXcBeW1E&t=60s) 真实编辑器时间轴。 | 让一句利益点短标题和具体 UI 操作交替出现。剪辑、字幕和声音可以给 UI 节奏，无须把 UI 交给视频模型重绘。 |
| [Notion — Introducing the new Notion AI](https://www.youtube.com/watch?v=S92KX8-Hmlc) | [0:03](https://www.youtube.com/watch?v=S92KX8-Hmlc&t=3s) 白底黑字一句主张；[0:12–0:18](https://www.youtube.com/watch?v=S92KX8-Hmlc&t=12s) 真实助手面板；[0:30–0:39](https://www.youtube.com/watch?v=S92KX8-Hmlc&t=30s) 真实内容分析界面；[0:45](https://www.youtube.com/watch?v=S92KX8-Hmlc&t=45s) 饱和色块切换到移动端。 | 用户给出的第二张截图与这种「真实产品 + 图形注解」相近：真正应生成的是可控的注解、转场和氛围层，而非伪造一个仪表盘。 |

[Google Design 对 Gemini 视觉语言的拆解](https://design.google/library/gemini-ai-visual-design)进一步说明：渐变是引导注意力的线索，运动要有明确起点和终点，并与产品操作关联。这是其设计团队的说明；把它用于 Finlyze 的判断是本调研的推论，不能把 Gemini 的形状或配色直接搬过来。

## 为什么旧的抽象 prompt 失效

仓库原有 [Seedance 提示词参考](../skills/ark-video-clip/references/prompting.md)把「磨砂玻璃面板、紫靛渐变、边缘发光、体积光、漂浮粒子」拼成片头，却没有 Finlyze 的真实界面、具体功能、用户问题或镜头中的信息层级。这样的描述很容易得到通用科幻光束，无法证明产品价值。单纯换更贵的模型不能修复这个创意问题。

## 三个原创镜头方向

下面每段为 5–8 秒的可执行镜头，**真实录屏和真实文字由 Focus Studio 合成**。生成模型只做没有数据与文字的背景、环境或过渡。颜色应从 Finlyze 实际界面/品牌资产提取，不能预设为 Gemini 的蓝紫色。

### A. 从噪声到判断（7 秒，产品主镜头）

- **0–1.5 秒：** 在中性深色背景上摆出真实 Finlyze 仪表盘，保留大量周边留白。若画面较密，先用裁切/模糊让主信息之外的内容退后。
- **1.5–4.5 秒：** 用 Focus Studio 的原生 zoom 推近真实录屏中的一个趋势或 AI 结论，数值、文字和坐标始终来自原始录屏。细线和标注框需在支持叠加图层的工具中制作，当前不作为原生能力承诺。
- **4.5–7 秒：** 拉回完整界面，叠加一句经用户确认的利益点文案，停留至少 1 秒供阅读。可选背景生成物仅是安静的暗面和非常轻的局部光，禁止穿梭隧道、漂浮玻璃片或假图表。

### B. 编辑式产品介绍（6 秒，浅色极简）

- **0–1.5 秒：** 米白或品牌浅色底，单行大字提出一个具体任务，例如「更快看清关键变化」；文字在编辑器原生绘制。
- **1.5–4.5 秒：** 用一次淡入或直接剪切到真实 UI，一个鼠标动作或分析结果是唯一的主动作；用已有点击动画与 zoom 引导视线。蒙版展开需额外合成工具。
- **4.5–6 秒：** 界面稳定，标题缩为小标签，留给下一段产品录屏一个可剪辑的静止尾帧。过渡只有一次，色块和字体从 Finlyze 自身品牌提取。

### C. 从工作场景进入产品（8 秒，人物/空间）

- **0–2.5 秒：** 生成或拍摄整洁、真实的办公空间；屏幕是无字的中性占位面。镜头慢慢靠近屏幕，环境的光线、桌面材质都为画面服务。
- **2.5–4 秒：** 在镜头靠近屏幕时直接匹配剪切到**真实 Finlyze 录屏**，避免出现伪造界面。四点跟踪/透视替换需要额外合成工具，当前 Focus Studio 不提供该能力。
- **4–8 秒：** 演示一个真实任务和结果，可叠加一条矢量引导线和一句简短结论。不要让生成模型绘制界面文字或虚构财务数据。

### 给 AI 助手的执行顺序

1. 先读取当前项目的真实录屏、目标用户与品牌资产，要求用户选定一个要传达的**产品收益**；缺少截图或品牌颜色时给出可编辑的建议，不凭空编数据。
2. 提出 2–3 套有时间轴的分镜，并明确哪些层用生成模型、哪些层由编辑器合成。先预览风格关键帧，再为所选镜头生成运动，不要一次生成多个昂贵视频。
3. 生成前选择实际可用的模型、时长、比例、分辨率与费用；按用户确认的模型调用，不静默降级。Google Flow 的[官方工作流](https://support.google.com/flow/answer/16353334?hl=en)也把模型选择、参考素材、首尾帧、时长列为生成前的选择项；这是可借鉴的产品交互，不代表 Focus Studio 已支持其模型。
4. 在 Focus Studio 内预览成片，核对画质、时长、文字/数据保真、镜头稳定和与前后片段的连接；满意后先存通用素材库，再由用户选择导入当前项目并放入时间轴。对已有录屏片段做 AI 优化时，默认保留其原始画面，生成的是可撤销的叠加层或新副本。

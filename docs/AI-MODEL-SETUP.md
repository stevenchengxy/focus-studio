# 配置 AI 对话与视频生成

Focus Studio 把“谁来回答对话”和“谁来生成素材”分开配置。Codex 或 OpenAI 等文本模型负责规划、写提示词和编辑；视频可选火山方舟 Ark 的 Seedance，或 Google Gemini API 的 Veo。图片使用 Ark 的 Seedream。配置文本模型的 API Key 不会自动获得视频生成权限。

## 新安装后的最短路径

1. 在 Focus Studio 的“设置 → AI 模型”打开 **AI 视频与图片**，选择视频提供商。Seedance 选 Ark；Veo 选 Gemini。点击“配置视频密钥”。
2. Seedance/Seedream：在[火山方舟控制台](https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey)创建 API Key。Veo：在 [Google AI Studio](https://aistudio.google.com/app/apikey)创建 Gemini API Key。进入相应提供商的配置页粘贴密钥，点击“保存”，再点击“测试”。两个提供商的密钥各自独立，保存在本机当前用户的 `~/Library/Application Support/FocusStudio/secrets.json`（目录 0700、文件 0600），不会写入项目文件或偏好设置。
3. 在上方选择视频、图片模型。Ark 视频预设为 `doubao-seedance-2-5-260628`（Seedance 2.5）；Gemini 视频预设为 `veo-3.1-generate-preview`（Veo 3.1）。图片模型是 Seedream，始终使用 Ark 密钥。“提供商未列出”表示尚未测试，或当前账号的模型列表没有返回这个**完整 ID**；不要把它当成已开通权限。模型下拉菜单显示模型完整 ID，测试后标识接口实际列出的 ID。
4. 打开 AI 助手描述片段。每次付费生成前再检查模型、时长、分辨率和费用确认框；如果选定模型不可用，任务应报错并保留选择，不会自动换成 Seedance mini。

如需聊天规划，在同一页选择 AI 助手使用的 Codex 账户或文本模型，并按对应提供商的配置页保存其 Key。Gemini/Veo 在这里是**视频专用**，不会被误选为对话模型。自定义 OpenAI 兼容地址目前只用于文本聊天，不能当成任意视频生成 API 使用。提供商的模型列表测试验证密钥和可列出的模型；具体视频模型是否具备调用权限，最终仍以生成接口的结果为准。

模型名称和能力以[火山方舟官方模型列表](https://docs.volcengine.com/docs/ark/model-list?lang=zh)及 [Google 官方 Veo 文档](https://ai.google.dev/gemini-api/docs/veo)为准；列表会更新，所以 Focus Studio 显示完整模型 ID，并且不根据名称猜测可用性。

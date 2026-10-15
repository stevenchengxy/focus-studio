# 社区客户端确认验证（2026-10-15）

## 用户规则

- 访客可浏览公开内容。
- 创建上传草稿、上传视频/封面、编辑和发布内容，必须使用 ChatGPT 登录，并在安装后启动的客户端完成一次确认。
- 下载点击、浏览器批准连接码、取得设备 token 均不单独开通发布资格；必须再完成客户端回连。
- 确认记录绑定 ChatGPT 身份，过期或撤销设备 token 不删除已完成的一次性资格。
- 删除、撤回、举报、个人资料与管理员审核仍保留原权限。

## 实现

新增独立 community 用途的设备配对和凭据。普通 account token 无法确认社区，community token 无法访问旧账户/账单鉴权路径。浏览器的旧 Google cookie 不覆盖社区的 ChatGPT 身份。Mac 仅正式 `/Applications/Focus Studio.app` 可执行确认；Electron 主进程要求 `app.isPackaged`。前端不会持有设备 token。

追加 D1 迁移 `0006_slimy_thunderball.sql`：新增永久确认表和设备用途字段，旧设备默认 account；未修改已应用的迁移。生产发布由 Sites 在上传 Worker 前应用新增迁移。

这是客户端配对及回连确认，不是硬件或官方二进制的远程证明。自定义客户端仍可能模拟公开协议，因此不能声称绝对防伪。

## 已完成验证

| 验证 | 结果 | 范围 |
| --- | --- | --- |
| 网站服务端测试 | 83/83 PASS | 包含社区权限、设备purpose隔离、ChatGPT/Google身份分离、token过期/撤销、浏览器Origin、幂等确认及永久资格 |
| TypeScript | PASS | 最终UI及账户身份显示 |
| moderation HTTP | 91 checks PASS | 本地构建Worker、合成身份、完整配对与回连；测试内容已删除 |
| 原生客户端回归 | PASS | 真实app源编译，模拟transport和内存vault验证状态、取消、回连回执与独立凭据 |
| 原生离线免费导出回归 | PASS | 未登录reserve/commit/recovery及手动/MCP导出 |
| Mac最终Universal包 | PASS | arm64+x86_64、1513个匹配翻译键、两架构MCP helper、DMG校验及ZIP解包验证 |
| Electron单测 | 41/41 PASS（含17项社区） | 独立加密凭据、可信origin、purpose、取消/超时/迟到响应 |
| Windows/Linux真实Electron及安装包CI | PASS | [run 38701067753](https://github.com/stevenchengxy/focus-studio/actions/runs/38701067753)，提交dc01c894；此后提交未改变desktop源 |
| 网页人工观察 | PASS | 未登录只显示ChatGPT入口；本地模拟已登录但未确认时显示连接步骤，隐藏上传表单；刷新仍维持正确门禁 |

页面截图：`.artifacts/installation-validation/community-client-required-zh.png`。界面验证使用本地预览及模拟身份，没有创建生产帖子，也没有操作用户的真实ChatGPT登录。

## 验证边界

普通HTTP串行脚本在本地Wrangler多次遇到503“worker restarted mid-request”或超时；单独请求同路径返回预期403。原始失败日志保留为 `.artifacts/installation-validation/community-http.log`，不能计为已通过的完整测试。

没有替换用户当前正在运行的旧版，也没有完成真实账户的浏览器登录到各平台客户端回连的人工验收。Mac包本地签名，未经过Apple公证。最终安装验证见同目录 `2026-10-15-installation-1.14.6.md`。

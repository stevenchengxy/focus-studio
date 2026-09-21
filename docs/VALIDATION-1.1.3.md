# Focus Studio 1.1.3（build 5）验证记录

本次范围：录屏库多选、全选 / 取消全选、确认后批量移到废纸篓，以及逐项目重命名。最低构建目标为 macOS 15.0；验证机器为 Apple Silicon、macOS 26.2。

## 双语和版本资源

`Resources/Info.plist` 更新为版本 1.1.3、build 5。新录屏库控件、确认提示、字符数和项目存储错误均提供英文与简体中文。当前两种语言各 537 个键，键集合和格式占位符一致；权限说明完整，`plutil -lint` 通过。项目标题和文件路径属于用户内容，不经过翻译。

## 删除安全边界

移到废纸篓的目标以项目 UUID 定位在应用管理的项目目录内，不使用录屏标题、外部媒体路径作为删除目标。不允许借助符号链接或错误的项目元数据扩大操作范围。批量操作中成功和失败分别报告，失败不会退化为永久删除；新安装包不包含用户录制或凭据。

## 自动化回归

`zsh scripts/test-app-regression.sh --skip-build` 通过。新增 `Tests/FocusStudioAppRegression/ProjectLibraryRegression.swift` 覆盖：

- 选择、Shift 连续选择、列表更新后清理失效选择。
- 三个项目选中两个移动到可恢复的模拟废纸篓，未选中的第三个不受影响。
- 部分删除失败时只移除成功项目，失败保留且可重试，不使用永久删除作为后备。
- 30 次排队编辑保存及失效编辑器绑定不会在删除后重建项目；重命名与删除的双向并发互斥。
- 名称去除首尾空白、空名和超长名称拒绝、Unicode、重复名称，以及保存后重新加载。
- 重命名保持缩放、音乐、背景与媒体字节不变；嵌套 / 绝对视频路径和未知 JSON 字段保持不变，只有标题变化。
- 缺失项目、项目目录 / 元数据符号链接、元数据 UUID 不匹配被拒绝；项目库路径没有尾斜杠也可以正常工作。

全部测试只在新建 UUID 临时目录与模拟废纸篓执行，结束后清理测试目录，没有操作用户项目或真实废纸篓。既有权限、50 次导航返回、逐段缩放编辑与保存回归同时通过。

主任务对最终冻结源码再次完成 `swift build --product FocusStudio`、537 键语言目录验证、隔离用户偏好的语言选择测试及完整 AppRegression，均通过。构建仅报告已有的 macOS 26 `Text` 拼接弃用警告，没有编译错误。

## 实机与安装包

用户正在使用旧版本，尚未回复现场 UI 验收协调请求。因此本次没有重启应用、进行真实废纸篓操作或声称完成 GUI 端到端测试。

构建和打包脚本支持 `FOCUS_STUDIO_APP_DIR` 明确输出到独立候选目录，默认位置不变；拒绝相对路径、`dist` 之外的位置及符号链接路径。已验证 `/tmp/Focus Studio.app` 和相对路径被拒绝。候选输出父目录自动创建，临时构建和替换范围限制在该目录。

最终 Universal 2 的 `arm64` / `x86_64` release 切片编译通过，应用位于 `dist/candidates/1.1.3/Focus Studio.app`，不是当前运行的 `dist/Focus Studio.app`。候选应用、ZIP 解压副本均通过版本 1.1.3 / build 5、双架构、macOS 15 最低系统版本、代码签名、系统框架依赖、图标、537 键双语资源及 10 个音频素材验证。DMG 完整性校验通过。打包仅包含应用、安装说明、Applications 快捷方式及发布状态，不含用户项目或凭据。

交付文件：

- `dist/candidates/1.1.3/Focus Studio.app`
- `dist/releases/Focus-Studio-1.1.3-universal-local.dmg`
- `dist/releases/Focus-Studio-1.1.3-universal-local.zip`
- `dist/releases/Focus-Studio-1.1.3-universal-local.sha256`

候选应用可执行文件 SHA-256：`ae8ddc2a8a2d8d56c480e28d415771211ac640795130ee44eb183f456bdcb584`。

原位置应用仍为 **1.1.2**，构建前后可执行文件 SHA-256 均为 `737435e842614702a276535fe61d0a1e10798838b4666dfa97227a034d408e78`，其签名复验通过；没有替换、启动或退出它。

当前机器没有有效签名身份，安装包采用 ad-hoc 本地签名，未通过 Apple 公证。Intel 仅经过交叉编译和结构验证，尚未实机运行；macOS 15 兼容声明来自构建目标，实际测试环境为 macOS 26.2。

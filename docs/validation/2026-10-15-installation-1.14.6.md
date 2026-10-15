# 1.14.6（build 68）· 首次安装与旧版替换验证

本次针对网页下载后从 `AppTranslocation` 临时目录运行，以及新旧副本同时存在造成冲突的问题，补充首次安装引导、旧安装归并和安装后的应用切换。安装专项、切换协调、翻译、应用回归及最终 Universal 2 打包检查已通过；最终候选的中文首次启动界面已观察。新版尚未发布，干净 Mac 上的完整安装链路仍待验收。

## 代码与行为

- 版本由已发布的 1.14.5（build 67）提升为 **1.14.6（build 68）**。修复基线是 `codex/studio-launch` / `v1.14.5-preview.1`，对应提交 `2ea725053ab0c68efb7624dfb5b7192b255dc059`。
- `FocusStudioApp.swift`、`AppServices.swift` 和 `InstallationSettingsView.swift` 增加启动阶段的安装引导。下载、磁盘映像或临时目录里的 app 先显示“安装并打开 / 更新并打开”；进入正式使用前处理安装位置和其它运行副本。
- `AppInstallation.swift` 仅检查 `/Applications` 和当前用户 `~/Applications` 的顶层真实 `.app` 目录，按应用标识及可执行文件名识别 Focus Studio，包括改名副本。符号链接、无关软件、下载和开发目录不作为全盘清理对象，当前运行的安装源会保留。
- 统一目标为 `/Applications/Focus Studio.app`。先暂存、校验版本、内容和签名，再替换；拒绝降级和同版本同 build 的内容冲突。旧安装以 `previous.bundle` 等名称保留在隐藏恢复目录，`recovery.plist` 记录原路径；事务失败时尝试恢复各原安装。
- `AppInstallationHandoff.swift` 协调其它副本正常退出，并等待退出结果；拒绝退出、超时、取消或等待期间出现新副本时停止安装。文件替换前再次检查运行状态，不强制结束用户进程。启动目标后验证其实际路径，再退出下载副本。
- 启动准备只适用于用户主动执行安装时、与 `Bundle.main.bundleURL` 相同的当前运行源。安装器在暂存副本通过签名及内容校验后，移除该副本范围内的 `com.apple.quarantine`；不遍历符号链接，不改原始下载、不改链接目标，不更改 Gatekeeper 全局设置。默认安装器和外部 CLI 来源不执行此处理。同版同内容的暂存重装用于修复已复制但仍保留隔离标记的目标；不能以此绕过版本或内容冲突检查。
- 处理器架构改用 Foundation 的 `Bundle.executableArchitectures` 检查，安装时不再调用依赖开发工具的 `lipo`。发布构建本身仍可使用开发工具。
- DMG/ZIP 增加 `INSTALL-FIRST.txt`，安装文档及网站帮助同步说明新流程、备份和失败恢复。网站下载链接及 release feed 尚未切到 1.14.6。

## 已完成检查

| 检查 | 结果与证据 | 验证范围 |
| --- | --- | --- |
| `zsh scripts/test-installation.sh` | **PASS**；日志 `.artifacts/installation-validation/installer.log` | 临时目录 fixture：版本比较、降级/同 build 冲突、签名失败注入、暂存、锁、改名/个人应用目录发现、运行源保留、运行中与检查期间启动保护、多副本回滚、项目文件保留。未替换真实应用。 |
| 隔离标记专项（同一 installation 测试） | **PASS**；日志明确包含 `quarantine default`、`verified-copy preparation`、`symlink boundary`、`preparation failure/mutation`、`identical-build repair` | 使用真实临时文件扩展属性，验证默认/CLI 路径保留隔离标记，准备只改变暂存副本，原源及外部符号链接目标不变，失败或内容变化阻止替换，运行中修复被拒绝。签名验证以测试依赖注入隔离，不代表 Gatekeeper 实际放行。 |
| `zsh scripts/test-installation-handoff.sh` | **22 项通过**；`.artifacts/installation-validation/handoff.log` | 启动位置策略、当前 PID 不被请求退出、其它副本正常退出及等待、拒绝/超时/竞态/新副本/取消保护。全部使用进程替身，不启动或结束用户进程。 |
| `swift scripts/test-localization.swift` | **PASS：1513 个中英文匹配键**，占位符和权限描述通过 | 最终打包直接复核当前资源目录，包含新增社区连接文案。 |
| Debug 应用编译 | **PASS**；`.artifacts/installation-validation/debug-build.log` 末尾为 `Build complete!` | 验证应用与安装界面编译。最终发布切片以稍后的打包结果为准。 |
| 完整 app regression | **PASS**；`.artifacts/installation-validation/app-regression.log` 末尾为 `FocusStudioAppRegression: PASS` | 编辑/保存、录制状态机、助手、自动化桥、控制服务、MCP 接入及临时项目的 MCP 端到端导入/编辑/导出。相关录制用例明确不执行真实屏幕捕获，不能据此宣称重新完成真实录屏验收。 |
| 发布脚本及元数据静态检查 | `git diff --check`、`zsh -n scripts/package-release.sh`、`plutil -lint Resources/Info.plist` 通过 | 补充说明文件、脚本语法及版本元数据；不代替产物验证。 |

## 实际界面观察

已查看最终候选应用的中文首次启动界面，截图为 `.artifacts/installation-validation/first-launch-final-zh.png`。画面显示“安装 Focus Studio”、当前副本 **1.14.6**、“退出”和“安装并打开”按钮，并说明安装时请求其它版本正常退出、备份被替换的应用、保留项目及登录信息。随后通过界面的“退出”关闭测试副本，并以进程列表确认已退出。

这张截图证明安装入口和中文文案已渲染，不证明已经点击安装、更换真实应用或完成重启交接。

本次未安装到或替换真实 `/Applications`。用户原先运行的旧版保持运行；记录时只读查询仍显示该进程从 `AppTranslocation/.../Focus Studio.app/Contents/MacOS/FocusStudio` 启动，未对其执行退出或替换。

## 最终 Universal 2 产物

最终发布构建和打包已成功，日志为 `.artifacts/installation-validation/package-final.log`。这次构建覆盖隔离标记处理、Foundation 架构检查及新增原生社区连接；此前的 `package.log` 不作为最终候选证据。

| 项目 | 当前状态 |
| --- | --- |
| arm64 + x86_64 应用和 MCP helper 构建 | **PASS**；应用和 helper 均包含两个架构 |
| 最终候选 app 路径与版本/build | `dist/Focus Studio.app`，**1.14.6 / 68** |
| `verify-release.sh --require-universal`、签名完整性和 helper 冒烟检查 | **PASS**；helper 两个架构均返回 54 个工具，x86_64 经 Rosetta 运行 |
| DMG/ZIP 最终路径、大小、SHA-256 | 见下表；校验文件在 `dist/releases/Focus-Studio-1.14.6-universal-local.sha256` |
| DMG 完整性、ZIP 解包后的 app 验证、`INSTALL-FIRST.txt` | **PASS**；`hdiutil verify` 为 VALID，解包后重新通过完整 app 检查，说明文件已包含 |
| 最终 app 的安装器只读检查 | **PASS**；`scripts/install-app.sh "$PWD/dist/Focus Studio.app" --check` 验证真实签名与 Foundation 架构读取，日志 `real-bundle-check.log`；未安装、未停止应用 |
| GitHub release / 官网下载切换 | **未执行** |

| 文件（均位于 `dist/releases/`） | 字节数 | SHA-256 |
| --- | ---: | --- |
| `Focus-Studio-1.14.6-universal-local.dmg` | 71,786,262 | `b448662c26c222f576808aeb418130b6832fec9e0fef9c2c285002474307ac09` |
| `Focus-Studio-1.14.6-universal-local.zip` | 67,940,051 | `f801b86f9ccf4d8daa22be6f54aaf6e8682e5271cd3850ed5545fc5f5392592c` |

## 签名与验收边界

本机只读执行 `security find-identity -v -p codesigning` 返回 **0 valid identities found**。本次没有可用 Apple 开发者签名身份，也没有完成 Apple 公证；后续即使本地签名包通过 `codesign --verify`，也只说明该包签名结构和内容校验通过，不能称为 Developer ID 认证或 Apple 公证通过。

本次没有在干净 Mac/新用户环境里，从真实网页下载最终 DMG/ZIP，再完成 Gatekeeper 首次启动、安装替换、旧版退出、canonical 路径重启和录屏权限检查。隔离标记专项验证的是临时文件的处理边界；中文截图验证的是界面；进程替身验证的是协调逻辑，三者不能合并宣称这条完整链路已验收。

尚待独立验收的场景包括：干净 Mac 首装、真实浏览器下载的 AppTranslocation 启动、实际旧版运行及拒绝退出、多个真实安装副本、安装后重启路径与用户数据读取、Gatekeeper 行为、Intel 实机。网站帮助仅更新了源文件，尚未作为网站部署或新版下载已上线的证据。

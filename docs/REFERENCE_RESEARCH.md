# Product reference research

Focus Studio was implemented independently in Swift using Apple's public macOS frameworks. No Recordly source files are included in this repository.

The following products were used to validate feature scope and terminology:

- [Screen Studio](https://screen.studio/) and its official guide: recording targets, automatic/manual zooms, editable purple zoom timeline, cursor controls, background/frame styling, aspect ratios, and MP4/GIF export.
- [Recordly](https://github.com/webadderallorg/Recordly): an AGPL-3.0 open-source alternative that confirms the practical architecture of native capture plus separate cursor telemetry and a renderer-driven editor.

Recordly is AGPL-3.0 and has explicit branding/attribution conditions. For that reason, this project does not copy or vendor its implementation. Recordly was used only as an external behavioral benchmark while the local native implementation, data model, timing math, renderer, tests, and UI were authored separately.

## 1.2 调研：缩放动效、特效与音乐（2026-09-21）

以下开源项目仅作为行为参考，没有复制任何源码：

| 项目 | 许可 | 参考点 | 本版本采纳 |
| --- | --- | --- | --- |
| [OpenScreen](https://github.com/siddharthvaddem/openscreen) | MIT | 自动/手动缩放、光标平滑与点击效果；[PR #674](https://github.com/getopenscreen/openscreen/pull/674) 用哈希锁定 CC0 曲库并归档许可页面 | 曲库继续按 SHA-256 + 作者页 CC0 声明收录 |
| [FollowCursor](https://github.com/sabbour/followcursor) | 开源 | 作者[文章](https://sabbour.me/2026/03/23/building-followcursor.html)指出"链接相邻活动、保持放大并 pan"比物理模拟更能消除抖动 | 相邻点击 pan 链接（`zoomChainGap`） |
| [Screenize](https://github.com/syi0808/screenize) | 开源（已暂停） | 弹簧物理相机与按活动类型规划缩放级别 | 以闭式 C2 曲线（`cinematicEase`）代替积分器，保证逐帧可复现 |
| [Cursorfly](https://github.com/anugotta/cursorfly-screen-recorder) | 开源 | 点击感知的电影式 pan/zoom | 曲线形态参考 |
| [open-recorder](https://github.com/imbhargav5/open-recorder) | 开源 | 原生 Swift 的轻量 Screen Studio 替代 | 结构验证 |
| [Recordly](https://github.com/WizardofTryout/recordly) | AGPL-3.0 | 编辑器布局基准（见上文） | 不引入代码 |

音乐来源沿用 OpenGameArt 上作者页明确标注 CC0 的作品（`Calm Loop`、`Loading screen loop` 新增）；FreePD 原站已于 2025 年关闭，镜像站不作为来源；Pixabay / Mixkit 的许可不允许在桌面编辑器中以独立素材形式分发，未采用。

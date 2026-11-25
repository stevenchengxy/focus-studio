# Focus Studio 正式版签名与 Apple 公证

**1.14.11 / build 74** 为可关闭录屏背景的预览更新，频道为 `preview`，保留应用内选屏。Apple 公证仍待开发者会员和签名凭据就绪；正式版必须使用高于已发布预览版的新版本号（下一候选为 1.14.12 / build 75），并将更新频道设为 `stable`。

2026-11-20 本机检查结果：`security find-identity -v -p codesigning` 返回 **0 valid identities**；没有查到 Developer ID Application 证书，也未指定 `FOCUS_STUDIO_NOTARY_PROFILE`。因此尚未向 Apple 提交公证。

## 在本机配置一次

1. 使用有权限的 [Apple Developer Program 账号](https://developer.apple.com/programs/enroll/) 登录开发者网站。会员通常为每年 99 美元或当地货币等值；账户持有人自行完成身份确认、协议和付款。已加入的账户不用重复开通。
2. 按 [Apple 的证书指引](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) 在本机创建并安装 **Developer ID Application** 证书。在“钥匙串访问 → 我的证书”中，它必须带有配对私钥。只有 `.cer` 而没有私钥不能签名；不要把 `.p12`、私钥或密码发到聊天或提交到 Git。
3. 在自己的 Terminal 中运行下面的交互命令。按提示输入 Apple 账号、Team ID 和 App 专用密码，工具会把凭据保存在钥匙串中并验证。不要把密码直接写进命令行。

```sh
xcrun notarytool store-credentials 'focus-studio-notary'
```

4. 在同一个 Terminal 中设置公证 profile。若只有一个有效 Developer ID Application，构建脚本会自动找到；有多个团队时明确指定证书完整名称。

```sh
export FOCUS_STUDIO_NOTARY_PROFILE='focus-studio-notary'
# 多个团队时，将下方值替换为 security find-identity 输出中的证书名称。
# export FOCUS_STUDIO_SIGNING_IDENTITY='Developer ID Application: Your Company (TEAMID)'
zsh scripts/check-notarization.sh
```

配置完成后只需告诉 Codex **profile 名称**以及必要时证书名称；这些不是密码。Shell 的 `export` 不会自动传到已经运行的 Codex，后续构建需要明确使用对应变量。

## 构建、公证与发布

凭据就绪后，先在 `Resources/Info.plist` 更新正式版本号、build 和 `stable` 频道，再使用独立构建目录（以下以 1.14.12 为例）：

```sh
FOCUS_STUDIO_NOTARY_PROFILE='focus-studio-notary' \
FOCUS_STUDIO_APP_DIR="$PWD/dist/stable-1.14.12/Focus Studio.app" \
zsh scripts/package-release.sh
```

脚本为 Apple Silicon 和 Intel 构建，先签 MCP helper 再签 App，启用 hardened runtime 和安全时间戳；将 App archive 提交给 Apple，staple/validate 后再构建、签名、公证和 staple DMG。正式频道在缺少有效签名身份或公证配置时会提前停止。App 与 DMG 都需要通过 Gatekeeper 评估；公证失败不得改名冒充 `notarized`。

发布前仍需验证应用内屏幕／窗口／区域选源、首次权限、暂停恢复和停止，并从下载的安装包测试安装/升级。Apple 公证是分发安全检查，不代表功能验收或 App Store 审核。原来的本地签名切换为 Developer ID 后，macOS 或 MCP 客户端可能要求重新确认权限。

通过上述检查后使用新的正式 tag（例如 `v1.14.12`）发布对应的 `Focus-Studio-1.14.12-universal-notarized.dmg`，不替换已经发布的预览文件。同步官网 Mac 正式版文案和下载 fallback，刷新 `release-feed`，验证 `channel=stable`、网站实际下载和旧客户端更新提示。Windows/Linux 仍保留其预览状态。

官方参考：[公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[命令行公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[会员费用](https://developer.apple.com/help/account/membership/program-enrollment/)。

# Kestra 自动更新

Kestra 使用 Sparkle 2 的标准更新器。应用启动后由 Sparkle 按 `SUScheduledCheckInterval` 自动检查 GitHub Release 的 appcast；用户确认后下载 `.zip`，先验证 Sparkle Ed25519 签名，再重启替换应用。应用内设置页也提供“检查更新”。

## 发布配置

### 1. 生成 Sparkle 签名密钥

从 Sparkle 发布包的 `bin/generate_keys` 运行一次：

```bash
./bin/generate_keys
./bin/generate_keys -p
./bin/generate_keys -x /private/tmp/kestra-sparkle-private-key
```

私钥应留在本机钥匙串或安全的 CI Secret 中，不能放进 Git。将导出的私钥内容保存为 GitHub Actions Secret：

```bash
gh secret set SPARKLE_ED25519_PRIVATE_KEY < /private/tmp/kestra-sparkle-private-key
```

`script/build_and_run.sh` 中的 `SUPublicEDKey` 是对应的公开密钥，可以提交；私钥不能提交。

### 2. 生成发布包

推送 `v*` tag 后，`.github/workflows/release.yml` 会：

1. 构建并签名 `Kestra.app`；
2. 生成用于 Sparkle 的 `Kestra-v*.zip`；
3. 用 `generate_appcast` 生成带 Ed25519 签名的 `appcast.xml`；
4. 将 DMG、ZIP 和 appcast 上传到 GitHub Release。

应用读取的 feed 地址是：

```text
https://github.com/qyuja/Kestra/releases/latest/download/appcast.xml
```

没有 `SPARKLE_ED25519_PRIVATE_KEY` 时，workflow 会跳过 ZIP/appcast，只发布 DMG，避免生成无法验证的更新包。

## 本地验证

本地构建默认不启动 Sparkle，避免开发时访问尚未发布的 feed。配置公开密钥后可以手动构建：

```bash
SPARKLE_ENABLED=true ./script/build_and_run.sh package
```

然后检查：

```bash
codesign --verify --deep --strict dist/Kestra.app
plutil -p dist/Kestra.app/Contents/Info.plist | grep -E 'SUFeedURL|SUPublicEDKey|SURequireSignedFeed'
```

自动更新包仍应使用真实发布构建验证；仅通过 Swift 测试或本地 ad-hoc 签名，不能证明另一台 Mac 上的 Gatekeeper 和更新安装流程已经验收。

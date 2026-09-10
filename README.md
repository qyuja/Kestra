# Kestra

Kestra 是一个面向 macOS 26 的原生状态栏 AI coding agent 任务雷达：在后台监听本地 agent 客户端，把运行中任务数、任务摘要和完成提醒放到一个随时可见的状态栏入口里。

## 功能

- 状态栏图标显示运行状态；默认使用 Barbell Squat runner：没有任务时站立，有任务时深蹲，并发任务越多速度越快。
- 任务 popover 中查看 Active / Recent 任务、thread name、最近一条 user 对话摘要、模型和 effort。
- 支持客户端 tab、任务展开收起、运行时长和完成时间展示。
- 任务完成后从屏幕指定位置弹出可点击的完成提醒，支持边、角和中心位置，以及独立的 In / Out 动画、速度和停留时长设置。
- 账号管理和手动切换目前面向 Codex / ChatGPT 与 Claude Code；切换前会阻止仍有运行任务的账号操作。
- 状态栏图标支持资源型插件，可使用 PNG 帧或 macOS System Symbol，不加载或执行插件代码。

## 已接入的任务来源

目前代码包含以下本地客户端适配：

- Codex / ChatGPT：通过本地 `codex app-server` 和 session 状态读取任务。
- Claude Code：通过 CLI Hooks 读取任务，并提供账号登记、重登和手动切换。
- Cursor、Pi、OpenCode、Gemini CLI、Qwen Code、Grok Build、WorkBuddy：通过各自的本地 Hook / 插件协议接入；其中部分仍属于实验性适配，真实客户端版本和模式需要单独验证。

这里只监听 coding/work agent 的任务，不把普通网站聊天或纯聊天模型本身当作任务来源。模型和 effort 是任务属性，额度监控不在当前范围内。

## 构建和运行

要求：macOS 26、Swift 6.2 或更新版本。

```bash
git clone https://github.com/qyuja/Kestra.git
cd Kestra

swift test
./script/build_and_run.sh
```

构建并做进程检查：

```bash
./script/build_and_run.sh --verify
```

协议适配器的隔离测试：

```bash
node script/test_pi.mjs
node script/test_opencode.mjs
```

发布 DMG：

```bash
git tag v0.1.1
git push origin v0.1.1
```

推送 `v*` tag 会触发 GitHub Actions，在 macOS 26 runner 上测试、构建并把 `Kestra-v*.dmg` 上传到对应 Release；也可以在 Actions 页面手动运行并填写 tag。

Actions 默认使用 ad-hoc 签名，适合本机验证但不会通过 Gatekeeper。要让其他 Mac 直接双击打开，需要在仓库 Secrets 配置 `MACOS_CERTIFICATE_P12_BASE64`、`MACOS_CERTIFICATE_PASSWORD`、`MACOS_KEYCHAIN_PASSWORD`，以及 notarization 所需的 `APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_PASSWORD`。

应用是状态栏应用，不创建常规控制窗口。运行脚本会在 `dist/Kestra.app` 生成经过完整 bundle 校验的本地调试包；没有 Developer ID 时，首次打开下载包请在 Finder 中右键选择“打开”。

如果下载后 macOS 提示无法验证开发者或应用不安全，请先确认 DMG 来源可信，将 `Kestra.app` 拖入“应用程序”，再执行（命令是 `xattr`，不是 `xttr`）：

```bash
xattr -dr com.apple.quarantine /Applications/Kestra.app
open /Applications/Kestra.app
```

## 图标插件

插件目录为：

```text
~/Library/Application Support/com.kiannest.kestra/icon-plugins
```

每个子目录包含一个 `manifest.json`，资源插件支持：

```json
{
  "schemaVersion": 1,
  "id": "circle-example",
  "name": "Circle Example",
  "systemSymbol": "circle"
}
```

也可以把 `frames` 设置为包内相对 PNG 路径数组。`frames` 与 `systemSymbol` 二选一。设置页提供打开目录和重新加载入口。完整字段、大小限制和安全规则见[图标插件说明](icon-plugins/README.md)。

## 本地数据和隐私边界

- Kestra 的任务监听在本机完成，不上传任务标题、对话摘要或 Hook 事件到 Kestra 服务。
- Codex、Claude Code 和其他客户端仍按它们自己的协议访问各自服务；Kestra 不替换模型请求。
- 账号切换只保存必要的本地账号元数据；凭据保存在客户端文件或 macOS 钥匙串中，不写入任务列表、README、日志或 Git 仓库。
- 应用数据默认位于 `~/Library/Application Support/com.kiannest.kestra/`；Codex 的 session 和设置继续使用用户现有的 `~/.codex`，不会复制到仓库。
- 应用不会扫描或上传完整历史；任务预览只读取界面需要的截断内容。

## 当前限制

- 这是 macOS 26 的本地开发包，尚未提供签名、notarization、安装器或自动更新。
- 各客户端 Hook / 插件协议会随客户端版本变化；协议单元测试不等于真实客户端端到端验证。
- 客户端被强制结束且没有产生结束事件时，Kestra 无法凭本地协议准确推断任务已结束。
- Claude Code 的真实账号切换尚未完成双账号端到端验收；不应把隔离测试当成真实登录验证。
- `ProviderLogos` 中的图标来自第三方资源。它们不属于本项目 MIT 许可证覆盖范围，重新分发前请核对 Icons8 的授权和 attribution 要求，或替换为自有资源。

更多设计和架构背景见：

- [账号与任务交接](docs/account-task-bridge.md)
- [Claude Code 账号](docs/claude-code-accounts.md)
- [图标插件](icon-plugins/README.md)
- [开源准备检查](docs/open-source-readiness.md)

## 许可证

Kestra 源码采用 [MIT License](LICENSE)。第三方资源、客户端 SDK、商标和服务仍受各自的许可证或使用条款约束。

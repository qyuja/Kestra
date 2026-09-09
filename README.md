# Kestra

原项目名 IslandBarDemo / AI Task Radar。当前保留原构建名称、bundle ID 和本地数据目录，避免影响已有账号与设置。

状态栏图标插件：[资源包格式与安装](icon-plugins/README.md)。
公开发布前检查：[开源准备清单](docs/open-source-readiness.md)。

一个面向 macOS 26 的原生 SwiftUI/AppKit 状态栏应用：把已选 AI 客户端的运行中任务数放进状态栏；所有查看、筛选和设置都在 bar icon 的 popover 中完成。当运行中的任务结束时，完成卡片会以 Animate.css 风格淡入、淡出，并可点击打开对应任务。

设置页设计探索稿：[Codex Task Radar — Settings Exploration](https://www.figma.com/design/nE2ee3bAFtHe0kRU9O2bXf)

多 Codex 账号和任务交接方案：[Account Task Bridge](docs/account-task-bridge.md)

Claude Code 账号切换：[范围、使用和安全限制](docs/claude-code-accounts.md)。首版适配 2.1.234，切换前需退出所有 Claude Code 进程，之后在原项目使用 `claude --resume` 恢复会话；不包含 Claude Desktop。

## 运行

```bash
cd IslandBarDemo
./script/build_and_run.sh
```

也可以运行 `./script/build_and_run.sh --verify` 做构建和进程检查。

## 交互

- 状态栏默认使用 qyuja 贡献的 [Barbell Squat runner](https://github.com/runcat-dev/RunnerGallery/pull/55)（原始 37×36、8 帧，资源未修改；附 RunnerGallery Apache-2.0 许可）。无运行任务时扛杠站立，有任务时深蹲；已选客户端并行任务越多越快，一轮从 1.2 秒逐渐加快，最快 0.36 秒。
- 每个完整动画周期累计一次，中途停止不计；休眠期间不补计。任务页底部及状态栏提示显示累计次数，使用本地 UserDefaults 持久化。这是动画次数，不是完成任务数或真人运动记录。

- 状态栏只显示所选图标；客户端运行数量保留在提示和任务列表中。
- 鼠标移入或点击状态栏 item，打开任务 popover；右上角齿轮进入设置，任务页可以切换已选客户端 tab。
- 任务页按客户端展示正在运行的任务和最近任务，每行包含 thread name 与最新对话摘要，文本会截断。
- Claude tab 旁提供 Claude Desktop 打开按钮；未安装 Claude Desktop 时按钮置灰，不影响 Claude Code 监听和账号切换。
- 设置页可以选择要显示的客户端，并配置完成提醒的显示位置、Animate.css 淡入/淡出方向、速度和停留时长。
- 设置页顶部固定、内容滚动；直接点击屏幕示意图的边、角或中心选择提醒位置，高亮和圆点同步更新，无二级分段控件。
- In 与 Out 独立保存：In 支持无方向淡入和位置允许的方向；Out 支持独立方向淡出、缩小消失、粉末消散。粉末效果将卡片分成约 3 点大小的 3567 个颗粒，共用截图，随机漂移、旋转、缩小并淡出。统一通过播放按钮预览完整流程。
- 动画选项使用 Top / Bottom 方向命名；淡出的悬停菜单用于选择方向，选项经过时高亮但不播放。菜单选中关闭后保持设置页打开，鼠标重新进入并离开设置页后恢复自动关闭。
- Codex 任务结束后，完成提醒会按所选 `fadeInX / fadeOutX` 方向进入和离开；点击会打开 `codex://threads/<thread-id>`。
- 任务来源按客户端区分：Codex、Claude Code、OpenCode、Gemini CLI、Qwen Code、Grok Build、WorkBuddy。模型是任务属性，不做额度监控。运行任务左上角使用绿色实心 10pt circle.fill，持续 breathe.pulse.wholeSymbol 呼吸动画，2 倍速。打开任务面板时主动刷新数据。
- 任务右侧运行时每秒更新本轮执行时长（m:ss / h:mm:ss），结束后显示距结束的 xx ago。Codex 使用生命周期事件时间；Hook 客户端使用本地接收时间，工具和模型更新不会重置计时。

## Claude Code

Gemini CLI、Qwen Code 同样提供任务页连接按钮，分别合并 `~/.gemini/settings.json`、`~/.qwen/settings.json` 的官方 command hooks。Gemini 的 BeforeAgent/BeforeTool/AfterAgent 映射为开始/活动/完成；Qwen 使用 UserPromptSubmit/PreToolUse/Stop，并仅用 submitted_prompt 作为原始用户预览。接入范围为 CLI 会话，不包含各自网站聊天；自定义配置路径、全局禁用 Hook 及真实 CLI 端到端运行尚需进一步验证。

参考：[Gemini Hooks](https://geminicli.com/docs/hooks/reference/)、[Qwen Hooks](https://qwenlm.github.io/qwen-code-docs/en/users/features/hooks/)。GLM、DeepSeek 等模型不再作为任务来源。Grok Build 合并 `~/.grok/hooks/islandbar.json`，处理其 camelCase sessionId、取消事件和真正 end_turn 的 Stop。

在任务页选择 Claude，然后点击「连接 Claude Code」。应用会备份 `.claude/settings.json` 并合并自己的 Hook，保留其他配置。若使用 `CLAUDE_CONFIG_DIR`，请在启动本应用时提供同一环境变量。连接后重新打开 Claude Code 会话；配置绑定当前应用路径，移动应用后需重新连接。

- 未检测到 CLI：显示「本机尚未安装 Claude Code，或未找到 claude 可执行文件」。
- 已安装但未配置：显示「未找到 Claude Code 监听配置」，提供连接按钮。
- 已连接且无记录：显示「当前没任务」。
- `UserPromptSubmit` / `PreToolUse` 更新运行状态；`Stop` 完成提醒；`StopFailure` / `SessionEnd` 清除运行状态但不冒充成功完成。每 0.5 秒读取新事件。
- 只监听接入之后的用户消息；应用启动时读取已记录摘要但不回放历史提醒，已有会话需产生新的开始或工具事件才能恢复运行状态。进程被强制杀死且未发出 Hook 时，无法从协议确认终止。
- Hook 只将必要的生命周期、用户消息和工作目录写入本机应用数据目录，不保存工具参数或上传内容。事件文件目前保留在 `~/Library/Application Support/com.kiannest.islandbar/claude-events`。
- 点击 Claude 任务目前打开其工作目录，不会误打开 Codex；尚未实现终端会话恢复。

协议参考：[Claude Code Hooks](https://code.claude.com/docs/en/hooks)。本机无真实会话时使用隔离测试目录验证协议事件，不向产品任务列表注入测试数据。

## Provider logo 资源

客户端 logo 使用 Icons8 页面中的 `iOS 27 Outlined` PNG 资源并随应用打包：Codex 与 ChatGPT 共用 OpenAI/ChatGPT knot logo；MiniMax 当前使用同页面风格的通用 AI logo，后续拿到 MiniMax 专属资源时只需替换同名 PNG。若用于公开发布，请按 Icons8 的授权和 attribution 要求处理。

## 完成动画插件

完成提醒通过 `CompletionAnimationPlugin` 注入，支持无方向淡入淡出与八个方向。进入和退出均经过所选边或角。内部保留旧预设标识以兼容已保存设置，界面统一用 Top / Bottom 表达方向。

动画参数集中在 `CompletionAnimationConfiguration`，例如可以通过下面的命令调整动画速度：

```bash
defaults write com.kiannest.islandbar completionAnimation.speed -float 1.25
```

停留时长也可以通过偏好设置调整，单位为秒，范围是 1 到 30 秒：

```bash
defaults write com.kiannest.islandbar completionAnimation.dwellDuration -float 8
```

显示位置保存为 `completionAnimation.displayPosition`；所选 `fadeInX / fadeOutX` 预设同时决定淡入和淡出方向，不再提供容易混淆的手动进入方式覆盖。旧版本的 `completionAnimation.entryMode` 会被自动归一为 `automatic`。

新增动画时，实现协议并注册到 `CompletionAnimationRegistry` 即可。当前是编译期 Swift 插件式架构；如果以后需要第三方独立 `.bundle` 动态加载，再把注册表替换为 Bundle/模块发现即可，任务监控和浮窗控制器无需改动。

## 本地数据边界

- 任务列表通过随 Codex 安装提供的 `codex app-server` 读取，只请求非归档线程的元数据。
- 任务卡的对话预览可配置为 session JSONL 中第一条或最后一条 user 消息，不显示 assistant 返回内容；文件不可读时回退到线程元数据中的 preview。
- 运行中数量通过定时增量读取 app-server 返回的非归档线程对应的 session JSONL，使用 `task_started`、`task_complete` 和中止事件判断状态；状态扫描每 0.5 秒执行一次，Codex app-server 通知会触发额外的即时刷新，不依赖 Accessibility 读取 Codex 界面，也不会启动时扫描整个历史目录。
- 任务数据来自真实的 Codex 本地状态，不再生成或注入模拟任务；当检测到任务开始或结束时，状态栏会立即按运行中客户端和数量刷新。
- 应用启动时只建立当前任务文件的状态基线，不回放启动前已经完成的历史任务；应用运行期间新观察到的完成事件才会进入提醒队列。
- 开启“前台应用时跳过提醒”后，如果对应客户端的桌面应用位于前台（当前 Codex/ChatGPT 的 bundle id 为 `com.openai.codex`），完成任务只更新任务列表，不弹出完成卡片。
- 标题和最新对话只在界面中显示截断后的内容；应用不修改 Codex 会话、数据库或 JSONL 文件。
- 如果将来做成沙盒签名应用，需要把 Codex 数据目录改为用户授权的安全书签，或改用公开的 Codex 集成接口。

系统状态栏 item 的位置仍由 macOS 决定，因此它不会遮挡其他状态栏图标；完成卡片是独立的非激活浮动面板，会按设置定位到当前屏幕的九宫格位置，并使用对应的 Animate.css 风格位移和淡入/淡出。应用本身不再创建常规控制窗口。

## 新增客户端与验证边界（2026-09-05）

### 2026-09-07 客户端目录与 Pi / Cursor

- 主列表：Codex、Claude Code、Cursor、Pi、OpenCode、Gemini CLI。更多客户端：Qwen Code、Grok Build、WorkBuddy、DeepSeek Harness、Cline、GitHub Copilot、Windsurf、Kiro、Claude Cowork。保留既有选择；后六项尚未完成适配，设置标记“未接入”，不虚报连接成功。新增品牌 logo 暂用系统符号，尚未补齐资源。
- Pi：任务页“连接 Pi”安装 `~/.pi/agent/extensions/islandbar.js`，支持 `PI_CODING_AGENT_DIR`。已有同名文件先备份，之后需 `/reload` 或重启 Pi。扩展不修改提示、工具或权限；读取模型/thinkingLevel、用户 prompt 和 session ID。仅在 `agent_settled` 且 idle 后报告完成，不把 `agent_end` 的自动重试间隙算完成；错误、取消、关闭单独清状态。无工具的纯聊天不记录。要求运行版本支持 `agent_settled`；其他加载该扩展的 Pi 宿主需实测，未加载扩展的宿主不覆盖。协议：[Pi Extensions](https://pi.dev/docs/latest/extensions)。
- Cursor：任务页“连接 Cursor”备份并合并 `~/.cursor/hooks.json` 的官方扁平 Hook 格式；beforeSubmitPrompt / preToolUse / stop / sessionEnd 映射任务状态。只按 conversation_id 聚合，不把 generation 或 subagent 额外算一张任务卡，不订阅 Tab 补全 Hook。失败、取消不弹成功提醒。保留用户现有 Hook，不输出权限决定或修改请求。记录选中模型和明确 effort，不保存邮箱、工具参数、assistant 内容。协议：[Cursor Hooks](https://prod.cursor.com/docs/hooks)。
- 覆盖边界：当前 Cursor 接的是在本机触发上述 Agent Hooks 的入口；桌面/CLI 各版本、Ask 模式是否触发同名 Hook、其他 stop Hook 自动续跑的组合行为需实测，不能保证所有版本都已排除普通聊天。远端云 Agent 不会自动把事件传回本机。Claude Cowork 不因为已接 Claude Code 就视为支持。
- 本轮不自动安装 Pi CLI，不自动修改用户客户端配置；用户在任务页点击连接才写入扩展或 Hook。未安装时显示未找到客户端，已配置且暂无事件显示当前没任务。进程强杀无结束事件的恢复仍未实现。
- 验证：`swift test`、`node script/test_pi.mjs`、`node script/test_opencode.mjs`。测试用临时目录/内存事件，不写入用户真实任务列表。Pi/Cursor 真实任务端到端尚需启动客户端后验证。

- OpenCode：点击连接安装随应用打包的 `plugins/islandbar.js`，默认位于 `~/.config/opencode`，支持 OPENCODE_CONFIG_DIR / XDG_CONFIG_HOME。通过 chat.message、chat.params、session.status / idle / error 记录用户预览、模型和生命周期，不修改模型请求。需重新启动 OpenCode 加载插件。参考：[官方插件接口](https://opencode.ai/docs/plugins/)。
- WorkBuddy：实验性兼容 Hook，探测 WorkBuddy.app；优先使用已有 `~/.workbuddy-ai`，否则使用 `~/.workbuddy/settings.json`。只接入状态事件，不接管审批。配置有备份，连接后重启客户端。依据是[开源兼容实现](https://github.com/FlashFamily/workbuddy-buddy/blob/main/hooks/install.py)，不是桌面版官方稳定协议承诺，尚未实机验证。
- 模型：Codex 从 session 的 turn_context.model 读取；OpenCode 从插件模型参数读取；Gemini 使用 BeforeModel.llm_request.model；其他 Hook 从明确的 model 字段或 transcript 的模型元数据提取。不会用客户端名称或默认配置推测模型；未提供时显示“模型未知”。transcript 只扫描最多 1 MiB 尾部，过早的模型记录可能无法找到。
- 旧设置中的 Codex / Claude 等客户端选择保留，GLM / DeepSeek 等模型选择忽略；若无剩余选择则回到 Codex。
- 验证：`swift test`；`node script/test_opencode.mjs`（内存事件，不写入真实任务列表）；`./script/build_and_run.sh --verify`。协议测试不等同于各客户端真实会话端到端验证。

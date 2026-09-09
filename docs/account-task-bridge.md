# 多 Codex 账号任务桥接方案

状态：已实现“空闲检查 → 正常退出 Codex → 备份/切换文件登录缓存 → 原目录重启 → 核验身份”的切换代码。仅完成临时目录自动测试，未在运行中的本任务上执行真实账号重启；跨账号续接对话仍需实机验证。交接 UI 和 MCP 尚未接入。

### 2026-09-07 登录和切换实现

#### 切换耗时日志

使用 macOS 统一日志，subsystem 为 `com.kiannest.islandbar`，category 为 `AccountSwitchTiming`，级别 notice。每次允许开始的切换生成随机 attempt ID，各阶段结束记录 elapsed_ms 和自本次点击起累计的 total_ms，最后 stage=total 汇总。记录失败阶段、超时和退出取消；恢复启动成功时总结果仍是 failed。不会记录邮箱、账号 ID、文件内容、路径、凭据或原始错误。

阶段包含首次任务列表/扫描、文件预检、原目录确认、目标/当前身份查询、退出前任务列表/扫描、正常退出、停止监听、凭据备份、账号映射保存、凭据安装、启动、目录/身份验证和状态发布。切换身份查询现在只请求 account/read，不再等待额度；工作区核对使用同目录文件型登录缓存的 tokens.account_id，缺失时不会放宽已有工作区匹配。launchApplication 包含现有 750ms 等待，不代表界面完全就绪。此前日志中的身份阶段曾包含额度读取，比较前后耗时时应注意此变化。

```sh
/usr/bin/log show --last 30m --style compact --predicate 'subsystem == "com.kiannest.islandbar" AND category == "AccountSwitchTiming"'
```

实时观察可把 `show --last 30m` 改为 `stream`。日志由 macOS 管理保存和清理，不另建应用日志文件。此轮使用注入时钟的测试验证阶段计时、总计、恢复结果和取消；真实切换耗时需要一次用户主动切换后采集。

#### 本机设置与自定义指令共用

- 账号目录只用于保存登录凭据和后台身份/额度查询，不是桌面运行配置。切换时不把其中的 config.toml 或旧桌面偏好复制到当前实例。
- 切换前从当前进程打开的文件确认 CODEX_HOME 和桌面 userData 两个目录；重启和失败恢复均显式指定相同的 CODEX_HOME、CODEX_ELECTRON_USER_DATA_PATH。启动后两者必须匹配才确认成功。桌面目录探测依赖当前安装版本的 Default/Local Storage/leveldb/LOCK 布局，不是公开稳定 API；布局未知或存在多个候选时中止，不猜目录。
- 共用同一个 CODEX_HOME 下的 config.toml、全局 AGENTS.md / AGENTS.override.md、自定义指令文件、skills、rules、hooks、automations、插件本地配置、项目记录与本地会话。原桌面目录中的本地偏好继续原地使用。项目级 AGENTS.md 和 .codex/config.toml 仍从原项目目录加载。
- 这里的 System prompt 指用户可编辑的自定义指令，不是模型内置系统提示词。Codex 的加载优先级和项目可信任要求保持原样；不改写已有指令，也不保证恢复中的旧任务会重新加载新指令。
- 不实现 ChatGPT 网站自定义指令、云端记忆或云端对话的跨账号同步；不合并套餐、额度、组织策略或第三方 OAuth 授权。本地插件/MCP 配置相同不代表新账号自动获得其服务权限。不得把组织专有内容带入无授权的账号。
- 新增临时目录测试覆盖 A→B→A 后设置和指令保留最新编辑、恢复凭据不回滚配置、旧账号配置不覆盖共享配置、两类目录识别和异常拒绝。真实桌面重启、跨账号继续旧任务和偏好显示仍需用户空闲时实测。

依据：[配置加载规则](https://learn.chatgpt.com/docs/config-file/config-basic)、[自定义指令加载规则](https://learn.chatgpt.com/docs/agent-configuration/agents-md)。

- 额度现在由 `CodexAccountUsageMonitor` 在后台每 30 秒刷新全部已启用账号，启动登记完成及添加账号后立即刷新。切换期间暂停，切换结束恢复 30 秒定时器，不额外立即读取，保留已缓存额度，未知仍显示未知。按账号顺序查询，每次最多一个临时 app-server，完成即关闭；失败或身份不匹配只影响该行。额度只缓存在内存，SwiftUI 订阅更新，打开账号菜单和设置展开不再请求接口。退出时取消定时器和未完成查询。

- 启动时默认读取当前 CODEX_HOME 的真实账号。设置中的“添加账号”创建 `task-bridge/profiles/<uuid>/codex`，由官方 app-server 执行 `account/login/start` 浏览器流程，等待匹配 loginId 的完成通知，再读取身份和登记。支持取消、180 秒超时、浏览器打开失败和登录失败。新目录配置文件仅指定 file 凭据存储（0600），登录凭据由 Codex 自己写入该隔离目录。
- 运行中任务数大于零时，其他账号行置灰禁用；断连、查询失败、尚无快照或快照超过 5 秒也禁止切换。点击后重新获取任务列表并读取任务生命周期，再检查运行状态；超时、不可读都中止。
- 当前没有桌面登录控制 socket，改为用户点击触发正常退出后重启。只支持单个 Codex 实例、可确认的数据目录和文件型 auth；不强制退出。退出前再次读取全量任务列表，生命周期缺失、文件不可读或记录未写完整都中止。退出后才备份和替换 auth.json；项目目录、全局项目记录、数据库和会话文件不迁移、不复制。原实例不退出时绝不启动目标实例。
- 第一次切离原账号时，将其最新登录缓存保存到应用原数据根下 profiles/<uuid>/codex，并更新账号映射。当前活跃账号的额度查询使用实际运行目录，其他账号使用各自保存目录，避免两个副本同时刷新同一账号凭据。启动时按已验证身份匹配账号，不按当前目录重复登记。
- switches/<uuid>/previous-auth.json 是恢复备份，目录 0700、凭据文件 0600；accounts.json 始终只存元数据。若替换或启动失败且没有运行中的 Codex，恢复原缓存并尝试重新打开。新窗口已打开但核验失败时不再次强制关闭它，清除“使用中”标记并报告错误，备份仍保留。进程崩溃期间的备份可用于手动恢复，尚未实现自动崩溃恢复。
- 额度圆环只保留中心剩余百分比，短周期在前、周窗口在后，缺失窗口隐藏，未知额度保留单个 `—`。周期只在辅助功能和鼠标提示中说明。

协议依据：[官方 App Server 登录流程](https://learn.chatgpt.com/docs/app-server)、[凭据目录与存储](https://learn.chatgpt.com/docs/auth)。

账号入口位于任务 tab 的打开应用按钮左侧；菜单只显示账号列表与右上角添加按钮，添加按钮导航到设置账号区。各账号额度通过后台 `account/rateLimits/read` 读取，优先选 `rateLimitsByLimitId.codex`，圆环中心显示剩余百分比，不显示周期文字。打开面板只展示内存中的最新状态，未知或读取失败显示 `—`，错误保留在圆环提示中。其他已登记账号不复用当前账号额度。接口没有工作区枚举能力，Team 对应的个人行只是“未连接”入口，不写入虚构 profile；个人身份实际登录后才登记。以接口提供的 accountId 区分同邮箱工作区，并兼容已有无 workspaceID 记录。

应用启动时通过现有 Codex app-server 的 `account/read`（`refreshToken: false`）登记当前 ChatGPT 账号。仅保存邮箱、套餐、本地目录、workspaceID 和时间，按身份与规范化目录去重。未登录、非 ChatGPT 登录、缺失邮箱、超时和保存失败会显示错误。账号列表是登记记录，不表示各账号登录缓存仍然可用；同一目录更换登录后，旧记录不能用于恢复旧登录。当前读取的是监听进程使用的 CODEX_HOME，默认 ~/.codex。

## 1. 背景与目标

Codex 账号 A 和账号 B 可以访问同一个本地项目目录，但它们的登录态、对话历史和 Codex thread 不保证互通。

本方案解决以下问题：

- 多个 Plus 账号分别登录、分别消耗额度。
- 账号 A 的任务因额度不足暂停后，用户可以手动切换到账号 B。
- 账号 B 在同一个项目目录中继续原任务。
- IslandBar 将多个账号下的会话聚合为一张任务卡。
- 保留任务从账号 A 到账号 B 的完整交接链路。

本方案不承诺跨账号恢复同一个 Codex 对话 thread。实际实现是“同一个本地任务，多个账号会话接力”。

当前代码骨架位于 `Sources/IslandBarDemo/TaskBridge`，运行后会创建：

```text
~/Library/Application Support/com.kiannest.islandbar/task-bridge/
├── accounts.json
├── tasks/
├── messages/
└── leases/
```

交接 Markdown 同时写入项目目录，供 Codex 桌面端的 Local 环境读取：

```text
<project>/.codex/task-bridge/<taskId>/<handoffId>.md
```

该目录默认加入项目 `.gitignore`，交接内容只留在本机，不随代码提交。

## 2. 核心原则

### 2.1 任务和会话分离

`taskId` 是 IslandBar 自己维护的稳定任务标识，不等于 Codex 的 `threadId`。

```text
taskId:      islandbar-task-001       // 跨账号保持不变
sessionId A: codex-thread-a           // 账号 A 的会话
sessionId B: codex-thread-b           // 账号 B 的会话
```

账号切换只会创建新的 Codex session，不会改变 `taskId`。

### 2.2 项目目录可以共用，对话上下文需要显式交接

- 顺序执行时，账号 A 和 B 可以使用同一个项目目录。
- 并行执行时，不允许两个账号直接同时修改同一工作树。
- 需要并行时，为每个会话创建 Git worktree，完成后再合并。
- 账号 B 通过结构化交接上下文了解账号 A 的工作，而不是依赖账号 A 的服务端对话历史。

### 2.3 凭据只在本机切换

每个账号保留独立登录缓存。按最新重启切换方案，应用会在用户点击后本地备份并替换文件型 auth.json，凭据不进入任务上下文、日志或网络消息。此处替代最初“不读取或复制登录缓存”的设计。Keychain/auto 存储及 API key 登录不纳入本轮切换。

Codex 官方文档说明登录缓存位于 `auth.json` 或系统凭据存储中，文件型凭据位于 `CODEX_HOME` 下；因此账号配置必须隔离保存。[Codex Authentication](https://learn.chatgpt.com/docs/auth)

## 3. 系统结构

```text
┌─────────────────────────────┐
│ Codex session A              │
│ account-a / CODEX_HOME-A    │
└──────────────┬──────────────┘
               │ MCP tools / events
               ▼
┌─────────────────────────────┐
│ Local Task Bridge            │
│                             │
│ task state                  │
│ handoff snapshots           │
│ account/session mapping     │
│ messages and leases         │
└──────────────┬──────────────┘
               │ MCP tools / events
               ▼
┌─────────────────────────────┐
│ Codex session B              │
│ account-b / CODEX_HOME-B    │
└─────────────────────────────┘

┌─────────────────────────────┐
│ IslandBar                    │
│ status item + task popover   │
└──────────────┬──────────────┘
               │ local IPC / bridge API
               ▼
        Local Task Bridge
```

MCP 负责让 Codex 会话读写任务上下文；IslandBar 负责展示状态、创建交接和触发下一账号会话。Codex 官方支持通过 MCP 连接外部工具，桌面版、CLI 和 IDE 扩展也支持 MCP 配置。[MCP](https://learn.chatgpt.com/docs/extend/mcp)

如果未来需要从应用侧深度控制会话、订阅 agent 事件或主动发送新一轮消息，再接入 Codex App Server。App Server 是 Codex 用于嵌入产品的双向 JSON-RPC 接口。[Codex App Server](https://learn.chatgpt.com/docs/app-server)

## 4. Task Bridge 数据模型

桥接层保存任务状态，不保存账号凭据。

```json
{
  "taskId": "islandbar-task-001",
  "projectPath": "/Projects/IslandBarDemo",
  "branch": "main",
  "worktreePath": "/Projects/IslandBarDemo",
  "status": "paused_quota",
  "activeAccountId": "account-a",
  "activeSessionId": "codex-thread-a",
  "goal": "完成 Codex 任务监听",
  "completed": [
    "任务结束后能更新任务卡状态"
  ],
  "inProgress": [
    "实现账号切换后的任务续接"
  ],
  "decisions": [
    "使用本地 Task Bridge，不共享账号凭据"
  ],
  "filesChanged": [
    "Sources/IslandBarDemo/Models/CodexTaskStore.swift"
  ],
  "tests": [
    "swift test"
  ],
  "lastUserRequest": "账号 A 额度用完后，手动切换账号 B 继续",
  "nextStep": "检查任务状态并继续实现账号 B 的会话",
  "updatedAt": "2026-09-07T00:00:00Z"
}
```

### 4.1 重要实体

| 实体 | 作用 |
| --- | --- |
| `Task` | 跨账号持续存在的逻辑任务 |
| `AccountProfile` | 本机账号别名、Codex 配置目录和显示信息，不含凭据 |
| `TaskSession` | 某个账号实际运行过的 Codex session |
| `HandoffSnapshot` | 某一时刻可供下一个账号继续的上下文快照 |
| `TaskMessage` | 账号会话之间的补充消息 |
| `TaskLease` | 防止多个会话同时修改同一工作树 |

## 5. 交接流程

### 5.1 账号 A 额度耗尽

1. Codex 任务进入暂停、失败或等待用户处理状态。
2. IslandBar 任务卡显示：

   ```text
   已暂停 · 额度不足 · 账号 A
   ```

3. 用户点击「生成交接」。
4. Bridge 写入一个不可变的 `HandoffSnapshot`。
5. IslandBar 保留账号 A 的 session 记录，不删除原任务。

如果账号 A 仍能响应，可以请求它生成更完整的摘要；如果已经无法继续，则使用已有事件、用户消息、Git diff、测试记录和项目文件生成最低限度的交接信息。

### 5.2 手动切换账号 B

1. 用户在 IslandBar 账号选择器中选择账号 B。
2. 用户点击「从交接继续」。
3. IslandBar 在同一个 `projectPath` 启动账号 B 的 Codex session。
4. 将 `HandoffSnapshot` 转换成可编辑的 continuation prompt。
5. 账号 B 先读取项目状态和交接信息，再继续执行。
6. Bridge 将 `activeSessionId` 切换到账号 B，并记录 `A → B` 的会话关系。

推荐注入给账号 B 的提示结构：

```text
你正在继续一个已有任务。

任务 ID：<taskId>
项目目录：<projectPath>

目标：
<goal>

已经完成：
<completed>

当前进行中：
<inProgress>

重要决策：
<decisions>

最近修改：
<filesChanged>

测试结果：
<tests>

请先检查当前工作树和实际文件状态，再从下一步开始继续。
不要重复已经完成的工作。
```

## 6. Bridge 接口

桌面端优先采用项目文件交接。IslandBar 生成 Markdown 后，账号 B 在同一个项目的 Local 环境中读取：

```text
请先读取 .codex/task-bridge/<taskId>/<handoffId>.md，
检查当前工作树和实际文件状态，然后从 Next step 继续。
```

第一阶段的 MCP 接口预留为：

```text
task_get_context(taskId)
task_update_state(taskId, patch)
task_create_handoff(taskId)
task_list_messages(taskId)
task_append_message(taskId, message)
task_acquire_lease(taskId, sessionId)
task_release_lease(taskId, sessionId)
```

约束：

- `taskId` 必须由 IslandBar 创建或显式绑定。
- 账号会话不能修改其他任务。
- `task_create_handoff` 生成不可变快照，不覆盖历史交接。
- `task_update_state` 只允许更新任务状态和工作摘要。
- 工具参数、完整 assistant 输出和凭据默认不进入 Bridge。
- 任务消息需要限制长度，避免上下文无限膨胀。

### 6.1 主动通信的边界

MCP 工具是按需调用的。账号 B 不会因为 Bridge 中出现新消息就自动收到一条模型上下文消息；它需要在下一轮中调用 `task_get_context` 或 `task_list_messages`。

如果未来要求两个会话实时互相发消息，需要由 IslandBar 或 App Server 作为编排器，将消息转换成目标会话的新一轮输入。这个能力属于第二阶段，不作为手动账号切换的前置条件。

## 7. 账号 Profile

IslandBar 只管理账号的本地显示信息和配置目录映射：

```text
account-a
  displayName: 个人 Plus
  codexHome: <local codex home A>

account-b
  displayName: 工作 Plus
  codexHome: <local codex home B>
```

首次添加账号时，用户在对应的 Codex 配置目录中完成官方登录。IslandBar 不采集密码；重启切换时仅在本机操作文件型登录缓存，按 2.3 的备份和权限规则执行。

账号切换只影响新启动的 Codex session。已经运行的 session 继续归属于原账号，不能在运行中强行替换身份。

## 8. 并发与项目安全

### 顺序交接

适用于当前目标：

```text
账号 A 暂停
    ↓
生成交接
    ↓
账号 B 使用同一项目目录
    ↓
继续任务
```

### 并行任务

如果账号 A 尚未结束，账号 B 也要工作：

- 为 B 创建独立 worktree。
- Bridge 记录每个 session 的 worktree。
- 禁止两个 session 获得同一个 worktree 的写入 lease。
- 合并前运行测试和冲突检查。

项目目录共用不等于文件写入可以并发。

## 9. IslandBar UI 规划

### 账号管理

- 账号列表：显示别名、当前状态、最近使用时间。
- 添加账号：创建 profile 并引导用户完成官方登录。
- 当前账号：只影响新任务或「从交接继续」。

### 任务卡

- 显示逻辑任务名，而不是只显示当前 Codex thread 名。
- 显示当前账号，例如「账号 A」。
- 显示状态：运行中、已暂停、额度不足、等待交接、已完成。
- 显示会话链路，例如 `A → B`。
- 显示「生成交接」和「从交接继续」。
- 展开后查看最近交接摘要和下一步。

### 交接编辑

交接内容在发送给账号 B 前允许用户编辑，避免自动摘要中的错误决定影响后续任务。

## 10. 分阶段实现

### Phase 1：文件交接和数据结构

- 增加 `taskId`、`accountId`、`sessionId` 和会话链路模型。
- 增加 `HandoffSnapshot` 持久化，同时生成项目内可读的 `handoff.md`。
- 任务卡显示账号和暂停状态。
- 不修改现有 Codex 登录逻辑。

### Phase 2：桌面端手动交接

- 增加「生成交接」。
- 从 Codex 本地事件、用户消息、Git diff 和测试结果构建快照。
- 增加账号 profile 列表。
- 使用指定账号和项目目录启动新的 Codex session。
- 注入 continuation prompt。

### Phase 3：MCP Bridge

- 实现本地 MCP server。
- 为每个 Codex profile 注册相同的 Bridge。
- 支持任务上下文读取、状态更新和消息追加。
- 增加 task lease，避免并发写入同一工作树。

### Phase 4：App Server 编排

- 接入各账号的 Codex App Server。
- 监听 session、turn、额度错误和完成事件。
- 支持从 IslandBar 发起新的 continuation turn。
- 仅在确认稳定后考虑实时双向消息。

## 11. 暂不实现

### 2026-09-07 账号管理状态

- 设置中账号行的菜单支持修改备注、移除登记和浏览器重新登录；重新登录校验邮箱及已知工作区，保留账号 ID、备注和创建时间。
- 移除登记不清除登录缓存、项目或历史；当前账号不能移除，需先切换。当前账号的重新登录仍需在 Codex 内执行，菜单只支持更新非当前账号的独立缓存。
- 移除未登录的个人工作区占位项，工作区由用户手动登录登记。
- **关闭前对话自动恢复尚未实现**：当前读取的共享状态没有可靠的前台任务标识；不使用最近更新时间推测。已有共享目录复用不等于恢复当前打开的对话。
- 单元测试覆盖备注持久化、空备注拒绝、重登工作区校验和稳定 ID；浏览器真实登录与重启恢复未作端到端验证。

- 自动轮换账号或自动合并额度。
- 向其他主机转发、上传或代理 OAuth token。
- 修改 Codex 官方服务端对话历史。
- 保证跨账号恢复同一个 thread。
- 两个账号同时写入同一个工作树。
- 读取或上传完整私人对话作为默认行为。

## 12. 验收标准

- 账号 A 和账号 B 可以分别登录并保持独立缓存。
- 两个账号可以指向同一个项目目录。
- A 的任务暂停后，可以生成交接快照。
- B 可以在同一项目目录创建新会话并继续。
- IslandBar 能将 A、B 的 session 显示为同一个逻辑任务。
- 原任务的文件修改、测试结果和下一步不会因账号切换丢失。
- Bridge 不包含任何 token、密码或 API key。
- 在并行场景下，同一 worktree 不会被两个会话同时获得写入 lease。

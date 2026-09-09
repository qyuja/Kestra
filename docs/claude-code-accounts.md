# Claude Code 账号切换

## 范围与使用

- 仅支持 Claude Code 的 Claude.ai 订阅账号，不包含 Claude Desktop、Cowork、API Key 或云厂商认证。
- 设置 → Claude → 账号：首次展开读取当前身份；支持添加账号、修改备注、移除登记、重新登录。
- 任务页 Claude tab 旁有快捷切换入口。
- 浏览器登录使用官方 `claude auth login --claudeai`。首次无钥匙串登录时使用默认目录；已有登录时在独立临时配置目录登记，避免覆盖当前登录。
- 登录最长等待 180 秒，支持取消；需要手动粘贴授权码的环境暂不支持应用内交互，应在终端完成登录再刷新。
- 首版只适配本机 Claude Code **2.1.234** 的私有存储格式。未知版本、自定义认证环境、非默认配置目录、文件型凭据或链接配置会拒绝切换。

## 会话保护

- 运行中任务时 UI 禁用切换。实际切换前还检查系统进程；任何 Claude Code 进程（包括空闲交互、后台监督进程）存在就拒绝，不强制结束它。
- 用户先正常退出已有 Claude Code，在切换后回到原项目执行 `claude --resume` 选择原会话；不自动猜测最后打开的会话、不自动向终端输入命令。
- 会话、项目、记忆、settings、plugins 原地保留，不复制或删除；只替换钥匙串中的 `claudeAiOauth` 和 `~/.claude.json` 中的 `oauthAccount`。其他 JSON 字段保留。
- 进程检查不是系统级启动锁；用户应避免在切换期间自行启动另一 Claude 进程。

## 数据与失败恢复

- 账号元数据：应用 Task Bridge 根目录下 `claude/accounts.json`（0600）。
- 账号登录快照及恢复备份：macOS 钥匙串，service 为 `com.kiannest.islandbar.claude-accounts`；不把 OAuth token 写入日志或账号元数据。
- 写入前在钥匙串备份原登录，持久化 `claude/pending-switch.json`（仅恢复项 ID）；异常时尝试还原。进程被终止后再次启动，存在标记就禁止新切换并提供“恢复原账号”。
- 删除为“移除登记”：保留钥匙串缓存和历史。登录临时目录和恢复快照目前保留，尚未做自动清理。
- 使用 `auth status` 校验身份一致性；这是本地登录状态检查，不等价于向模型服务发请求验证 token 未被撤销。过期缓存会要求重新登录，不进行后台私有 OAuth 刷新。

## 验证

- 单元测试：订阅身份解析、不同组织拒绝、过期凭据拒绝、配置字段保留、进程匹配、辅助命令取消。
- 本机确认已安装 2.1.234 且当前未登录。尚未进行两个真实账号的浏览器登录、钥匙串授权、切换及会话恢复端到端验收。
- 官方依据：[认证](https://code.claude.com/docs/en/authentication)、[CLI 命令](https://code.claude.com/docs/en/cli-reference)。私有钥匙串命名及身份字段另经本机安装包核对。

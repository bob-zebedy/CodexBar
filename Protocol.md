# app-server 接口清单

Codex 版本：`0.162.0`

## 主动请求

| 接口 | 作用 |
| --- | --- |
| `initialize` | 初始化连接，获取服务端版本 |
| `account/read` | 读取账户信息；`refreshToken` 指定是否刷新认证 |
| `account/rateLimits/read` | 读取额度、余额和重置凭证 |
| `account/usage/read` | 读取账户用量汇总和每日 Token 用量 |
| `account/rateLimitResetCredit/consume` | 消费额度重置凭证；`creditId` 指定凭证，`idempotencyKey` 用于避免重复消费 |
| `config/read` | 读取 Codex TUI 通知配置 |
| `config/batchWrite` | 修改 Codex TUI 通知配置；`edits` 指定 `tui.notifications` 的值，`reloadUserConfig: true` 使配置生效 |
| `thread/loaded/list` | 获取已加载会话列表 |
| `thread/read` | 读取会话信息和状态；`threadId` 指定会话，`includeTurns: false` 不返回轮次内容 |
| `thread/resume` | 订阅已加载会话的消息；`threadId` 指定会话，`excludeTurns: true` 不返回轮次内容 |
| `thread/turns/list` | 分页读取会话的轮次信息；`threadId` 指定会话，`itemsView: "notLoaded"` 不加载执行项正文 |
| `thread/items/list` | 分页读取轮次的执行项；`threadId` 和 `turnId` 指定目标轮次 |

## 主动通知

| 接口 | 作用 |
| --- | --- |
| `initialized` | 告知服务端初始化已完成 |

## 接收通知

### 账户通知

| 接口 | 作用 |
| --- | --- |
| `account/updated` | 接收账户变化通知 |
| `account/rateLimits/updated` | 接收额度变化通知 |

### 会话、轮次和执行项

| 接口 | 作用 |
| --- | --- |
| `thread/started` | 接收会话启动通知 |
| `thread/status/changed` | 接收会话状态变化 |
| `thread/tokenUsage/updated` | 接收会话 Token 用量更新 |
| `turn/started` | 接收轮次开始通知 |
| `turn/completed` | 接收轮次结束通知 |
| `item/started` | 接收执行项开始通知，包括异步提问和用户回应 |
| `item/completed` | 接收执行项结束通知，包括异步提问和用户回应 |

### 进展通知

| 接口 | 作用 |
| --- | --- |
| `item/agentMessage/delta` | 感知回答输出进展 |
| `item/reasoning/textDelta` | 感知思考文本输出进展 |
| `item/reasoning/summaryTextDelta` | 感知思考摘要输出进展 |
| `item/commandExecution/outputDelta` | 感知命令输出进展 |

### 状态与展示通知

| 接口 | 作用 |
| --- | --- |
| `turn/plan/updated` | 接收计划进度更新 |
| `turn/diff/updated` | 感知代码差异更新 |
| `model/rerouted` | 接收模型切换信息 |
| `model/verification` | 感知模型验证需求 |
| `modelProvider/authRecoveryStarted` | 感知认证恢复开始 |
| `modelProvider/authRecoveryCompleted` | 感知认证恢复结束 |
| `model/safetyBuffering/updated` | 接收安全缓冲展示状态 |
| `hook/started` | 感知 hook 执行开始 |
| `hook/completed` | 接收 hook 执行结果 |
| `serverRequest/resolved` | 接收审批、提问等服务端请求的结束通知 |
| `error` | 接收错误通知 |
| `warning` | 记录服务端警告 |

## 服务端请求

| 接口 | 作用 |
| --- | --- |
| `item/commandExecution/requestApproval` | 观察命令执行审批请求 |
| `item/fileChange/requestApproval` | 观察文件修改审批请求 |
| `item/permissions/requestApproval` | 观察权限审批请求 |
| `item/tool/requestUserInput` | 观察运行期间的提问；`isBlocking` 表示是否阻塞执行 |
| `mcpServer/elicitation/request` | 观察 MCP 交互请求 |

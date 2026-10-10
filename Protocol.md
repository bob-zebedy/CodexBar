# app-server 接口清单

适用版本 Codex `0.162.0`

## 主动调用

### 请求

| 接口 | 作用 |
| --- | --- |
| `initialize` | 初始化连接，获取服务端版本 |
| `account/read` | 读取账户信息、刷新认证 |
| `account/rateLimits/read` | 读取额度、余额和重置凭证 |
| `account/usage/read` | 读取账户用量汇总和每日 Token 用量 |
| `account/rateLimitResetCredit/consume` | 消费额度重置凭证 |
| `config/read` | 读取 Codex TUI 通知配置 |
| `config/batchWrite` | 修改 Codex TUI 通知配置 |
| `thread/loaded/list` | 获取已加载线程列表 |
| `thread/read` | 读取线程信息和状态 |
| `thread/resume` | 订阅已加载线程的消息 |
| `thread/turns/list` | 获取线程的轮次列表、状态、根轮次标识和子 Agent 创建信息 |

### 通知

| 接口 | 作用 |
| --- | --- |
| `initialized` | 告知服务端初始化已完成 |

## 被动接收

### 账户通知

| 接口 | 作用 |
| --- | --- |
| `account/updated` | 接收账户变化通知 |
| `account/rateLimits/updated` | 接收额度变化通知 |

### 线程、轮次和 item 通知

| 接口 | 作用 |
| --- | --- |
| `thread/started` | 接收线程启动通知 |
| `thread/status/changed` | 接收线程状态变化 |
| `thread/tokenUsage/updated` | 接收线程 Token 用量更新 |
| `turn/started` | 接收轮次开始通知 |
| `turn/completed` | 接收轮次结束通知 |
| `item/started` | 接收执行项开始通知 |
| `item/completed` | 接收执行项结束通知 |

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
| `serverRequest/resolved` | 感知服务端请求已处理完毕 |
| `error` | 接收错误通知 |
| `warning` | 记录服务端警告 |

### 服务端请求

| 接口 | 作用 |
| --- | --- |
| `item/commandExecution/requestApproval` | 观察命令执行审批请求 |
| `item/fileChange/requestApproval` | 观察文件修改审批请求 |
| `item/permissions/requestApproval` | 观察权限审批请求 |
| `mcpServer/elicitation/request` | 观察 MCP 交互请求 |

## 使用的根轮次和子 Agent 字段

| 接口 | 字段 | 作用 |
| --- | --- | --- |
| `thread/turns/list` | 请求参数 `itemsView` | 使用 `notLoaded` 读取轮次信息，使用 `full` 读取包含子 Agent 创建信息的执行项 |
| `thread/turns/list`、`turn/started`、`turn/completed` | `Turn.rootTurnId` | 获取当前轮次所属工作链的根轮次 ID |
| `thread/turns/list`、`item/started`、`item/completed` | `subAgentActivity.model` | 获取 `kind` 为 `started` 时子 Agent 创建所用的实际模型 |
| `thread/turns/list`、`item/started`、`item/completed` | `subAgentActivity.reasoningEffort` | 获取 `kind` 为 `started` 时子 Agent 创建所用的实际推理强度 |

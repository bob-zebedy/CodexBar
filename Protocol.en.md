# app-server API Inventory

Applicable version Codex `0.162.0`

## Outgoing Calls

### Requests

| API | Purpose |
| --- | --- |
| `initialize` | Initialize the connection and retrieve the server version |
| `account/read` | Read account information and refresh authentication |
| `account/rateLimits/read` | Read rate limits, credit balance, and reset credits |
| `account/usage/read` | Read account usage summaries and daily token usage |
| `account/rateLimitResetCredit/consume` | Consume a rate limit reset credit |
| `config/read` | Read Codex TUI notification settings |
| `config/batchWrite` | Update Codex TUI notification settings |
| `thread/loaded/list` | List loaded threads |
| `thread/read` | Read thread information and status |
| `thread/resume` | Subscribe to messages from a loaded thread |
| `thread/turns/list` | Read a thread's turns, statuses, root turn IDs, and sub-agent creation information |

### Notifications

| API | Purpose |
| --- | --- |
| `initialized` | Notify the server that initialization is complete |

## Incoming Messages

### Account Notifications

| API | Purpose |
| --- | --- |
| `account/updated` | Receive account change notifications |
| `account/rateLimits/updated` | Receive rate limit change notifications |

### Thread, Turn, and Item Notifications

| API | Purpose |
| --- | --- |
| `thread/started` | Receive thread start notifications |
| `thread/status/changed` | Receive thread status changes |
| `thread/tokenUsage/updated` | Receive thread token usage updates |
| `turn/started` | Receive turn start notifications |
| `turn/completed` | Receive turn end notifications |
| `item/started` | Receive item start notifications |
| `item/completed` | Receive item end notifications |

### Progress Notifications

| API | Purpose |
| --- | --- |
| `item/agentMessage/delta` | Track response output progress |
| `item/reasoning/textDelta` | Track reasoning text output progress |
| `item/reasoning/summaryTextDelta` | Track reasoning summary output progress |
| `item/commandExecution/outputDelta` | Track command output progress |

### Status and Presentation Notifications

| API | Purpose |
| --- | --- |
| `turn/plan/updated` | Receive plan progress updates |
| `turn/diff/updated` | Observe code diff updates |
| `model/rerouted` | Receive model change information |
| `model/verification` | Observe model verification requirements |
| `modelProvider/authRecoveryStarted` | Observe the start of authentication recovery |
| `modelProvider/authRecoveryCompleted` | Observe the end of authentication recovery |
| `model/safetyBuffering/updated` | Receive safety buffering display status |
| `hook/started` | Observe the start of hook execution |
| `hook/completed` | Receive hook execution results |
| `serverRequest/resolved` | Observe that a server request has been resolved |
| `error` | Receive error notifications |
| `warning` | Log server warnings |

### Server Requests

| API | Purpose |
| --- | --- |
| `item/commandExecution/requestApproval` | Observe command execution approval requests |
| `item/fileChange/requestApproval` | Observe file change approval requests |
| `item/permissions/requestApproval` | Observe permission approval requests |
| `mcpServer/elicitation/request` | Observe MCP elicitation requests |

## Root Turn and Sub-Agent Fields Used

| API | Field | Purpose |
| --- | --- | --- |
| `thread/turns/list` | Request parameter `itemsView` | Use `notLoaded` to read turn information and `full` to read items containing sub-agent creation information |
| `thread/turns/list`, `turn/started`, `turn/completed` | `Turn.rootTurnId` | Read the ID of the root turn in the chain of work leading to the current turn |
| `thread/turns/list`, `item/started`, `item/completed` | `subAgentActivity.model` | Read the resolved model at sub-agent creation when `kind` is `started` |
| `thread/turns/list`, `item/started`, `item/completed` | `subAgentActivity.reasoningEffort` | Read the resolved reasoning effort at sub-agent creation when `kind` is `started` |

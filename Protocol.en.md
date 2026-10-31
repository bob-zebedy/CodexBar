# app-server API inventory

Codex version: `0.162.0`

## Outgoing requests

| API | Purpose |
| --- | --- |
| `initialize` | Initialize the connection and get the server version |
| `account/read` | Read account information; `refreshToken` specifies whether to refresh authentication |
| `account/rateLimits/read` | Read rate limits, credit balance, and reset credits |
| `account/usage/read` | Read account usage summaries and daily token usage |
| `account/rateLimitResetCredit/consume` | Consume a rate limit reset credit; `creditId` identifies the credit, and `idempotencyKey` prevents duplicate consumption |
| `config/read` | Read Codex TUI notification settings |
| `config/batchWrite` | Update Codex TUI notification settings; `edits` specifies the value of `tui.notifications`, and `reloadUserConfig: true` applies the change |
| `thread/loaded/list` | List loaded threads |
| `thread/read` | Read thread information and status; `threadId` identifies the thread, and `includeTurns: false` omits turn content |
| `thread/resume` | Subscribe to messages from a loaded thread; `threadId` identifies the thread, and `excludeTurns: true` omits turn content |
| `thread/turns/list` | Read a thread's turn information in pages; `threadId` identifies the thread, and `itemsView: "notLoaded"` omits item content |
| `thread/items/list` | Read a turn's items in pages; `threadId` and `turnId` identify the target turn |

## Outgoing notifications

| API | Purpose |
| --- | --- |
| `initialized` | Notify the server that initialization is complete |

## Incoming notifications

### Account notifications

| API | Purpose |
| --- | --- |
| `account/updated` | Receive account change notifications |
| `account/rateLimits/updated` | Receive rate limit change notifications |

### Threads, turns, and items

| API | Purpose |
| --- | --- |
| `thread/started` | Receive thread start notifications |
| `thread/status/changed` | Receive thread status changes |
| `thread/tokenUsage/updated` | Receive thread token usage updates |
| `turn/started` | Receive turn start notifications |
| `turn/completed` | Receive turn end notifications |
| `item/started` | Receive item start notifications, including asynchronous questions and user responses |
| `item/completed` | Receive item end notifications, including asynchronous questions and user responses |

### Progress notifications

| API | Purpose |
| --- | --- |
| `item/agentMessage/delta` | Track response output progress |
| `item/reasoning/textDelta` | Track reasoning text output progress |
| `item/reasoning/summaryTextDelta` | Track reasoning summary output progress |
| `item/commandExecution/outputDelta` | Track command output progress |

### Status and presentation notifications

| API | Purpose |
| --- | --- |
| `turn/plan/updated` | Receive plan progress updates |
| `turn/diff/updated` | Observe code diff updates |
| `model/rerouted` | Receive model change information |
| `model/verification` | Observe model verification requirements |
| `modelProvider/authRecoveryStarted` | Receive notifications when authentication recovery starts |
| `modelProvider/authRecoveryCompleted` | Receive notifications when authentication recovery ends |
| `model/safetyBuffering/updated` | Receive safety buffering display status |
| `hook/started` | Receive notifications when a hook starts |
| `hook/completed` | Receive hook execution results |
| `serverRequest/resolved` | Receive notifications when server requests, such as approvals or questions, end |
| `error` | Receive error notifications |
| `warning` | Log server warnings |

## Server requests

| API | Purpose |
| --- | --- |
| `item/commandExecution/requestApproval` | Observe command execution approval requests |
| `item/fileChange/requestApproval` | Observe file change approval requests |
| `item/permissions/requestApproval` | Observe permission approval requests |
| `item/tool/requestUserInput` | Observe questions asked during a turn; `isBlocking` indicates whether the question blocks execution |
| `mcpServer/elicitation/request` | Observe MCP elicitation requests |

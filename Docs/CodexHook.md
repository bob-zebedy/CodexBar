# Codex Hook 工作流统计

本文档记录 CodexBar 接入 Codex Hook 后的配置、存储和统计口径。`AGENTS.md` 只保留开发时必须遵守的边界，具体实现细节以本文档为准。

## 开关行为

设置页「启用 Codex Hook」由 `CodexHookSettings` 管理。开启后，CodexBar 会把当前 App 的可执行文件路径写入全局配置:

```text
~/.codex/hooks.json
```

开启和关闭都会先移除当前 App 可执行文件路径对应的 CodexBar hook。开启时随后按当前 App 路径安装 hook。用户自定义 Hook、其他 App Hook、其他路径的 CodexBar Hook 和同事件下的其他处理器必须保留。

CodexBar 处理器的识别条件:

- `type` 是 `command`
- `command` 必须等于当前 App 可执行文件路径生成的命令, 例如 `'<当前 CodexBar 可执行文件路径>' --hook-event SessionStart`

检测是否已开启时，要求全部 CodexBar 事件都存在当前 App 路径对应的处理器。

## Hook 事件

当前安装的事件:

```text
SessionStart
UserPromptSubmit
PreToolUse
PostToolUse
PermissionRequest
PreCompact
PostCompact
Stop
SubagentStart
SubagentStop
```

命令格式:

```bash
'/Applications/CodexBar.app/Contents/MacOS/CodexBar' --hook-event SessionStart
```

Hook timeout 为 5 秒。App 启动最早阶段会调用 `WorkflowHookEventRecorder.handleIfRequested()`，如果命中 Hook 参数，只记录数据并立即退出正常 App 启动流程。

支持的参数形式:

```bash
--hook-event SessionStart
--hook-event=SessionStart
```

旧的 `codexbar_event` 参数已经删除，不再兼容。

## Payload 解析

Hook stdin 会尝试解析为 Codex 官方 JSON 对象，只读取顶层字段。缺少字段时尽量兜底，不阻断记录。

读取字段:

- 目录: `cwd`
- 工具: `tool_name`
- 模型: `model`
- 权限模式: `permission_mode`，写入 `events.jsonl` 时保存为 `permission`
- 会话: `session_id`
- 轮次: `turn_id`

事件名来自 Hook 命令参数 `--hook-event`，时间戳由 CodexBar 记录时生成。`events.jsonl` 每行按固定顺序写入 `timestamp`、`event`、`model`、`permission`、`session`、`turn`、`cwd`、`tool`；缺失值写为 `null`。每日维护裁剪 `events.jsonl` 时也会用同一编码入口重写保留行，确保字段顺序稳定。

事件名统计时会去掉 `_` 和 `-` 并转小写，因此 `PreToolUse`、`pre_tool_use`、`pre-tool-use` 会归为同一个事件。

常用项目名称只取目录最后一层，不过当前 popup 不展示该字段。

## 本机存储

Hook 数据目录:

```text
~/Library/Application Support/CodexBar/HookEvents/
```

文件职责:

- `events.jsonl`: 原始 Hook 事件日志
- `daily.jsonl`: 每日聚合结果，UI 优先读取它
- `stats.lock`: 并发写入锁文件，只用于 `flock`
- `maintenance.json`: 记录上次每日维护日期、`daily.jsonl` 重建标记、事件日志聚合高水位和最近重建错误

`WorkflowStatsStorage` 定义这些路径和保留策略。UI 读取时优先加载 `daily.jsonl`；如果聚合文件缺失、为空、事件日志高水位不一致或已标记为 dirty，会先尝试后台重建，重建失败时再回退读取 `events.jsonl` 末尾 5MB 生成临时快照。

## 写入事务

Hook 可能由多个 Codex 进程并发触发。`WorkflowHookEventRecorder` 会在同一个 `flock(LOCK_EX)` 中完成轻量写入事务:

1. 追加当前事件到 `events.jsonl`
2. 如当天第一次写入，裁剪超过 210 天的 `events.jsonl` 并更新 `maintenance.json` 中的维护日期
3. 如果 `daily.jsonl` 可信，增量更新当天聚合并记录 `lastAggregatedEventLogSize`
4. 如果发现 `daily.jsonl` 缺失、为空、事件日志高水位不一致或之前已标记 dirty，只写入 `needsDailyRebuild = true`

这样可以避免并发写入导致 `events.jsonl` 或 `daily.jsonl` 丢失数据，也避免在 Hook timeout 内执行全量重建。

`WorkflowStatsService` 在 App 自动刷新、手动刷新或打开 popover 读取工作流统计时检查 `maintenance.json`。如果 `needsDailyRebuild = true` 或事件日志高水位不一致，会在 `CodexBar.workflow-stats` 后台队列中从 `events.jsonl` 重建 `daily.jsonl`。重建时逐行容错，坏行会被跳过并计入 `corruptEventLineCount`; 重建失败时保留旧 `daily.jsonl` 和 dirty 标记, 下次刷新继续重试。

## 保留策略

CodexBar 最多保留最近 210 天数据。

最近 7 天的每日聚合保留 `sessionIds` 和 `turnIds`，用于继续去重。7 天前的日期会把 ID 集合压缩成 `sessionCount` 和 `turnCount`，之后不再保存 ID。210 天外的数据会在每天第一次 Hook 写入时删除。

如果 `daily.jsonl` 缺失、为空、事件日志高水位不一致或之前已标记 dirty，Hook 只会标记 `needsDailyRebuild`; 后续 App 自动刷新、手动刷新或打开 popover 时由后台服务重建每日聚合。

## 统计口径

`events.jsonl` 是统计源。重建或增量更新 `daily.jsonl` 时，每条事件先按 `timestamp` 落到本地时区的自然日，再按 `event` 名称归类。`event` 归类时会去掉 `_` 和 `-` 并转小写，例如 `PreToolUse`、`pre_tool_use`、`pre-tool-use` 都会归为 `pretooluse`。

能参与统计的事件行必须至少满足:

- `timestamp` 能解析为 ISO8601 时间
- `event` 是非空字符串

不满足这两个条件的坏行在重建时会被跳过。其他字段缺失不会阻断统计，只会影响依赖该字段的去重或项目统计。

从 `events.jsonl` 到页面指标的判定规则如下:

| 页面展示名 | 会被计入的 `events.jsonl` 行                                                                                                                                 | 不会计入的典型情况                                                            | 计数方式                                                      |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------- | ------------------------------------------------------------- |
| 会话总数   | 最近 7 天内，任意带非空 `session` 的事件行都会把该 `session` 加入当天去重集合；另外 `event` 归一化为 `sessionstart` 的行会增加 `sessionStartCount`。         | `session` 为 `null` 且 `event` 不是 `SessionStart`；坏行。                    | `max(sessionCount ?? 0, sessionIds.count, sessionStartCount)` |
| 对话轮次   | 最近 7 天内，任意带非空 `turn` 的事件行都会把该 `turn` 加入当天去重集合；另外 `event` 归一化为 `stop` 的行会增加 `stopCount`。                               | `turn` 为 `null` 且 `event` 不是 `Stop`；坏行。                               | `max(turnCount ?? 0, turnIds.count, stopCount)`               |
| 子智能体   | `event` 归一化为 `subagentstart` 或 `subagentstop` 的行。                                                                                                    | 其他事件名；坏行。                                                            | `max(subagentStartCount, subagentStopCount)`                  |
| 工具调用   | `event` 归一化为 `pretooluse` 的行会增加 `preToolUseCount`；归一化为 `posttooluse` 的行会增加 `postToolUseCount`。`tool` 可以是具体工具名，也可以是 `null`。 | `SessionStart` 这类非工具事件，即使 `tool` 是 `null` 或存在也不会计入；坏行。 | `max(preToolUseCount, postToolUseCount)`                      |
| 权限请求   | `event` 归一化为 `permissionrequest` 的行。                                                                                                                  | `permission` 字段本身不会触发计数；只有事件名是 `PermissionRequest` 才计入。  | `permissionRequestCount`                                      |
| 上下文压缩 | `event` 归一化为 `precompact` 或 `postcompact` 的行。                                                                                                        | 其他事件名；坏行。                                                            | `max(preCompactCount, postCompactCount)`                      |

逐字段统计口径如下:

| `daily.jsonl` 字段       | 从 `events.jsonl` 读取什么                           | 写入 / 更新规则                                                                                                                                                                                     | 页面关系                                               |
| ------------------------ | ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| `date`                   | `timestamp`                                          | 先把事件时间解析为绝对时间，再用 `Calendar.current.startOfDay(for:)` 落到当前本地时区的自然日，最后格式化为 `yyyy-MM-dd`。同一天所有事件合并到同一行。早于最近 210 天保留窗口的事件不会进入聚合。   | 热力图日期键；tooltip 日期。                           |
| `eventCount`             | 每条成功解码并保留下来的事件行                       | 每处理一条事件就 `+1`，发生在具体事件类型判断之前。因此 `UserPromptSubmit`、未知 `event`、`tool: null`、`session: null` 等行都会计入，只要 `timestamp` 和 `event` 可解析。                          | 进入 `WorkflowDailyStats.eventCount`，当前页面不展示。 |
| `sessionStartCount`      | `event`                                              | `event` 归一化后等于 `sessionstart` 时 `+1`。不要求 `session` 非空。                                                                                                                                | 作为「会话总数」兜底来源。                             |
| `stopCount`              | `event`                                              | `event` 归一化后等于 `stop` 时 `+1`。不要求 `turn` 非空。                                                                                                                                           | 作为「对话轮次」兜底来源。                             |
| `preToolUseCount`        | `event`                                              | `event` 归一化后等于 `pretooluse` 时 `+1`。不读取 `tool` 做过滤，`tool` 为 `null` 也计入。                                                                                                          | 参与「工具调用」。                                     |
| `postToolUseCount`       | `event`                                              | `event` 归一化后等于 `posttooluse` 时 `+1`。不读取 `tool` 做过滤，`tool` 为 `null` 也计入。                                                                                                         | 参与「工具调用」。                                     |
| `permissionRequestCount` | `event`                                              | `event` 归一化后等于 `permissionrequest` 时 `+1`。不读取 `permission` 字段做过滤，`permission` 只是记录当时的权限模式。                                                                             | 直接显示为「权限请求」。                               |
| `preCompactCount`        | `event`                                              | `event` 归一化后等于 `precompact` 时 `+1`。                                                                                                                                                         | 参与「上下文压缩」。                                   |
| `postCompactCount`       | `event`                                              | `event` 归一化后等于 `postcompact` 时 `+1`。                                                                                                                                                        | 参与「上下文压缩」。                                   |
| `subagentStartCount`     | `event`                                              | `event` 归一化后等于 `subagentstart` 时 `+1`。                                                                                                                                                      | 参与「子智能体」。                                     |
| `subagentStopCount`      | `event`                                              | `event` 归一化后等于 `subagentstop` 时 `+1`。                                                                                                                                                       | 参与「子智能体」。                                     |
| `sessionIds`             | `session`                                            | 仅最近 7 个本地自然日保留。任意事件行只要 `session` 是非空字符串，就插入当天集合并去重、排序；不要求事件类型是 `SessionStart`。超过 7 天后会被压缩为 `sessionCount` 并写成 `null` / 缺失。          | 参与「会话总数」去重。                                 |
| `turnIds`                | `turn`                                               | 仅最近 7 个本地自然日保留。任意事件行只要 `turn` 是非空字符串，就插入当天集合并去重、排序；不要求事件类型是 `Stop`。超过 7 天后会被压缩为 `turnCount` 并写成 `null` / 缺失。                        | 参与「对话轮次」去重。                                 |
| `sessionCount`           | `sessionIds`、旧 `sessionCount`、`sessionStartCount` | 最近 7 天通常为 `null`；日期进入 7 天外窗口后，归一化时写成 `max(sessionCount ?? 0, sessionIds.count, sessionStartCount)`，然后移除 `sessionIds`。这样旧日期不用继续保存完整 ID，也能保留会话总数。 | 参与「会话总数」。                                     |
| `turnCount`              | `turnIds`、旧 `turnCount`、`stopCount`               | 最近 7 天通常为 `null`；日期进入 7 天外窗口后，归一化时写成 `max(turnCount ?? 0, turnIds.count, stopCount)`，然后移除 `turnIds`。这样旧日期不用继续保存完整 ID，也能保留轮次总数。                  | 参与「对话轮次」。                                     |
| `projectCounts`          | `cwd`                                                | 任意事件行只要 `cwd` 非空，就取标准化路径的最后一层目录名作为项目名并 `+1`；如果最后一层为空，回退使用完整路径字符串。统计的是事件数，不是会话数或工具调用数。未知事件也会计入。                    | 用于计算 `mostActiveProject`，当前页面不展示。         |

读取旧 `daily.jsonl` 时，缺失的数字字段按 `0` 处理，缺失的 `projectCounts` 按空字典处理，缺失的 `sessionIds` / `turnIds` / `sessionCount` / `turnCount` 保持为 `nil`。后续归一化会按当前保留策略补齐或压缩这些字段。

UI 不直接展示所有原始字段，而是先生成 `WorkflowDailyStats`:

| 页面展示名 | 生成规则                                                      |
| ---------- | ------------------------------------------------------------- |
| 会话总数   | `max(sessionCount ?? 0, sessionIds.count, sessionStartCount)` |
| 对话轮次   | `max(turnCount ?? 0, turnIds.count, stopCount)`               |
| 子智能体   | `max(subagentStartCount, subagentStopCount)`                  |
| 工具调用   | `max(preToolUseCount, postToolUseCount)`                      |
| 权限请求   | `permissionRequestCount`                                      |
| 上下文压缩 | `max(preCompactCount, postCompactCount)`                      |

`mostActiveProject` 和 `eventCount` 会进入 `WorkflowDailyStats`，但当前页面没有展示。`UserPromptSubmit` 和未知事件不会增加上述 6 个页面指标，只会进入 `eventCount`，有 `cwd` 时也会进入 `projectCounts`。

## UI 展示

用量热力图固定为近 30 周、30 列 x 7 行、周日到周六排列。`account/usage/read` 返回当天 `dailyUsageBuckets` 时, 热力图展示今天的小方块和对应 token 数; 没有当天 bucket 时再按 Hook 开关决定是否包含今天。

Codex Hook 关闭时:

- 默认不包含今天
- tooltip 只显示日期和 token 数
- tooltip 使用较窄宽度

Codex Hook 开启时:

- 热力图包含今天
- 没有当天 token bucket 时, 今天的 token 数显示为 `--`
- tooltip 首行左侧显示日期、右侧显示 token 数
- 后续逐行显示「会话总数」、「对话轮次」、「子智能体」、「工具调用」、「权限请求」、「上下文压缩」

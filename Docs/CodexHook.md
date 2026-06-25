# Codex Hook 工作流统计

本文档记录 CodexBar 接入 Codex Hook 后的配置、存储和统计口径。`AGENTS.md` 只保留开发时必须遵守的边界，具体实现细节以本文档为准。

## 开关行为

设置页「启用 Codex Hook」由 `CodexHookSettings` 管理。开启后，CodexBar 会把当前 App 的可执行文件路径写入全局配置:

```text
~/.codex/hooks.json
```

开启前会先复用 App 当前的 Codex app-server 会话调用 `config/read`。如果有效配置中 `[features] hooks = false`，或兼容旧名 `codex_hooks = false`，CodexBar 不写入 `hooks.json`，并在 Hook 选项下方显示全局禁用说明。

开启和关闭都会先移除 `command` 包含当前 App 可执行文件路径的 CodexBar hook。开启时随后按当前 App 路径安装 hook。用户自定义 Hook、其他 App Hook 和同事件下的其他处理器必须保留。

CodexBar 处理器的识别条件:

- `type` 是 `command`
- `command` 必须包含当前 App 可执行文件路径生成的 shell 命令和 `--hook-event` 参数, 例如 `'<当前 CodexBar 可执行文件路径>' --hook-event`

也就是说，如果用户手写的 Hook 命令同样包含当前 CodexBar 可执行文件路径和 `--hook-event` 参数，也会被当作当前 CodexBar 处理器移除；不同时包含当前路径和 `--hook-event` 的用户 Hook 会保留。

检测是否已开启时，只要任意 CodexBar 事件存在当前 App 路径对应的处理器，开关就保持开启；如果缺少部分事件，`hooks/list` 验证会在 Hook 选项下方显示 `CodexBar Hook 已不完整`。

关闭时会先通过 `hooks/list` 找出 `command` 属于当前 CodexBar 且来源为全局 `hooks.json` 的 Hook key；移除 `hooks.json` 中的处理器后，再通过 `config/read` + `config/batchWrite` 从 `hooks.state` 删除这些 key。清理失败不恢复已经关闭的 Hook，只在 Hook 选项下方提示清理信任状态失败。

开启写入成功后会复用同一条 app-server 会话调用 `hooks/list` 做有效性检查:

- `command`: 必须包含 CodexBar 当前可执行文件路径生成的命令和 `--hook-event` 参数。
- `eventName`: 必须覆盖全部 CodexBar 事件；`hooks/list` 返回值使用 `sessionStart` 这类 lower camel 名称，CodexBar 会与写入的 `SessionStart` 配置名做映射。
- `enabled`: 必须为 `true`，否则提示 Codex 已禁用这些 Hook。
- `sourcePath`: 必须指向全局 `~/.codex/hooks.json`。
- `trustStatus`: `untrusted` 或 `modified` 时，仅对 `sourcePath` 指向全局 `~/.codex/hooks.json` 且 command 属于当前 CodexBar 的 Hook 读取 `key` 和 `currentHash`，通过 `config/batchWrite` upsert 到 `hooks.state` 的 `trusted_hash`，再重新 `hooks/list` 验证。
- `warnings` / `errors`: 参与验证优先级判断；设置页只显示最高优先级问题，完整返回内容进入日志窗口。

`config/read`、`hooks/list` 和 `config/batchWrite` 都通过 `AppServerSession.request` 调用，请求和响应会进入 CodexBar 日志窗口。

`config/read` 请求失败时，CodexBar 不写入 `hooks.json`，调用 `refresh()` 恢复本地实际状态，并在 Hook 选项下方显示 `设置 Codex Hook 失败: <错误>`。只有请求成功且明确读到全局禁用 Hook 时，才显示 `Codex 配置已禁用 Hook`。

`hooks/list`、自动信任写入或二次验证失败时，CodexBar 不回滚已经写入的 Hook。请求失败时显示 `无法验证 Codex Hook: <错误>`；请求成功但验证未通过时只显示最高优先级的一条摘要。当前优先级为: 无返回结果、Codex 返回错误、Hook 被禁用、Hook 未被信任、事件不完整、来源异常、Codex 返回警告。

Hook 事件定义集中在 `CodexHookEvent`。`configName` 用于写入 `hooks.json`, `appServerName` 用于匹配 `hooks/list` 返回的 lower camel 事件名, `init(eventName:)` 用于把 events 中的 `hook_event_name` 归一化到同一组事件。

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
'/Applications/CodexBar.app/Contents/MacOS/CodexBar' --hook-event
```

Hook timeout 为 5 秒。App 启动最早阶段会调用 `WorkflowHookEventRecorder.handleIfRequested()`，只有启动参数包含 `--hook-event` 时才读取 stdin；如果识别到 Hook 输入，只记录数据并立即退出正常 App 启动流程。

Hook 子进程通过 `--hook-event` 参数进入记录模式, 再通过 stdin payload 顶层 `hook_event_name` 判断事件名。

## Payload 解析

Hook stdin 会尝试解析为 Codex 官方 JSON 对象，只读取顶层字段。`hook_event_name` 是记录事件的必需字段；其他字段缺失时尽量兜底，不阻断记录。

读取字段:

- 事件: `hook_event_name`
- 目录: `cwd`
- 工具: `tool_name`
- 模型: `model`
- 权限模式: `permission_mode`，写入 `events/YYYY-MM-DD.jsonl` 时保存为 `permission`
- 会话: `session_id`
- 轮次: `turn_id`

事件名来自 payload 顶层 `hook_event_name`。没有 `--hook-event` 参数时按普通 App 启动；有 `--hook-event` 参数但 stdin 为空、不是 JSON 或事件名缺失时吞掉本次 Hook，避免 Hook 子进程继续启动完整菜单栏 App。事件时间优先读取 payload 顶层 `timestamp`，解析后按本机时区写成 `yyyy-MM-dd HH:mm:ss.SSS`；如果 `timestamp` 缺失或无法解析，记录当前时间作为兜底。同一个事件时间也会按本机时区格式化为 `yyyy-MM-dd` 的 date key，用于选择 `events/YYYY-MM-DD.jsonl` 文件。日期和时间解析统一走 `CodexDateFormat`，其中高频的 `yyyy-MM-dd` key 由本机 Gregorian 日历组件生成和校验，不暴露可变 `DateFormatter` 实例。每行按固定顺序写入 `timestamp`、`event`、`model`、`permission`、`session`、`turn`、`tool`、`cwd`；缺失值写为 `null`。

事件名统计时会去掉 `_` 和 `-` 并转小写，因此 `PreToolUse`、`pre_tool_use`、`pre-tool-use` 会归为同一个事件。

常用项目名称只取目录最后一层，不过当前 popup 不展示该字段。

## 本机存储

Hook 数据目录:

```text
~/Library/Application Support/CodexBar/HookEvents/
```

文件职责:

- `events/YYYY-MM-DD.jsonl`: 按本机日期拆分的原始 Hook 事件日志
- `daily.jsonl`: 每日聚合结果，UI 优先读取它
- `stats.lock`: 并发写入锁文件，只用于 `flock`
- `maintenance.json`: 记录待整理日期、需要重建日期和每个日期的处理进度

`maintenance.json` 当前结构:

```json
{
    "schema": 2,
    "pending": ["2026-06-21"],
    "dirty": [],
    "days": {
        "2026-06-21": {
            "offset": 102400,
            "size": 122880,
            "corrupt": 0
        }
    }
}
```

`pending` 表示有新增事件等待整理的日期；`dirty` 表示需要从头重建 `daily.jsonl` 对应日期的日期；`offset` 是当天 events 文件已经处理到的字节位置；`size` 是上次处理完成时当天 events 文件大小；`corrupt` 是当天解析失败的 JSONL 行数。

`WorkflowStatsStorage` 定义这些路径和保留策略。UI 读取时优先加载 `daily.jsonl`；原始事件文件不再作为 UI 临时快照回退源。

旧版单文件 `HookEvents/events.jsonl` 不参与新版统计、迁移或清理。

## 写入事务

Hook 可能由多个 Codex 进程并发触发。`WorkflowHookEventRecorder` 会在同一个 `flock(LOCK_EX)` 中完成轻量写入事务:

1. 解析事件时间并格式化为本机时间戳与 date key
2. 追加当前事件到 `events/YYYY-MM-DD.jsonl`
3. 将 date key 加入 `maintenance.json` 的 `pending`

Hook 写入路径不更新 `daily.jsonl`，也不执行重建或清理旧文件，避免在 Hook timeout 内持锁执行重活。

`WorkflowStatsService` 是 actor，只在现有自动刷新或手动刷新触发工作流统计刷新时检查 `maintenance.json`。打开菜单面板时只读取现有 `daily.jsonl`。如果没有 `pending` 或 `dirty`，服务不会执行维护。

维护时优先处理 `dirty`，从对应日期文件第一行开始流式重建当天聚合；再处理 `pending`，从 `days[date].offset` 开始流式读取新增事件并合并到已有当天聚合。每条坏行会被跳过并计入 `days[date].corrupt`。处理完成后先在 `stats.lock` 外原子写回 `daily.jsonl`，再短暂持有 `stats.lock` 更新 `maintenance.json`，避免主 App 写 daily 时阻塞 Hook 追加事件。

## 保留策略

CodexBar 最多保留最近 210 天数据。

最近 3 个本地自然日的每日聚合保留 `sessionIds` 和 `turnIds`，用于继续去重。早于最近 3 天窗口的日期会把 ID 集合压缩成 `sessionCount` 和 `turnCount`，之后不再保存 ID。210 天外的 `events/YYYY-MM-DD.jsonl` 会在主 App 维护流程中删除。

如果 `daily.jsonl` 缺失、为空、解析失败、缺少对应日期摘要，或者某天 events 文件状态和 `maintenance.json` 不一致，主 App 会把对应日期加入 `dirty` 并在刷新维护时按天重建。

## 统计口径

`events/YYYY-MM-DD.jsonl` 是统计源。Hook 写入时已经按事件自身 `timestamp` 选择对应本地日期文件；重建或增量更新 `daily.jsonl` 时，维护流程按当前处理的文件日期生成当天聚合，再按每行的 `event` 名称归类。`event` 归类时会去掉 `_` 和 `-` 并转小写，例如 `PreToolUse`、`pre_tool_use`、`pre-tool-use` 都会归为 `pretooluse`。

`daily.jsonl` 每一行 JSON 的字段顺序固定为:

```text
date, eventCount, sessionStartCount, stopCount, preToolUseCount, postToolUseCount,
permissionRequestCount, preCompactCount, postCompactCount, subagentStartCount,
subagentStopCount, sessionCount, turnCount, projectCounts, sessionIds, turnIds
```

其中 `sessionIds` / `turnIds` / `sessionCount` / `turnCount` 没有值时写为 `null`，`projectCounts` 内部项目名按稳定顺序写出。

能参与统计的事件行必须至少满足:

- `timestamp` 能解析为 `yyyy-MM-dd HH:mm:ss.SSS` 本机时间
- `event` 是非空字符串

不满足这两个条件的坏行在重建时会被跳过。其他字段缺失不会阻断统计，只会影响依赖该字段的去重或项目统计。

从 `events/YYYY-MM-DD.jsonl` 到页面指标的判定规则如下:

| 页面展示名 | 会被计入的 `events/YYYY-MM-DD.jsonl` 行                                                                                                                        | 不会计入的典型情况                                                            | 计数方式                                                               |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| 会话总数   | 最近 3 个本地自然日内，任意带非空 `session` 的事件行都会把该 `session` 加入当天去重集合；另外 `event` 归一化为 `sessionstart` 的行会增加 `sessionStartCount`。 | `session` 为 `null` 且 `event` 不是 `SessionStart`；坏行。                    | 优先 `sessionCount`，其次 `sessionIds.count`，最后 `sessionStartCount` |
| 对话轮次   | 最近 3 个本地自然日内，任意带非空 `turn` 的事件行都会把该 `turn` 加入当天去重集合；另外 `event` 归一化为 `stop` 的行会增加 `stopCount`。                       | `turn` 为 `null` 且 `event` 不是 `Stop`；坏行。                               | 优先 `turnCount`，其次 `turnIds.count`，最后 `stopCount`               |
| 子智能体   | `event` 归一化为 `subagentstart` 或 `subagentstop` 的行。                                                                                                      | 其他事件名；坏行。                                                            | `max(subagentStartCount, subagentStopCount)`                           |
| 工具调用   | `event` 归一化为 `pretooluse` 的行会增加 `preToolUseCount`；归一化为 `posttooluse` 的行会增加 `postToolUseCount`。`tool` 可以是具体工具名，也可以是 `null`。   | `SessionStart` 这类非工具事件，即使 `tool` 是 `null` 或存在也不会计入；坏行。 | `max(preToolUseCount, postToolUseCount)`                               |
| 权限请求   | `event` 归一化为 `permissionrequest` 的行。                                                                                                                    | `permission` 字段本身不会触发计数；只有事件名是 `PermissionRequest` 才计入。  | `permissionRequestCount`                                               |
| 上下文压缩 | `event` 归一化为 `precompact` 或 `postcompact` 的行。                                                                                                          | 其他事件名；坏行。                                                            | `max(preCompactCount, postCompactCount)`                               |

逐字段统计口径如下:

| `daily.jsonl` 字段       | 从 `events/YYYY-MM-DD.jsonl` 读取什么                | 写入 / 更新规则                                                                                                                                                                                                           | 页面关系                                               |
| ------------------------ | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| `date`                   | `timestamp`                                          | Hook 写入时先把事件时间解析为绝对时间，再按当前本地时区格式化为 `yyyy-MM-dd` 选择日期文件。维护流程按当前处理的文件日期生成同名 `daily.jsonl` 行。早于最近 210 天保留窗口的日期不会进入聚合。                             | 热力图日期键；详情面板日期。                           |
| `eventCount`             | 每条成功解码并保留下来的事件行                       | 每处理一条事件就 `+1`，发生在具体事件类型判断之前。因此 `UserPromptSubmit`、未知 `event`、`tool: null`、`session: null` 等行都会计入，只要 `timestamp` 和 `event` 可解析。                                                | 进入 `WorkflowDailyStats.eventCount`，当前页面不展示。 |
| `sessionStartCount`      | `event`                                              | `event` 归一化后等于 `sessionstart` 时 `+1`。不要求 `session` 非空。                                                                                                                                                      | 作为「会话总数」兜底来源。                             |
| `stopCount`              | `event`                                              | `event` 归一化后等于 `stop` 时 `+1`。不要求 `turn` 非空。                                                                                                                                                                 | 作为「对话轮次」兜底来源。                             |
| `preToolUseCount`        | `event`                                              | `event` 归一化后等于 `pretooluse` 时 `+1`。不读取 `tool` 做过滤，`tool` 为 `null` 也计入。                                                                                                                                | 参与「工具调用」。                                     |
| `postToolUseCount`       | `event`                                              | `event` 归一化后等于 `posttooluse` 时 `+1`。不读取 `tool` 做过滤，`tool` 为 `null` 也计入。                                                                                                                               | 参与「工具调用」。                                     |
| `permissionRequestCount` | `event`                                              | `event` 归一化后等于 `permissionrequest` 时 `+1`。不读取 `permission` 字段做过滤，`permission` 只是记录当时的权限模式。                                                                                                   | 直接显示为「权限请求」。                               |
| `preCompactCount`        | `event`                                              | `event` 归一化后等于 `precompact` 时 `+1`。                                                                                                                                                                               | 参与「上下文压缩」。                                   |
| `postCompactCount`       | `event`                                              | `event` 归一化后等于 `postcompact` 时 `+1`。                                                                                                                                                                              | 参与「上下文压缩」。                                   |
| `subagentStartCount`     | `event`                                              | `event` 归一化后等于 `subagentstart` 时 `+1`。                                                                                                                                                                            | 参与「子智能体」。                                     |
| `subagentStopCount`      | `event`                                              | `event` 归一化后等于 `subagentstop` 时 `+1`。                                                                                                                                                                             | 参与「子智能体」。                                     |
| `sessionIds`             | `session`                                            | 仅最近 3 个本地自然日保留。任意事件行只要 `session` 是非空字符串，就插入当天集合并去重、排序；不要求事件类型是 `SessionStart`。窗口外日期会被压缩为 `sessionCount` 并写成 `null`。                                        | 参与「会话总数」去重。                                 |
| `turnIds`                | `turn`                                               | 仅最近 3 个本地自然日保留。任意事件行只要 `turn` 是非空字符串，就插入当天集合并去重、排序；不要求事件类型是 `Stop`。窗口外日期会被压缩为 `turnCount` 并写成 `null`。                                                      | 参与「对话轮次」去重。                                 |
| `sessionCount`           | `sessionIds`、旧 `sessionCount`、`sessionStartCount` | 最近 3 天通常为 `null`；日期进入 3 天外窗口后，归一化时优先沿用已有 `sessionCount`，否则使用 `sessionIds.count`，再否则使用 `sessionStartCount`，然后移除 `sessionIds`。这样旧日期不用继续保存完整 ID，也能保留会话总数。 | 参与「会话总数」。                                     |
| `turnCount`              | `turnIds`、旧 `turnCount`、`stopCount`               | 最近 3 天通常为 `null`；日期进入 3 天外窗口后，归一化时优先沿用已有 `turnCount`，否则使用 `turnIds.count`，再否则使用 `stopCount`，然后移除 `turnIds`。这样旧日期不用继续保存完整 ID，也能保留轮次总数。                  | 参与「对话轮次」。                                     |
| `projectCounts`          | `cwd`                                                | 任意事件行只要 `cwd` 非空，就取标准化路径的最后一层目录名作为项目名并 `+1`；如果最后一层为空，回退使用完整路径字符串。统计的是事件数，不是会话数或工具调用数。未知事件也会计入。                                          | 用于计算 `mostActiveProject`，当前页面不展示。         |

读取旧 `daily.jsonl` 时，缺失的数字字段按 `0` 处理，缺失的 `projectCounts` 按空字典处理，缺失的 `sessionIds` / `turnIds` / `sessionCount` / `turnCount` 保持为 `nil`。后续归一化会按当前保留策略补齐或压缩这些字段。

UI 不直接展示所有原始字段，而是先生成 `WorkflowDailyStats`:

| 页面展示名 | 生成规则                                                |
| ---------- | ------------------------------------------------------- |
| 会话总数   | `sessionCount ?? sessionIds.count ?? sessionStartCount` |
| 对话轮次   | `turnCount ?? turnIds.count ?? stopCount`               |
| 子智能体   | `max(subagentStartCount, subagentStopCount)`            |
| 工具调用   | `max(preToolUseCount, postToolUseCount)`                |
| 权限请求   | `permissionRequestCount`                                |
| 上下文压缩 | `max(preCompactCount, postCompactCount)`                |

`mostActiveProject` 和 `eventCount` 会进入 `WorkflowDailyStats`，但当前页面没有展示。`UserPromptSubmit` 和未知事件不会增加上述 6 个页面指标，只会进入 `eventCount`，有 `cwd` 时也会进入 `projectCounts`。

## UI 展示

用量热力图固定为近 30 周、30 列 x 7 行、周日到周六排列。`account/usage/read` 返回当天 `dailyUsageBuckets` 时, 热力图展示今天的小方块和对应 token 数; 没有当天 bucket 时再按 Hook 开关决定是否包含今天。

热力图 hover 时不在菜单面板内绘制旧式 tooltip, 而是通过 `UsageHeatmapHoverContext` 通知 `HeatmapDetailPanelController` 展示侧边详情面板。指针会吸附到最近方块, 离开热力图后延迟 160 ms 清除选中状态。

详情面板是菜单面板的 borderless nonactivating child panel:

- 不接收鼠标事件, 不抢走菜单面板 key window
- 按悬停列优先显示在菜单面板左侧或右侧, 左右空间不足时尝试另一侧
- 最终位置会被夹在当前屏幕可见区域内, 屏幕边缘保留 `8` px
- 与菜单面板之间保留 `4` px gap
- 侧边切换使用抽屉动画: 收起 `0.12` 秒, 展开 `0.18` 秒

Codex Hook 关闭时:

- 默认不包含今天
- 详情面板显示日期, token 数和「用量强度」分段条
- 详情面板固定为 `212 x 84`
- 详情面板横向 padding 为 `12`, 纵向 padding 为 `10`, 圆角为 `12`
- 日期使用 `.caption2.monospacedDigit()`
- token 数使用 `14pt` 等宽数字并加粗
- token 数通过 `TokenCountText` 展示: `1K` 以下显示完整整数, `1K` 起显示 `K` / `M` / `B`, 不使用千位逗号; 文本自身允许缩小到 `0.8`

Codex Hook 开启时:

- 热力图包含今天
- 没有当天 token bucket 时, 今天的 token 数显示为 `--`
- 详情面板首行左侧显示日期、右侧显示 token 数
- 第二行显示「用量强度」分段条
- 后续逐行显示「会话总数」、「对话轮次」、「子智能体」、「工具调用」、「权限请求」、「上下文压缩」
- 详情面板固定为 `212 x 189`
- 详情面板横向 padding 为 `12`, 纵向 padding 为 `10`, 圆角为 `12`
- 日期使用 `.caption2.monospacedDigit()`, token 数使用 `14pt` 等宽数字并加粗
- 工作流统计行整体使用 `11pt`; 左侧标签固定宽度 `72`, 标签和值之间 spacing 为 `6`
- 工作流统计行右侧数字优先使用正常字号完整展示; 只有正常字号在横向剩余空间内放不下时, 才会启用自动缩小, 最小缩放比例为 `0.60`, 并允许字距收紧

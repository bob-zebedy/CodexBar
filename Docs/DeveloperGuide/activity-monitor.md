# 实时任务监控

简体中文 | [English](../en/DeveloperGuide/activity-monitor.md)

## 目标

实时任务链路需要回答 4 个问题：

- 当前是否有任务正在运行
- 当前是否在等待用户批准
- 最近任务是完成还是终止
- 哪些运行任务已经长时间没有进展

Hook 事件提供实时进展和中断信号，rollout 文件补充生命周期信息。[`CodexActivityMonitor.swift`](../../CodexBar/Services/Workflow/CodexActivityMonitor.swift) 合并两者并发布唯一任务快照：

```text
Codex Hook -> WorkflowHookEventRecorder -> Hook JSONL
                                            |-> WorkflowService -> 历史日聚合
                                            |-> HookEventTailReader -----+
                                                                         |-> CodexActivityMonitor
rollout JSONL -> CodexSessionLifecycleReader ----------------------------+           |
                                                                                     v
                                                                            CodexActivitySnapshot
                                                                                     |-> 活动卡片和任务中心
                                                                                     |-> 流光和防睡眠
```

`WorkflowHookEventRecorder` 从 `stdin` 提取最小字段，按需有界回查 rollout 元数据，加锁追加事件后退出。历史聚合和实时任务分别读取同一份 Hook JSONL；app-server 额度与用量走独立链路。采集与聚合细节见 [Hook 采集与历史聚合](hook-and-aggregation.md)

通知和触觉反馈消费 monitor 发布的实时转场。流光消费快照与终态展示事件：等待用户批准为橙色，运行中为青色，完成为绿色，终止为红色。存在等待任务时，活跃状态优先显示橙色；短暂终态提示可以覆盖活跃状态。

### 两种来源的分工

| 信息 | 优先来源 | 补充来源 |
| --- | --- | --- |
| prompt, tool, compact, subagent 实时进展 | Hook | rollout progress |
| 用户审批候选 | `PermissionRequest` | rollout reviewer 确认 |
| turn 起点 | `UserPromptSubmit` | rollout startedAt 或历史回查 |
| 完成候选 | `Stop` | rollout terminal |
| 明确的 turn 中断 | `Interrupt` | rollout terminal |
| 其他终态确认 | rollout terminal | 无明确终态时保留待确认任务，到期清理 |
| effort | Hook recorder 回查 | rollout lifecycle backfill |

Hook 每轮读取后等待 2 秒，rollout 每轮对账后等待 1 秒。

### 快照与转场

snapshot 可以在 View 重建、新消费者订阅或设置变化时反复读取。transition 只允许 live 数据产生一次。

例如 App 启动时 bootstrap 恢复出一个已经等待批准的任务：

- snapshot 显示它正在等待
- transition 不发布等待事件
- 通知服务因此不会补发一条历史通知

任务完成也一样。通知服务消费 `.completed` transition，不扫描 `recentCompletions`，避免 App 重启或 UI 刷新重复提醒。

## HookEventTailReader

[`HookEventTailReader.swift`](../../CodexBar/Services/Workflow/HookEventTailReader.swift) 是 actor，默认每 2 秒检查 Hook 事件文件。

### Bootstrap

首次启动读取最近 24 小时文件以建立任务基线：

- 每块最多读取 512 KiB
- 最多尝试 3 次获得稳定文件边界
- 使用 inode 和 size 判断读取期间是否发生替换或追加
- bootstrap 结果不会触发历史完成或等待通知

无法得到稳定边界时，reader 清空恢复态，跳到各日期文件末尾，并发布不健康状态。

### bootstrap 是一个逻辑事务

24 小时窗口可能跨两个自然日文件，单个文件又会分成多个 512 KiB batch 发送。

monitor 在 `.bootstrapStart` 时先清空上一次恢复态并暂停副作用，接收所有 `.bootstrapEvents`，最后在 `.bootstrapEnd` 才统一：

- 用 rollout 补齐生命周期
- 应用持久化异常保护记录
- 按当前阈值静默对账
- 定向回查缺失 prompt 起点
- 发布完整 snapshot

中间 batch 只更新内部任务状态。rollout 补齐和异常保护对账要求数据源健康，且系统未处于睡眠。

### 稳定边界重试

reader 在每次尝试开始时固定所有日期文件的 inode 和 size，读取到这些上界后再次验证：

- 历史日期必须 inode 和 size 都不变
- 当前日期允许在固定上界之后继续 append
- 当前自然日不能在读取期间跨过零点

任何条件不成立都从新的基线重试。连续 3 次失败后跳到当前文件末尾，并发布 degraded health，暂停异常会话保护判断。

bootstrap 因目录暂时不存在、不可读或边界不稳定而失败后，reader 最多每 10 秒重新尝试一次。目录恢复后的已有事件通过 bootstrap 静默重放，成功后才恢复正常增量读取。完整坏行导致的历史覆盖缺口不会因普通读取成功而消失，也不会触发无限历史重读。

### 完整行游标

Hook recorder 可能正在写最后一行。reader 只把最后一个 newline 之前的字节计入 `completeOffset`

半行不会丢弃，也不会被当作损坏事件。下一轮从旧 offset 重新读取，等行完整后再提交。未读完固定上界时，屏障返回 `sourceUnavailable`。完整坏行会使对应日期游标降级，不能因跳过坏行而报告健康；该日期退出读取窗口或文件替换重放后重新确定健康状态。

Hook 数据源降级期间仍会为已知任务读取 rollout，但只接受本轮完整读取、身份匹配的明确完成或中断记录，并静默结束对应任务。该路径不应用普通进展、不回填审批状态、不恢复隐藏任务，也不恢复异常会话保护。系统睡眠和 bootstrap 期间暂停该路径；任务取消或 reader 代次变化后丢弃读取结果。完整生命周期恢复仍要求 Hook 读取屏障成功。

### 跨日与文件替换

reader 为滚动 24 小时覆盖的每个自然日保留独立游标，每轮读取窗口内的全部日期。跨多日恢复会补读中间日期，切日后仍读取前一日的迟到追加。inode 改变或文件缩小时重新 bootstrap，不沿用旧游标。

当 `UserPromptSubmit` 早于当前增量窗口时，reader 可以向前回查最多 8 MiB，为现存任务补齐 prompt 起点。

### drainNow 读取屏障

`drainNow()` 的每个调用方必须等待一轮在本次请求之后开始的读取：

```text
调用 drainNow
  -> 记录请求代际
  -> 等待下一轮新读取开始
  -> 等待该轮读取完成
  -> 返回该轮结果
```

调用发生前已经在执行的读取不能满足屏障。reader 被替换、数据源不可用或任务取消时，调用方不能使用旧快照继续判定。

### 屏障的具体代际语义

每次 `drainNow()` 都递增 `requestedDrainGeneration` 并注册独立 waiter。

如果读取已经在途，新请求只把 `hasPendingDrain` 设为 true。当前轮完成后 reader 必须再开始一轮，这轮才会捕获该请求的 generation。

一轮读取可以同时满足在它开始前排队的多个 waiter，但不能满足读取开始后才加入的 waiter。这正是唤醒恢复需要的 happens-after 保证。

actor 在 `await` 期间可以重入，因此 `isProcessingReads` 和 `hasPendingDrain` 共同把所有外部请求收敛成一个串行 drain loop，避免两个读取同时推进 offset。

## Rollout 生命周期读取

[`CodexSessionLifecycleReader.swift`](../../CodexBar/Services/Workflow/CodexSessionLifecycleReader.swift) 读取 `$CODEX_HOME/sessions` 和 `$CODEX_HOME/archived_sessions`

读取规则如下：

- 默认每 1 秒检查一次
- 初始尾部窗口为 512 KiB
- effort 等 turn context 字段最多回查 8 MiB
- 只解析线程归属、生命周期、turn、progress、effort 和 reviewer
- 对话内容不进入活动模型或产品展示

Hook 的 `Stop` 将任务标记为“正在收尾”，保留在活动列表；仍有其他 Agent 等待用户批准时优先显示等待。后续工具、审批等进展继续更新同一任务；rollout 的完成记录确认本轮结束，满足转场时效和恢复条件时发布完成转场。

rollout 暂时不可读或无法关联 session、turn 时，任务继续等待对账。`Stop` 不启动终态超时；新 turn 或 `SessionEnd` 将旧任务移出活动列表，开始前 5 秒的快速终态查询，之后每 30 秒继续查询。迟到的 `Stop` 只更新待确认任务的元数据与进展，不恢复展示或重置窗口。

### 明确中断

`Interrupt` 结束匹配的顶层 turn，清理保护状态和通知，并保存终止记录。运行、等待批准、已隐藏和待确认终态的任务均可匹配；同一 session 的新 turn 保持活跃。身份有歧义时忽略该事件。

同一任务的 Hook 和 rollout 终态共用去重记录，先确认的完成或终止结果保留。终止记录用于展示，不触发完成通知或触觉反馈。

### session 文件如何定位

reader 先检查最可能的少量目录：

1. 任务开始日期对应的 `sessions/YYYY/MM/DD`
2. 当前日期目录
3. `archived_sessions`

resume 可能继续很早以前创建的 session。快速路径找不到时，快速路径每 10 秒允许重试，递归兜底每 60 秒允许重试，避免每秒 poll 都扫描整个 sessions 树，同时允许发现迟到或移动的文件。

文件被移到 archive 后，已缓存 URL 不存在会清除 cursor 并允许重新完整定位。

文件名按线程 ID 精确匹配，允许线程 ID 后带一个下划线和 UUID 后缀。候选文件须唯一，且首条 `session_meta.id` 与目标线程一致；读取元数据时采用与 Hook recorder 相同的[有界首行解析](hook-and-aggregation.md#来源归一化)

### Rollout 读取预算

实时任务只需要活跃 turn 附近的 lifecycle，全量读取一个长期 session 会增加常驻 I/O。

初始 cursor 从最后 512 KiB 开始并丢弃第一条可能不完整的行。缺少上下文、effort 或 reviewer 时，最多向前重放 8 MiB，统一恢复 turn 归属、元数据和进展。每个文件游标成功补读一次后停止回查，每轮最多补读一个 session。

每轮增量扫描总预算为 8 MiB，多个 session 轮转共享预算；待确认任务每轮最多查询 16 个。超过预算或尚未读到完整行时返回 `incomplete`，读取失败返回 `unavailable`，未找到文件返回 `notFound`。缓存可以保留已经观察到的事实，但不能替代本轮读取成功。成功读到固定上界且恢复了 turn 上下文时，`lifecycleCoverageCheckedAt` 记录本次检查时间；读取未完成、失败、文件不存在或缺少上下文时将其清空。常规异常静默判定要求该时间存在且距当前不足 5 秒。

增量扫描按实际读取字节推进 offset，并跨轮拼接未结束的行。每轮读取预算仍为 8 MiB，单行最多缓冲 16 MiB；超过缓冲上限时标记读取缺口并分块跳到换行，后续记录仍可继续消费。明确的 rollout 终态不受此前读取缺口影响。

文件可读且已经追到实际末尾，仅剩有界残缺末行时，reader 记录首次观察或最近一次追加的时间。任务已有 turn 上下文、没有其他覆盖缺口或已知终态，且本次观察距当前不足 5 秒时，可以使用残缺末行兜底：任务最后进展和末行最后增长均达到用户设置的静默阈值后，允许隐藏任务。末行继续增长会重新计时；读取失败、文件替换或截断、App 重启后重新开始观察。积压未读完、缺少上下文和超限丢弃中的行不能使用此兜底。

残缺末行始终返回 `incomplete`，观察结果用于保护计时、调度和隐藏前复核，不作为终态或进展，也不直接触发任务恢复。后续补完记录后，按正常完整读取流程处理进展和终态。

rollout 坏行将当时尚未结束的 turn 标记为有覆盖缺口，后续重复的同一 turn 上下文不能清除此标记。新的 turn 独立建立覆盖，身份明确的完成或中断记录可以结束有缺口的任务；后续坏行不会撤销已经读到的明确终态。读取失败或尚未读完时，缓存进展不推进任务的执行时间，也不能恢复隐藏任务或清除保护记录。

### Rollout 进展的 turn 归属

每个 session 的文件游标保存独立的 `currentTurnId`，按 JSONL 文件顺序更新：

- 外层 `type = "turn_context"`，或外层 `type = "event_msg"` 且 `payload.type` 为 `task_started` 或 `turn_started` 时，以 `payload.turn_id` 建立上下文
- `response_item` 优先使用 `payload.internal_chat_message_metadata_passthrough.turn_id`；其他进展记录使用 `payload.turn_id`，缺失时沿用游标上下文
- 当前 turn 的 `task_complete`、`turn_complete` 或 `turn_aborted` 清空上下文；迟到的其他 turn 终态不清空它
- 文件截断或替换时重建游标，同时清空上下文和已缓存的生命周期

进展记录包括外层 `type` 为 `response_item` 或 `token_usage_record` 的记录，以及外层为 `event_msg`、`payload.type` 为 `token_count`、`item_completed`、`agent_message`、`agent_reasoning`、`task_started`、`turn_started`、`task_complete`、`turn_complete` 或 `turn_aborted` 的记录。时间依次取外层 `timestamp`、`payload.completed_at`、`payload.started_at`。

记录须有可用时间和 turn 归属，本轮读取完整且时间晚于任务的 `lastProgressAt` 时才更新进展。`token_usage_record` 按活动记录处理，不比较 token 数量是否增加。缺少显式 turn 和游标上下文的记录不计入任务进展。

能用于推断审批恢复的执行进展单独记录为 `lastExecutionProgressAt`：包括 `response_item` 中 `role = "assistant"` 的记录及类型为 `function_call_output`、`custom_tool_call_output`、`tool_search_output` 的工具结果，以及 `agent_message`、`agent_reasoning` 事件。只有同一 Agent／轮次中晚于审批请求的执行进展才清除该等待；用量记录等普通活动只更新任务进展时间。

### Rollout 解析字段

共享的 `CodexRolloutLineEnvelope` 只提取 turn context, lifecycle 和 progress 所需字段。prompt, response 和 tool 内容不会进入活动模型。

终态要求 `payload.turn_id` 非空，并且本轮读取状态为 `complete`。外层 `type = "event_msg"` 时，`payload.type` 为 `task_complete` 或 `turn_complete` 确认完成，完成时间优先使用有效的 `payload.completed_at`（Unix 秒），缺失或无效时使用外层 `timestamp`；两者均不可用时不确认完成。`payload.type = "turn_aborted"` 确认中断。非负且有限的 `payload.duration_ms` 换算为秒后用于耗时展示；中断时间缺失时，活动任务使用对账时间，待确认任务使用移出活动列表的时间，结果均不早于任务最后活动时间。

## 任务身份

任务 key 按可用信息选择最精确身份：

1. `session ID + turn ID`
2. `session ID`
3. 匿名 project key

新的 prompt 会替代同一 session 的旧 turn。旧 turn 在后台等待明确终态，前 5 秒快速查询，之后每 30 秒补查，最长保留到移出活动列表后的 24 小时。

subagent 事件更新父任务的 subagent 活动，不创建独立顶层任务卡片。

### 身份精度与回退

`session ID + turn ID` 能精确区分同一 session 中顺序执行的 turn，是首选身份。

某些事件只有 session ID。后续顶层 Hook 匹配到该任务并提供 turn ID 时，任务在内存中补充 `associatedTurnId` 和终态别名，用于 rollout 查询与去重；初始 key 和保护哈希保持不变。

终态匹配先检查精确 key 及别名，再按 session 检查待确认任务。待确认候选唯一时使用该任务，多个时返回 `ambiguous`；没有待确认候选时再检查活动任务。候选须满足 Hook 时间顺序及 turn 身份条件。

完全没有 session ID 时只能使用 project key。这个 key 可能把同项目并发匿名任务合并，所以匿名任务只承担可撤销的 UI 展示，不驱动通知、防睡眠或持久化保护。

### 实时任务来源过滤

`CodexActivityMonitor.apply` 先解析实时链路的有效来源，再执行任务状态转换。沿用缓存来源时，事件副本使用该来源进行过滤和执行身份判断，原始 JSONL 保持不变。来源归一化规则见 [Hook 来源归一化](hook-and-aggregation.md#来源归一化)

monitor 按精确的 `session ID + turn ID` 在内存中保存来源，保留 24 小时。Codex 的 subagent Hook 复用父 session ID，因此来源判定不扩大到整个 session。

| 事件来源 | 实时处理 |
| --- | --- |
| `main`、`auxiliary` | 记录明确来源，并按正常状态机处理 |
| `autoReview` | 忽略事件，清理同 key 的活动任务、待确认终态、展示记录和异常保护；保留来源记忆 |
| `unknown`，同 key 有有效的 `main` 或 `auxiliary` 来源 | 沿用已确认来源，继续处理事件 |
| `unknown`，没有有效的正常来源记忆 | 忽略事件 |

缺少 session ID 或 turn ID 时不保存来源记忆，`unknown` 和 `autoReview` 事件直接忽略。来源已确认的任务不会因一次 rollout 读取失败被移除；迟到事件仍须通过状态机的时间和终态去重检查。

这些规则同时用于 bootstrap 和实时读取。其他 subagent（包括 Memories）归类为 `auxiliary`，按辅助任务规则关联。历史聚合仍消费全部原始事件，来源记忆不持久化或上传。

### 新 prompt 与终态确认

新 prompt 到来时，同一 session 的旧 turn 移到 `pendingTerminalTasks`，等待 rollout 确认结果：

- 从 active snapshot 立即移除
- 保留原任务元数据和开始时间
- 前 5 秒快速查询 rollout terminal，随后每 30 秒补查
- terminal 到达时准确分类 completed 或 aborted
- 24 小时后仍无终态则清理，不生成完成、终止、通知或流光提示

`SessionEnd` 使用同一个终态确认窗口，只是按 session 一次移动所有不晚于该事件的任务。

### 迟到事件如何被拒绝

Hook 顺序按 Agent／轮次隔离，任务整体进展另行汇总：

| 字段 | 来源与用途 |
| --- | --- |
| execution 的 `lastHookEventAt` | 同一 Agent／轮次已接受的最新 Hook 时间，用于拒绝该执行的迟到状态变化 |
| `lastMainHookEventAt` | 主 Agent 的最新 Hook 时间，用于顶层 prompt、中断及会话结束判断 |
| execution 的 `lastExecutionProgressAt` | 同一执行的 Hook 恢复信号与 rollout 执行进展时间，用于审批恢复和迟到审批过滤 |
| `lastProgressAt` | Hook 与 rollout 的最新进展时间，用于异常会话保护 |
| `lastActivityAt` | 由 `lastProgressAt` 派生，用于展示排序、保留期和终态时间校正 |

rollout 进展不会推进 Hook 时钟，其他 Agent 的较晚事件也不阻止本 Agent 的合法事件。审批请求还须不早于同一执行已知的执行进展，并晚于上次审批请求；任务的 `lastProgressAt` 和 `lastActivityAt` 保持单调递增。

完成和终止共用内存中的 `recentlyEndedTaskAt` 记录结束时间。展示记录仍分别保存在完成和终止列表，保留 10 分钟；去重记忆保留 24 小时，不随展示记录一起删除。来源过滤移除记录时，从剩余终态记忆重新计算对应 session 别名的最新时间。

迟到事件按以下规则处理：

- 工具、压缩、子 Agent 和审批 Hook 按执行归属检查时间；已确认终态的执行不接受新的状态变化
- 精确 turn 在终态记忆保留期间不允许重新创建；session 和匿名键只允许时间更新的新 prompt 复用
- `Stop` 命中多个候选时不猜测
- 已进入 terminal 去重记忆的 key 会清除异常顺序留下的恢复任务

这种比较依赖事件自身时间，而不是 batch 到达顺序，因为跨进程文件写入和 rollout poll 都可能让旧事件晚到。

### 匿名任务

`WorkflowHookEvent.sessionId` 缺失时，task key 使用匿名 project key。`isAnonymous` 会保留到 `CodexActivityTaskSnapshot`, `CodexActivityCompletion` 和 `CodexActivityTermination`

匿名任务仍进入活动快照和最近终态记录。活动卡片与任务中心统一显示橙色 `person.crop.circle.dashed` 图标，help 为 `匿名任务不参与防睡眠`。活动卡片的 `+N` 只表示其他活跃任务总数。

匿名运行任务不展示精确运行时长，匿名完成和终止记录也不包含精确耗时。

匿名任务不向通知消费者发布等待批准或完成 transition、不触发任务触觉反馈、不进入 KeepAlive 的运行中或等待任务集合、不参与异常会话保护。`activityProtectionIdentifier` 对匿名 key 返回 nil，保护状态文件不会保存匿名任务记录。

## 状态机

内部活动任务主要有以下状态：

| 状态 | 含义 |
| --- | --- |
| `running` | Codex 正在处理当前 turn |
| `waitingApproval` | 任务内至少一个主 Agent 或子 Agent 的执行正在等待用户批准 |
| `suppressed` | 任务被异常会话保护隐藏，等待新进展恢复 |

`PermissionRequest` 只有在 reviewer 是用户时才进入 `waitingApproval`。自动审批或策略审批不会被视为用户等待。

任务结束按以下信号处理：

- `Stop` 将任务标记为正在收尾，继续保留在活动列表
- `Interrupt` 将匹配的 turn 记录为终止
- rollout terminal 确认完成或终止
- 新 turn 或 `SessionEnd` 将旧任务移出活动列表并后台补查；没有明确终态就保持未确认，到期只清理

### 事件到状态的主要转换

| 当前状态 | 输入 | 新状态 | 额外动作 |
| --- | --- | --- | --- |
| 不存在 | `UserPromptSubmit` | running | 保存可信 startedAt |
| 不存在 | 顶层 tool 或 compact | running | 恢复任务，startedAt 暂缺 |
| running | tool, compact, subagent progress | running | 更新 last progress 和 generation |
| running | `PermissionRequest` + reviewer user | waitingApproval | 发布 live waiting transition |
| waitingApproval | 审批所属 Agent／轮次的有效 Hook 或 rollout 执行进展 | waitingApproval 或 running | 清除该执行的审批；仍有其他等待时保持等待 |
| waitingApproval | 其他 Agent 的进展 | waitingApproval | 更新进展，保留等待及其工具展示 |
| running 或 waiting | 顶层 `Stop` | running 或 waitingApproval | 清除主执行等待；仍有子 Agent 等待时继续显示等待，否则显示正在收尾 |
| active | 新 prompt 或 `SessionEnd` | pending terminal | 从快照移除并开始后台终态查询 |
| active、suppressed 或 pending terminal | `Interrupt` | terminated | 移除匹配任务、记录终止并清理保护状态和通知 |
| running | 满足保护条件且静默达到阈值 | suppressed | 隐藏并退出防睡眠贡献 |
| suppressed | 有效的工具、压缩、子任务或 `Stop` Hook，或健康对账读到新进展 | running | 清除持久化保护与旧通知 |
| active、suppressed 或 pending terminal | 完整读取的匹配 rollout terminal | completed 或 terminated | 记录明确终态并清理任务，降级期间静默处理 |

### 等待批准的两阶段确认

任务按 Agent／轮次保存执行记录，主 Agent 使用无 `agentId` 的明确主来源身份，子 Agent 使用自身线程 ID。每个执行独立保存 `approvalReviewer`，来源为 Hook 或 rollout 的 `payload.approvals_reviewer`，取值为 `user`、`auto_review` 或 `guardian_subagent`

每个执行只有一份可选审批记录：`pending` 表示路由待确认，`waiting` 表示等待用户。收到 `PermissionRequest` 后，已知 reviewer 为 `user` 时立即确认等待，未知时保留候选；确认为自动审批时清除候选。请求时间、工具名和顺序随审批记录保存，重复请求不覆盖正在等待的展示信息。

只有身份可靠且属于同一 Agent／轮次的进展才能清除该执行的审批。有效的工具、压缩、子 Agent 生命周期或顶层 `Stop` Hook 按现有恢复规则处理；rollout 执行进展须严格晚于请求时间。已清除的候选不会因后续 reviewer 回填重新进入等待，子线程的明确 rollout 终态也会清除对应执行的等待。

任务中仍有任意用户等待时保持 `waitingApproval`，展示请求时间最早的等待；同时间按记录顺序选择。等待持续期间切换展示对象不重置任务的等待起点。其他 Agent 的进展和身份不完整的进展不解除已知等待。同一 Agent／轮次内的并行调用仍共享审批记录，恢复依据是进展推断。

### Effort 合并

同一 turn 的多个上下文事件可能报告不同 reasoning effort。Task 不让最后一条静默覆盖前一条，而是在观察到冲突后标记为 `mixed`

### Subagent 计数可靠性

子 Agent Hook 的 `agent_id` 和 `turn_id` 标识子线程及其轮次。monitor 读取相关子线程 rollout，使用 `session_meta.id` 校验线程，使用 `parent_thread_id`（缺失时取 `source.subagent.thread_spawn.parent_thread_id`）校验父线程信息，并通过上下文或开始事件中的 `root_turn_id` 关联根任务轮次。`root_turn_id` 指向根轮次，不是直接父 Agent 的轮次。

根会话 ID 优先取 `session_meta.session_id`，缺失时使用已有关联或该子轮次 Hook 中唯一的根会话 ID。关联前暂存身份完整的子事件，确认后按原始来源重放；字段不足或关联冲突时不回退到当前唯一活动任务。子 Agent 活动只更新匹配的活动根任务，不创建独立卡片。

活跃子 Agent 数按已关联的 `SubagentStart` 和 `SubagentStop` 维护，与审批记录分开。计数可靠性由是否已知 prompt 起点初始化；首次观察某个 Agent 就收到 stop 时设为 `false`，UI 隐藏数量。每个 Agent 按自己的事件时间更新运行状态，已确认结束的执行不会被迟到的 start 计为运行。

## 快照优先级

活动卡片的 `primaryActivity` 按以下优先级选择内容：

```text
等待批准 > 运行中 > 最新的完成或终止 > 空闲
```

`latestTerminalEvent` 按结束时间选择最新的完成或终止，时间相同优先终止。活动卡片、菜单栏和空闲时的任务流光共用该结果。菜单栏在 `primaryActivity` 的基础上限制终态显示到结束时间后 10 秒。任务中心的终态记录保留 10 分钟，terminal 去重记忆保留 24 小时。

快照由以下模块消费：

- 菜单栏人物图标
- 主面板任务卡片
- 活动中心
- 任务流光
- 通知系统
- 防睡眠控制器

### 快照发布

monitor 每秒检查 rollout，并在清理 deadline 到达时刷新。

新快照先与当前值比较，只有结构变化才发布。运行时长文案由 View 使用当前时间格式化，不要求每秒修改任务对象。

### 展示更新

`presentationPublisher` 发布当前快照和本轮仍有效的 `terminalEvents`，供任务流光使用。展示事件包含匿名任务；通知使用独立的 `transitionPublisher`

完成转场和终态短提示要求结束时间距当前不超过 10 秒，并且不早于各自的恢复界限。Hook 直接确认或 rollout 补齐 reviewer 后确认的等待转场，均要求任务进入等待的时间距当前不超过 10 秒且不早于 `sessionTransitionNotBefore`。

历史重读、睡眠恢复和数据源健康状态变化时清空待发布事件，并更新 `terminalPresentationNotBefore`。bootstrap、恢复对账和数据源不健康期间暂停发布。

### 稳定排序

同一 batch 中多个任务可能具有相同时间戳，仅按时间比较无法确定它们之间的顺序。

所有列表先按最近时间降序，时间相同再按 display UUID 字符串排序。稳定顺序让 SwiftUI diff 不会因为等价任务随机交换位置而产生跳动。

### 清理采用最近 deadline

monitor 管理待确认任务、活动任务、历史记录、终态去重和保护记录的过期时间。菜单栏终态提示和任务流光分别由 `StatusItemController`、`TaskGlowController` 管理到期时间。提示到期不重新发布活动快照。

清理任务只等待最近的未来 deadline，到点处理后安排下一次。

## 系统睡眠与唤醒

系统即将睡眠时暂停异常会话保护判断。唤醒后的完整恢复顺序为：

1. 进入恢复状态并继续暂停保护
2. 等待 `HookEventTailReader.drainNow()` 成功
3. 重置 rollout 生命周期解析的 fallback
4. 使用新 Hook 结果和 rollout 结果统一对账
5. 恢复异常会话保护判断

Hook 屏障返回 `sourceUnavailable` 时，仅为已知任务对账明确终态，保持静默并继续暂停保护，后续轮询重试完整恢复。reader 被更换或任务取消时丢弃该轮结果。

### 系统睡眠期间暂停判定

系统睡眠期间不进行异常静默判定。恢复后，monitor 根据新读取的 Hook 与 rollout 进展静默对账，再恢复正常判定。

检查任务使用 `SuspendingClock` 等待，但静默时长仍按 `Date` 与 `lastProgressAt` 的差值计算，不扣除系统睡眠经过的时间。will-sleep 进入 recovery，did-wake 通过新的数据读取屏障后重新判定。

### 唤醒恢复的关联与代次

完整恢复先消费 Hook，以建立睡眠期间产生的任务身份，再合并 rollout 的生命周期和进展，最后恢复保护判断。降级终态对账仅处理已有任务。

bootstrap 等待 rollout 期间如果恢复代次改变，会丢弃旧生命周期结果；结束 bootstrap 后重新进入读取屏障，不能直接结束较新的恢复。

`tailReaderGeneration` 防止唤醒 Task 返回时 reader 已因 Hook 设置变化被替换。`activityProtectionRecoveryGeneration` 防止两次睡眠或设置变化交错后，较早恢复流程提前解除暂停。

## 异常会话保护

异常会话保护只在防睡眠主开关开启时工作，只处理非匿名 `running` 任务。

等待批准任务不参与静默阈值判断。原因是等待批准本身就是一个合法的无进展状态。

可选阈值为：

- 30 分钟
- 1 小时（默认值）
- 2 小时
- 4 小时

任务达到阈值后：

1. 先更新内存保护记录并加入串行持久化队列
2. 同时启动通知提交和 3 秒 grace
3. 通知提交完成或 grace 到期后再次校验候选
4. 候选仍有效时从活动快照隐藏任务
5. 如果期间或之后出现新进展，清除保护并恢复展示

隐藏任务不依赖通知成功。3 秒只是等待解释性通知提交的最大时间，到期后仍会释放防睡眠。

保护判断在以下阶段暂停：

- Hook bootstrap
- 系统睡眠
- 唤醒恢复
- Hook 数据源不可用
- reader 正在更换
- 当前任务的 rollout 未读全且不满足残缺末行兜底条件、读取失败、上下文缺失或读取结果过期

### progress generation 的作用

只比较时间戳不足以保护异步尝试。两条进展可能具有相同秒级时间，设置阈值也可能在通知提交期间变化。

每次有效进展都会递增 `progressGeneration`。保护候选保存：

- task display ID
- last progress timestamp
- progress generation
- 当时的阈值

通知返回或 3 秒 grace 到期时，四项都必须仍匹配才允许 suppress。任意新进展或阈值变化都会让旧尝试失效。

使用残缺末行兜底的候选还要复核末行观察的新鲜度和静默期限。末行继续增长或读取失败时取消尚未完成的隐藏尝试。

### 保护记录的保存顺序

候选开始时同步更新内存记录，再由 Task 按顺序调用 `ActivityProtectionStateStore.apply`。磁盘写入失败会记录日志，不阻止任务隐藏。

已保存的记录用于下次 bootstrap 恢复保护状态。隐藏动作不等待磁盘提交，因此跨重启恢复取决于记录是否成功写入。

### 阈值改变如何对账

阈值变短时，已经超过新阈值的 running 任务会立即重新判定。

阈值变长时，未超过新阈值的 suppressed 任务会静默恢复，并清除保护记录和通知；仍超过阈值的任务继续隐藏。

恢复与隐藏共用保护计时起点：取任务最后进展与已保留的残缺末行最后增长观察时间中的较晚者。调大阈值后的恢复不要求读取结果仍在 5 秒有效期内；再次隐藏仍须取得新鲜读取依据并达到新期限。

关闭防睡眠主开关会停用异常保护，并恢复当前进程内所有 suppressed 任务。

## 保护状态持久化

[`ActivityProtectionStateStore.swift`](../../CodexBar/Services/Workflow/ActivityProtectionStateStore.swift) 保存到：

```text
~/Library/Application Support/CodexBar/ActivityProtection/state.json
```

- 当前 schema 为 `1`
- 只保存哈希任务身份和时间戳
- 文件权限为 `0600`
- Debug 与 Release 通过 `flock` 共用文件
- 记录最长保留到最后进展后的 24 小时

任务身份使用 SHA-256 摘要，不把 session ID 或 turn ID 原文写入该状态文件。匿名任务没有保护标识，不写入该文件。

### 哈希身份的构造

turn 和 session key 先使用带类型前缀与 NUL 分隔的 canonical 字符串，再加固定 domain separator `CodexBar.ActivityProtection.v1` 执行 SHA-256。

类型和分隔符避免不同字段拼接后产生边界歧义。domain separator 避免同一原始 ID 在其他用途中的 hash 被直接关联。

### 跨进程状态合并

两个 App bundle ID 可以同时运行，但都观察同一份 Codex Hook 数据。如果各自保存独立保护状态，一个版本隐藏的异常任务可能被另一个版本重新用于防睡眠。

状态 store 使用 actor 串行单进程访问，再用 `flock` 保护跨进程 read-modify-write。removal 还可以附带 `matchingMarkedAt`，防止旧进程的迟到删除误删另一进程刚写入的新记录。

写入按 task identifier 稳定排序并原子替换，文件权限最终校正为 `0600`

## 代际和旧结果隔离

Monitor 为 reader 和异步恢复任务维护 generation：

- reader 更换后丢弃旧 reader 的迟到结果
- bootstrap 未完成时不发布转场副作用
- 取消的 drain 不满足恢复屏障
- 数据源显式不健康时不沿用最后健康快照做静默判断

### monitor 中的主要 generation

| generation | 保护的异步路径 |
| --- | --- |
| `tailReaderGeneration` | reader batch, rollout poll 和 prompt backfill |
| `bootstrapCompletionGeneration` | bootstrap 的异步 lifecycle 补齐，以及跨 bootstrap 的 rollout 对账结果 |
| `activityProtectionRecoveryGeneration` | 睡眠、唤醒恢复流程，以及跨恢复批次的 rollout 对账结果 |
| task `progressGeneration` | 通知宽限期间的保护候选 |

任务进展只使对应的保护尝试失效；reader、bootstrap 和恢复代次分别隔离各自的异步结果。

## 建议验证的故障场景

- Stop handler 要求继续后完成或中断，确认没有提前完成提醒
- Stop handler 执行期间中断，只产生一条终止记录和红色提示
- rollout 不可读超过 5 秒仍不判定完成，恢复后只确认一次
- Stop 后继续请求用户批准，等待状态和中断清理正常
- 中断运行、等待批准和隐藏任务，确认状态、耗时、保护清理且无完成通知
- Hook 与 rollout 终止以两种顺序到达，确认单条记录和单次提示
- 新 turn 开始后收到旧 turn 中断，新任务保持活跃
- 重复 Interrupt 和迟到工具或 prompt 事件不能恢复已结束的 turn
- App 在任务已运行时启动，bootstrap 展示任务但不补发通知
- bootstrap 文件持续追加时能重试并最终获得稳定边界
- 连续 3 次不稳定后进入 degraded，不启动异常静默判断
- 新 prompt 替换旧 turn，分别验证终态在前 5 秒及之后到达时的补分类
- 同 session 多个 terminal 候选时不猜测 `Stop` 归属
- 主 Agent 与多个子 Agent 同时等待，逐个恢复时只清除自己的等待，最后一项清除后才切回运行
- 普通 rollout 活动保持等待；同一执行的较新执行进展清除等待，同时间进展保持等待，迟到审批或 reviewer 回填不恢复已清除的等待
- 子线程 `root_turn_id` 指向旧轮次时不更新新任务；关联缺失或冲突时不猜测父任务
- 新 turn 边界后无 `turn_id` 的记录只推进新任务；迟到旧终态、分批读取和文件替换不串用上下文
- reviewer 缺失后由 rollout 确认为 user 才进入等待
- auto review 始终不发布等待 transition
- 子任务计数可靠性为 `false` 时 UI 隐藏数量
- reader 进行中调用 `drainNow()` 必须再执行一轮新读取
- 唤醒 drain 失败时保护继续暂停；Hook 坏行期间明确 rollout 终态静默结束已知任务，普通进展不恢复隐藏任务
- 静默候选在 3 秒窗口内出现进展后不隐藏，迟到通知被撤回
- 阈值调长后未超新阈值的 suppressed 任务恢复
- Debug 与 Release 并发更新保护记录时新记录不被旧 removal 删除
- 匿名任务始终不进入 transition、KeepAlive 和保护状态文件

## 关键源码

- [`CodexActivityMonitor.swift`](../../CodexBar/Services/Workflow/CodexActivityMonitor.swift)
- [`CodexActivityTask.swift`](../../CodexBar/Services/Workflow/CodexActivityTask.swift)
- [`CodexActivitySubagentTracking.swift`](../../CodexBar/Services/Workflow/CodexActivitySubagentTracking.swift)
- [`CodexActivityTerminalResolution.swift`](../../CodexBar/Services/Workflow/CodexActivityTerminalResolution.swift)
- [`HookEventTailReader.swift`](../../CodexBar/Services/Workflow/HookEventTailReader.swift)
- [`CodexSessionLifecycleReader.swift`](../../CodexBar/Services/Workflow/CodexSessionLifecycleReader.swift)
- [`CodexActivityProtection.swift`](../../CodexBar/Services/Workflow/CodexActivityProtection.swift)
- [`ActivityProtectionStateStore.swift`](../../CodexBar/Services/Workflow/ActivityProtectionStateStore.swift)

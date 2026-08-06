# 实时任务监控

## 设计出发点

实时任务不是 Hook 事件的直接映射。

同一个 turn 可能出现事件缺失、迟到、重复、只有 session ID、新 prompt 覆盖旧 turn、`Stop` 与 rollout terminal 先后到达，或 App 在任务已经运行一段时间后才启动。

`CodexActivityMonitor` 的工作是把这些不完整观察合并成一个保守的任务状态机，并同时提供两种不同输出：

- snapshot 表示现在可以展示什么
- transition 表示刚刚发生了什么，可以驱动一次性副作用

如果消费者各自从 Hook 列表推断任务，菜单栏、通知和防睡眠会在边界场景下得出不同结论。

## 目标

实时任务链路需要回答 4 个问题：

- 当前是否有任务正在运行
- 当前是否在等待用户批准
- 最近任务是完成还是中断
- 哪些运行任务已经长时间没有进展

Hook 事件提供低延迟信号，rollout 文件提供权威生命周期补充。[`CodexActivityMonitor.swift`](../../CodexBar/Services/Workflow/CodexActivityMonitor.swift) 合并两者并发布唯一任务快照：

```text
Hook JSONL -> HookEventTailReader -----+
                                      +-> CodexActivityMonitor -> ActivitySnapshot
rollout JSONL -> SessionLifecycleReader+
```

### 两种来源的分工

| 信息 | 优先来源 | 补充来源 |
| --- | --- | --- |
| prompt, tool, compact, subagent 实时进展 | Hook | rollout progress |
| 用户审批候选 | `PermissionRequest` | rollout reviewer 确认 |
| turn 起点 | `UserPromptSubmit` | rollout startedAt 或历史回查 |
| 完成候选 | `Stop` | rollout terminal |
| 完成与中断分类 | rollout terminal | grace 到期 fallback |
| effort | Hook recorder 回查 | rollout lifecycle backfill |

Hook 优先解决低延迟，rollout 优先解决语义准确性。两者不是简单按时间戳覆盖，每个字段都有自己的可信来源。

### snapshot 和 transition 为什么分开

snapshot 可以在 View 重建、新消费者订阅或设置变化时反复读取。transition 只允许 live 数据产生一次。

例如 App 启动时 bootstrap 恢复出一个已经等待批准的任务：

- snapshot 应显示它正在等待
- transition 不应发布等待事件
- 通知服务因此不会补发一条历史通知

任务完成也一样。通知服务消费 `.completed` transition，不扫描 `recentCompletions`，避免 App 重启或 UI 刷新重复提醒。

## HookEventTailReader

[`HookEventTailReader.swift`](../../CodexBar/Services/Workflow/HookEventTailReader.swift) 是 actor，默认每 2 秒检查 Hook 事件文件。

### Bootstrap

首次启动读取最近 24 小时文件以建立任务基线：

- 每块最多读取 512 KB
- 最多尝试 3 次获得稳定文件边界
- 使用 inode 和 size 判断读取期间是否发生替换或追加
- bootstrap 结果不会触发历史完成或等待通知

如果无法得到稳定边界，reader 会跳到当前文件末尾并发布显式不健康状态。这样不会把不完整历史误解释为真实任务变化。

### bootstrap 是一个逻辑事务

24 小时窗口可能跨两个自然日文件，单个文件又会分成多个 512 KB batch 发送。

monitor 在 `.bootstrapStart` 时先清空上一次恢复态并暂停副作用，接收所有 `.bootstrapEvents`，最后在 `.bootstrapEnd` 才统一：

- 用 rollout 补齐生命周期
- 应用持久化异常保护记录
- 按当前阈值静默对账
- 定向回查缺失 prompt 起点
- 发布完整 snapshot

中间 batch 不应让 UI 或通知看到半恢复状态。

### 稳定边界为什么要重试 3 次

reader 在每次尝试开始时固定所有日期文件的 inode 和 size，读取到这些上界后再次验证：

- 历史日期必须 inode 和 size 都不变
- 当前日期允许在固定上界之后继续 append
- 当前自然日不能在读取期间跨过零点

任何条件不成立都从新的基线重试。连续 3 次失败后跳到当前文件末尾，是为了避免 App 永远卡在 bootstrap。代价通过 degraded health 明确传给异常保护，而不是假装成功。

### 为什么只推进完整行 offset

Hook recorder 可能正在写最后一行。reader 只把最后一个 newline 之前的字节计入 `completeOffset`

半行不会丢弃，也不会被当作损坏事件。下一轮从旧 offset 重新读取，等行完整后再提交。

### 跨日与文件替换

正常跨日时先排空旧日期文件，再切换到新日期文件。inode 改变或文件缩小时重新 bootstrap，不沿用旧游标。

当 `UserPromptSubmit` 早于当前增量窗口时，reader 可以向前回查最多 8 MB，为现存任务补齐 prompt 起点。

### drainNow 读取屏障

`drainNow()` 不是普通的立即刷新提示。每个调用方必须等待一轮在本次请求之后开始的读取：

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
- 初始尾部窗口为 512 KB
- effort 等 turn context 字段最多回查 8 MB
- 只解析生命周期、turn, progress, effort 和 reviewer
- 不读取或保存对话内容用于产品展示

Hook 的 `Stop` 只是完成候选。rollout 中的 terminal 状态用于区分真正完成、用户取消和异常中断。

### session 文件如何定位

reader 先检查最可能的少量目录：

1. 任务开始日期对应的 `sessions/YYYY/MM/DD`
2. 当前日期目录
3. `archived_sessions`

resume 可能继续很早以前创建的 session。快速路径找不到时，每个活跃 session 生命周期最多执行一次递归兜底，避免每秒 poll 都扫描整个 sessions 树。

文件被移到 archive 后，已缓存 URL 不存在会清除 cursor 并允许重新完整定位。

### rollout cursor 为什么从尾部 512 KB 开始

实时任务只需要活跃 turn 附近的 lifecycle，全量读取一个长期 session 会增加常驻 I/O。

初始 cursor 从最后 512 KB 开始并丢弃第一条可能不完整的行。如果 effort 仍缺失，对具体 turn 再定向回查最多 8 MB。

effort backfill 只针对至少运行 2 秒，尚未 terminal 且仍缺 effort 的任务，同一 turn 重试间隔 10 秒。这避免刚创建任务时立刻做大范围回查。

### 为什么只解析结构事件

共享的 `CodexRolloutLineEnvelope` 只提取 turn context, lifecycle 和 progress 所需字段。prompt, response 和 tool 内容不会进入活动模型。

这既收紧隐私边界，也降低大 rollout 的解码成本。新增实时字段时应先扩展这份最小 envelope，不应把完整 transcript 解码成通用 JSON 树。

## 任务身份

任务 key 按可用信息选择最精确身份：

1. `session ID + turn ID`
2. `session ID`
3. 匿名 project key

新的 prompt 会替代同一 session 的旧 turn。旧 turn 进入最长 5 秒 terminal grace，给迟到的结束事件留出对账时间。

subagent 事件更新父任务的 subagent 活动，不创建独立顶层任务卡片。

### 身份选择为什么按精度降级

`session ID + turn ID` 能精确区分同一 session 中顺序执行的 turn，是首选身份。

某些事件只有 session ID。此时 session key 允许事件仍然参与状态，但终态匹配必须更保守。如果同一 session 同时存在多个候选，monitor 返回 ambiguous 而不是猜一个任务结束。

完全没有 session ID 时只能使用 project key。这个 key 可能把同项目并发匿名任务合并，所以匿名任务只承担可撤销的 UI 展示，不驱动通知、防睡眠或持久化保护。

### 为什么新 prompt 不直接把旧 turn 判为中断

同一 session 的 turn 顺序执行。新 prompt 到来时旧 turn 必须立即离开活跃列表，否则 UI 会短暂显示两个顶层任务。

但新 prompt 可能早于旧 turn 的 rollout terminal 到达。直接记录中断会误判一个正常完成的任务。

因此旧 turn 被移到 `pendingTerminalTasks`

- 从 active snapshot 立即移除
- 保留原任务元数据和开始时间
- 等待最多 5 秒 rollout terminal
- terminal 到达时准确分类 completed 或 aborted
- grace 到期仍无终态时按保守 fallback 收口

`SessionEnd` 使用同一个终态确认窗口，只是按 session 一次移动所有不晚于该事件的任务。

### 迟到事件如何被拒绝

任务保存 `lastActivityAt`，terminal 记忆保存完成或中断时间：

- 早于当前任务最后活动的事件不覆盖新状态
- 不晚于已记录 terminal 的新 prompt 不会复活旧任务
- `Stop` 命中多个候选时不猜测
- 已进入 terminal 去重记忆的 key 会清除异常顺序留下的恢复任务

这种比较依赖事件自身时间，而不是 batch 到达顺序，因为跨进程文件写入和 rollout poll 都可能让旧事件晚到。

### 匿名任务

`WorkflowHookEvent.sessionId` 缺失时，task key 使用匿名 project key。`isAnonymous` 会保留到 `CodexActivityTaskSnapshot`, `CodexActivityCompletion` 和 `CodexActivityTermination`

匿名任务仍进入活动快照和最近终态记录。活动卡片与任务中心统一显示橙色 `person.crop.circle.dashed` 图标，help 为 `匿名任务不参与防睡眠`。活动卡片的 `+N` 只表示其他活跃任务总数。

匿名运行任务不展示精确运行时长，匿名完成和终止记录也不包含精确耗时。

匿名任务不向通知消费者发布等待批准或完成 transition、不触发任务触觉反馈、不进入 KeepAlive 的运行中或等待任务集合、不参与异常会话保护。`activityProtectionIdentifier` 对匿名 key 返回 nil，保护状态文件不会保存匿名任务记录。

### 为什么匿名任务仍保留在 UI

缺少 session ID 不等于任务不存在。完全丢弃会让用户看到 Codex 正在工作，CodexBar 却显示空闲。

保留 UI 展示同时禁止高影响副作用，是对不确定身份的分层处理：

- 可见性错误可以由后续事件自动修正
- 错误通知会打扰用户
- 错误防睡眠可能持续数小时
- 持久化匿名 project key 可能压制未来另一个真实任务

因此匿名任务使用橙色虚线人物图标明确表达能力受限，而不是伪装成普通精确任务。

## 状态机

内部活动任务主要有以下状态：

| 状态 | 含义 |
| --- | --- |
| `running` | Codex 正在处理当前 turn |
| `waitingApproval` | 当前 turn 明确等待用户批准 |
| `suppressed` | 任务被异常会话保护隐藏，等待新进展恢复 |

`PermissionRequest` 只有在 reviewer 是用户时才进入 `waitingApproval`。自动审批或策略审批不会被视为用户等待。

终止信号按可靠性对账：

- `SessionEnd` 结束 session
- rollout terminal 区分完成和中断
- `Stop` 在缺少更强信号时形成完成候选
- 新 prompt 可以结束旧 turn 的展示生命周期

### 事件到状态的主要转换

| 当前状态 | 输入 | 新状态 | 额外动作 |
| --- | --- | --- | --- |
| 不存在 | `UserPromptSubmit` | running | 保存可信 startedAt |
| 不存在 | 顶层 tool 或 compact | running | 恢复任务，startedAt 暂缺 |
| running | tool, compact, subagent progress | running | 更新 last progress 和 generation |
| running | `PermissionRequest` + reviewer user | waitingApproval | 发布 live waiting transition |
| waitingApproval | 新进展 | running | 清除 pending approval 和保护记录 |
| running 或 waiting | `Stop` | terminal candidate | 保存完成或等待 rollout 对账 |
| active | 新 prompt 或 `SessionEnd` | pending terminal | 从快照移除并开启 5 秒 grace |
| running | 静默超过阈值 | suppressed | 隐藏并退出防睡眠贡献 |
| suppressed | 新进展 | running | 清除持久化保护与旧通知 |

### waiting approval 为什么采用两阶段确认

`PermissionRequest` 说明进入审批流程，但 reviewer 可能是 user, policy 或 auto review。

Hook event 到达时如果已经带有 reviewer，task 可以立即确认。reviewer 缺失时先保存 `pendingApprovalRequestedAt`，rollout poll 补齐后再决定是否进入 `waitingApproval`

只有 reviewer 明确为 user 才发布 waiting transition。不确定时维持 running 比误报用户正在被等待更符合事实。

### effort 为什么可能变成 `mixed`

同一 turn 的多个上下文事件可能报告不同 reasoning effort。Task 不让最后一条静默覆盖前一条，而是在观察到冲突后标记为 `mixed`

这向 UI 表达任务生命周期内确实出现过多个值，避免展示一个看似精确但只代表最后观察的 effort。

### subagent 数为什么允许 unknown

subagent 的 turn ID 属于 subagent 自己，父任务只能通过共享 session 关联。

只有同 session 恰好有一个 active 父任务、没有 pending terminal 歧义，并且 start/stop 带稳定 agent ID 时，active subagent count 才可靠。

缺少 ID、先看到 stop 或同 session 有多个候选时，monitor 将可靠性降为 false，UI 不展示伪精确数字。

## 快照优先级

多个任务和短时状态同时存在时，对外快照按以下优先级表达：

```text
等待批准 > 运行中 > 最近完成 > 最近中断 > 空闲
```

完成状态在菜单栏保留 30 秒绿色提示。活动中心保留最近 10 分钟任务，terminal 去重记忆保留 24 小时。

快照由以下模块消费：

- 菜单栏状态点
- 主面板任务卡片
- 活动中心
- 通知系统
- 防睡眠控制器

### 为什么最近完成和最近中断有不同展示权重

完成会在菜单栏保留 30 秒绿色高亮，这是短时正反馈。中断只进入最近记录、不发布完成 transition，也不显示绿色状态。

任务中心保留 terminal 10 分钟，但用于防止迟到事件重复完成的 key 会保留 24 小时。展示期限和去重期限解决不同问题，不能为了“统一缓存”合并。

### 为什么只在快照变化时发布

monitor 每秒 poll rollout，还会按多个 deadline 自行刷新。如果每轮都给 `@Published` 赋相同值，SwiftUI 和所有 Combine 消费者会重复计算。

新快照先与当前值比较，只有结构变化才发布。运行时长文案由 View 使用当前时间格式化，不要求每秒修改任务对象。

### 排序为什么有稳定兜底

同一 batch 中多个任务可能具有相同时间戳，Swift sort 又不是稳定排序。

所有列表先按最近时间降序，时间相同再按 display UUID 字符串排序。稳定顺序让 SwiftUI diff 不会因为等价任务随机交换位置而产生跳动。

### 清理采用最近 deadline

monitor 同时管理完成高亮、terminal grace、活动保留、历史保留、terminal 去重和保护记录过期。

它不使用固定高频 timer 扫描所有状态，而是收集所有未来 deadline，只为最近一项安排 Task。到点刷新后再计算下一项。

这种实现减少常驻菜单栏 App 的无意义唤醒，也保证每种保留期都能在没有新 Hook 事件时准时生效。

## 系统睡眠与唤醒

系统即将睡眠时暂停异常会话保护判断。唤醒后执行严格恢复顺序：

1. 进入恢复状态并继续暂停保护
2. 等待 `HookEventTailReader.drainNow()` 成功
3. 重置 rollout 生命周期解析的 fallback
4. 使用新 Hook 结果和 rollout 结果统一对账
5. 恢复异常会话保护判断

如果新一轮读取失败、reader 被更换或数据源不可用，不得使用睡眠前快照继续判断任务静默。

### 为什么系统睡眠期间必须暂停静默计时

系统睡眠时 Hook 与 rollout 都不会正常产生进展。如果只比较墙上时间，一次两小时睡眠会让所有运行任务在唤醒瞬间被判为异常静默。

保护计时使用 `SuspendingClock` 安排下一次检查，但系统时间变化和数据源恢复仍需要显式重算。will-sleep 先进入 recovery，did-wake 再通过新的数据读取屏障恢复判定。

### 唤醒顺序为何不能交换

rollout 对账必须发生在 Hook drain 成功之后。

如果先读 rollout，此时 monitor 中可能还没有睡眠期间刚追加的任务 key，lifecycle 结果无法关联。如果先恢复保护判定，则会基于睡前 last progress 误隐藏任务。

`readerGeneration` 防止唤醒 Task 返回时 reader 已因 Hook 设置变化被替换。`recoveryGeneration` 防止两次睡眠或设置变化交错后，较早恢复流程提前解除暂停。

## 异常会话保护

异常会话保护只在防睡眠主开关开启时工作，只处理非匿名 `running` 任务。

等待批准任务不参与静默阈值判断。原因是等待批准本身就是一个合法的无进展状态。

可选阈值为：

- 30 分钟
- 1 小时（默认值）
- 2 小时
- 4 小时

任务达到阈值后：

1. 先持久化保护记录
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

### 保护针对的故障模型

Hook 或 Codex 异常退出后，可能缺少 `Stop`, `SessionEnd` 和 rollout terminal。任务会一直停在 running，进而让防睡眠永久生效。

异常会话保护不是判断 Codex 是否“真的卡住”，它只处理一个可观察事实：非匿名 running 任务在可信数据源下超过阈值没有任何 Hook 或 rollout 进展。

等待批准被排除，因为等待用户本来就是合法静默。匿名任务被排除，因为 project key 不足以证明保护记录属于哪一个具体任务。

### progress generation 的作用

只比较时间戳不足以保护异步尝试。两条进展可能具有相同秒级时间，设置阈值也可能在通知提交期间变化。

每次有效进展都会递增 `progressGeneration`。保护候选保存：

- task display ID
- last progress timestamp
- progress generation
- 当时的阈值

通知返回或 3 秒 grace 到期时，四项都必须仍匹配才允许 suppress。任意新进展或阈值变化都会让旧尝试失效。

### 为什么先持久化再隐藏

一旦任务从快照隐藏，App 可能随即退出或系统休眠。如果保护记录还没有进入持久化队列，重启 bootstrap 会再次展示并重新支撑防睡眠。

因此候选开始时先写入记录、再等待通知提交、最后隐藏。通知权限或系统服务失败不影响 suppress，因为释放错误防睡眠才是保护的核心目标。

### 3 秒通知宽限的含义

保护通知是有价值的解释，但不能无限阻塞释放防睡眠：

- 通知先成功提交时立即完成 suppress
- 3 秒内仍未完成时直接 suppress
- 通知稍后成功返回但 attempt 已失效时立即撤回
- grace 内出现新进展时取消 attempt 和持久化记录

这个窗口只约束通知副作用，不改变静默阈值本身。

### 阈值改变如何对账

阈值变短时，已经超过新阈值的 running 任务会立即重新判定。

阈值变长时，尚未超过新阈值的 suppressed 任务会静默恢复，清除对应保护记录和通知。已经仍超过新阈值的任务继续 suppressed，不制造重复通知。

关闭防睡眠主开关会关闭异常保护并恢复全部 suppressed 任务，因为保护存在的目的就是避免错误防睡眠，不是永久隐藏任务。

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

这不是用来抵抗已知 session ID 的穷举，而是避免状态文件直接泄露可读身份并限制跨用途关联。

### Debug 与 Release 为什么共享文件还要加锁

两个 App bundle ID 可以同时运行，但都观察同一份 Codex Hook 数据。如果各自保存独立保护状态，一个版本隐藏的异常任务可能被另一个版本重新用于防睡眠。

状态 store 使用 actor 串行单进程访问，再用 `flock` 保护跨进程 read-modify-write。removal 还可以附带 `matchingMarkedAt`，防止旧进程的迟到删除误删另一进程刚写入的新记录。

写入按 task identifier 稳定排序并原子替换，文件权限最终校正为 `0600`

## 代际和旧结果隔离

Monitor 为 reader 和异步恢复任务维护 generation：

- reader 更换后丢弃旧 reader 的迟到结果
- bootstrap 未完成时不发布转场副作用
- 取消的 drain 不满足恢复屏障
- 数据源显式不健康时不沿用最后健康快照做静默判断

这些约束避免系统唤醒、Hook 重装或 `CODEX_HOME` 变化时出现错误完成通知和错误释放。

### monitor 中的主要 generation

| generation | 保护的异步路径 |
| --- | --- |
| `tailReaderGeneration` | reader batch, rollout poll 和 prompt backfill |
| `bootstrapCompletionGeneration` | 多次 bootstrap 重试后的异步 lifecycle 补齐 |
| `activityProtectionRecoveryGeneration` | 睡眠、唤醒和数据源恢复 |
| task `progressGeneration` | 通知宽限期间的保护候选 |

每一项都对应不同的“当前性”问题，不能合并成一个全局计数。例如 reader 没变但任务有新进展时，只需要让 protection attempt 失效，不应丢弃整个 reader。

## 扩展任务状态机的步骤

1. 先确定新输入是事实、metadata、progress 还是 terminal
2. 定义 bootstrap 与 live 是否产生相同 snapshot，是否允许 transition
3. 定义事件缺少 turn 或 session ID 时的降级行为
4. 定义迟到和重复输入如何用 timestamp, terminal memory 或 generation 拒绝
5. 如果读取 rollout 新字段，扩展最小 envelope 而不是读取正文
6. 在 `CodexActivityTask` 中维护领域状态，在 monitor 中维护跨任务关联
7. 更新 snapshot 前确认通知和防睡眠是否应该消费新状态
8. 为系统睡眠、reader 替换和数据源不健康定义恢复路径
9. 匿名任务默认不能获得新的高影响副作用，除非身份可靠性发生根本变化

## 建议验证的故障场景

- App 在任务已运行时启动，bootstrap 展示任务但不补发通知
- bootstrap 文件持续追加时能重试并最终获得稳定边界
- 连续 3 次不稳定后进入 degraded，不启动异常静默判断
- 新 prompt 立即替换旧 turn，rollout terminal 在 5 秒内准确补分类
- 同 session 多个 terminal 候选时不猜测 `Stop` 归属
- reviewer 缺失后由 rollout 确认为 user 才进入等待
- auto review 始终不发布等待 transition
- subagent 关联不可靠时 UI 不展示伪精确数量
- reader 进行中调用 `drainNow()` 必须再执行一轮新读取
- 唤醒 drain 失败时保护继续暂停
- 静默候选在 3 秒窗口内出现进展后不隐藏，迟到通知被撤回
- 阈值调长后未超新阈值的 suppressed 任务恢复
- Debug 与 Release 并发更新保护记录时新记录不被旧 removal 删除
- 匿名任务始终不进入 transition、KeepAlive 和保护状态文件

## 关键源码

- [`CodexActivityMonitor.swift`](../../CodexBar/Services/Workflow/CodexActivityMonitor.swift)
- [`CodexActivityTask.swift`](../../CodexBar/Services/Workflow/CodexActivityTask.swift)
- [`CodexActivityTerminalResolution.swift`](../../CodexBar/Services/Workflow/CodexActivityTerminalResolution.swift)
- [`HookEventTailReader.swift`](../../CodexBar/Services/Workflow/HookEventTailReader.swift)
- [`CodexSessionLifecycleReader.swift`](../../CodexBar/Services/Workflow/CodexSessionLifecycleReader.swift)
- [`CodexActivityProtection.swift`](../../CodexBar/Services/Workflow/CodexActivityProtection.swift)
- [`ActivityProtectionStateStore.swift`](../../CodexBar/Services/Workflow/ActivityProtectionStateStore.swift)

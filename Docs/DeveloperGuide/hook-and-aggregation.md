# Hook 采集与历史聚合

简体中文 | [English](../en/DeveloperGuide/hook-and-aggregation.md)

## 设计出发点

Hook 链路同时服务两个看似接近但要求相反的目标：

- 在 Codex 关键路径上尽快记录事实
- 在主 App 中可靠地维护长期统计

采集端必须短小、有界和允许失败。聚合端则可以异步运行，需要检测文件变化、修复损坏缓存并支持完整重建。

因此实现采用 append-only 原始 JSONL 加可重建日聚合，而不是让 Hook 子进程直接更新一份复杂统计对象。

## 链路职责

Hook 链路把 Codex 生命周期事件转换为可重建的本地历史统计：

```text
Codex Hook
  -> CodexBar --hook-event
  -> 原始 JSONL
  -> WorkflowService 增量聚合
  -> daily.jsonl
  -> 活跃度 UI 和 CloudKit 同步
```

原始事件是事实来源，日级聚合是可重建缓存。聚合算法或字段语义变化时，必须从保留期内的原始事件完整重建。

### 为什么不在 Hook 子进程里直接聚合

直接读改写 `daily.jsonl` 看起来少一层文件，实际会带来 4 个问题：

- 每个 Hook 都要解码和重写历史数据，事件越多延迟越高
- 子进程在 Codex 的超时预算内，聚合失败会放大成任务延迟
- 算法升级后没有原始事实可重算
- 多个并发 Codex session 更容易在读改写之间丢失更新

当前方案把关键路径缩成一条 append。主 App 可以在自己的节奏里批量聚合，失败时保留原始事件等待下一轮修复。

### 原始事实和缓存的责任

| 文件 | 是否权威 | 允许怎样恢复 |
| --- | --- | --- |
| `events/YYYY-MM-DD.jsonl` | 是 | 只追加，超过保留期后清理 |
| `daily.jsonl` | 否 | 可从原始事件完整重建 |
| `maintenance.json` | 否 | 缺失或 schema 变化时重新对账 |
| `stats.lock` | 不保存业务数据 | 只协调跨进程事务 |

## 安装与校验

[`CodexHookSettings.swift`](../../CodexBar/Services/Settings/CodexHookSettings.swift) 通过 app-server 读取和修改 Hook 配置。

启用前必须满足：

- 当前可执行文件路径可解析
- 实际 app-server 版本不低于 `0.145.0`
- `features.hooks` 可用
- `hooks/list` 返回可信来源
- 所需事件集合完整

目标配置文件位于 `$CODEX_HOME/hooks.json`，未设置 `CODEX_HOME` 时位于 `~/.codex/hooks.json`

安装逻辑把 CodexBar handler 作为独立命令加入现有配置。它不会用一份模板覆盖整个文件：

- 保留用户已有字段
- 保留其他应用已有 handler
- 只更新与当前可执行文件和 `--hook-event` 匹配的 handler
- 禁用时只移除精确匹配的 CodexBar handler
- 无法识别的配置保持原样

`isEnabled` 表示当前进程中的 Hook 开启状态，首次从现有 CodexBar handler 恢复。`isVerified` 表示最近一次 app-server 校验通过。UI 只有在 `isOperable` 成立时把 Hook 当作可工作数据源。

### 为什么安装和验证是两件事

`hooks.json` 中存在命令只能证明配置写在磁盘上，不能证明 Codex 会执行它。

实际执行还可能被以下条件阻止：

- 当前 app-server 版本过低
- `features.hooks` 被全局关闭
- handler 事件集合不完整
- app-server 解析到其他来源文件
- handler 处于 untrusted 或 modified

因此 `isEnabled` 是当前进程的开关状态，`isVerified` 是 Codex 对当前来源的最近明确结论。防睡眠和任务通知只依赖两者合成的 `isOperable`

临时 RPC 失败只代表本轮无法验证，不能反推 handler 已失效。此时保留上一次明确结论，同时展示操作错误供用户排查。

### 已开启 Hook 的对账

App 启动、设置状态刷新、菜单面板打开以及每轮额度刷新完成后，都会对账已开启的 CodexBar Hook。额度自动刷新正常每 60 秒完成一轮，因此配置和信任数据通常会在 60 秒内自动收敛：

- 只有已确认的实际 app-server 版本低于当前 Hook 最低版本时，才按手动关闭流程移除 CodexBar handler 和对应信任项
- 版本无法确认或 RPC 临时失败时保留用户配置
- 配置在当前进程中丢失不会关闭开关，而是标记配置损坏并触发自愈
- 版本受支持时遍历 `CodexHookEvent.allCases`，为缺失或非标准事件重建独立 group，然后复用信任和完整性校验
- 信任项缺失或哈希变化时，只修复 `command`、`sourcePath` 和 `event` 都属于当前 CodexBar 的条目
- 必需事件全部存在时不写 `hooks.json`

对账以当前必需事件集合和文件实际内容为依据，不保存一次性迁移标记。因此未来新增事件或用户手动删除必需 handler 时都会走同一条自愈路径。如果 App 启动前已经没有可识别的 CodexBar handler，首次读取无法恢复开启状态，Hook 保持关闭。

### 启用事务的顺序

```text
确认运行中 app-server >= 0.145.0
  -> 确认 features.hooks 没有全局关闭
  -> 读取现有 hooks.json
  -> 只移除当前 executable 的旧 CodexBar handler
  -> 为全部事件追加独立 group
  -> 原子写回 hooks.json
  -> hooks/list 读取 app-server 实际解析结果
  -> 仅信任 command + sourcePath + event 都匹配的条目
  -> 再次 hooks/list 完整校验
```

前置检查发生在文件修改之前。版本或全局开关不满足时，用户文件一个字都不会改变。

信任匹配同时要求 command 和 `sourcePath`。只按 executable 匹配可能误信任另一份配置中的相同命令，只按 source 匹配则可能碰到用户自己的 handler。

### 禁用为什么先查询信任 key

app-server 的 Hook key 来自它当前解析到的 handler。如果先从 `hooks.json` 删除命令，后续 `hooks/list` 已经无法反查对应 key。

因此禁用流程先保存精确匹配条目的 key、再删 handler、最后从 `hooks.state` 中清理这些 key。清理时先读取完整 state 再 replace，保留用户和其他工具的信任项。

信任清理失败不会把 handler 重新装回去。UI 会表达“Hook 已关闭，但清理未完成”，因为停止采集的用户意图已经成功。

### 为什么每个事件使用独立 group

CodexBar 不把命令塞进用户已有 group。独立 group 让卸载时可以只删除自身 handler，不需要理解用户 matcher 或其他 handler 之间的组合语义。

对于结构异常的同级条目，移除逻辑选择跳过而不是让整个开关失败。CodexBar 只负责识别自己的命令，不把自己变成用户 Hook 配置的全局校验器。

### 异步设置操作的代际

用户可以快速开关 Hook，App 激活也会触发校验。`CodexHookSettings` 每次操作递增 `updateGeneration` 并取消旧 Task。

每个文件写入或 RPC await 之后都会再次检查 generation。旧操作即使无法真正取消，也不能把新的开关状态或错误信息覆盖回去。

## 支持的事件

CodexBar 订阅以下 Hook 事件：

| 事件 | 聚合或实时用途 |
| --- | --- |
| `SessionStart` | 建立 session 生命周期 |
| `SessionEnd` | 结束 session |
| `UserPromptSubmit` | 建立 turn 和任务起点 |
| `PreToolUse` | 记录工具调用开始 |
| `PostToolUse` | 记录工具调用结束 |
| `PermissionRequest` | 识别用户批准等待 |
| `PreCompact` | 记录上下文压缩开始 |
| `PostCompact` | 记录上下文压缩结束 |
| `Stop` | 形成任务完成候选 |
| `SubagentStart` | 记录 subagent 启动 |
| `SubagentStop` | 记录 subagent 结束 |

### 事件字段和用途并不完全相同

历史计数需要事件名、日期、project、model 和身份集合。实时状态还需要 turn, reviewer, effort, tool, agent 关联和归一化来源。

把两类需求统一在一条最小原始记录中，可以让 recorder 只写一次，两个下游各自选择所需字段。但新增字段前仍要证明至少有一个消费者需要它，不能因为 Hook payload 中存在就全部持久化。

`transcript_path` 可用时，recorder 会为来源分类有界读取 rollout 首行。rollout 来源无法确定时，只有精确匹配 `codex-auto-review` 的 model 才作为 Auto-review 来源的后备判定。`PermissionRequest` 和 `UserPromptSubmit` 的 reviewer 或 effort 可能不在 Hook payload 中，只有这两个事件还会按 turn 定向读取 rollout 尾部。

## Hook 子进程

[`WorkflowHookEventRecorder.swift`](../../CodexBar/Services/Workflow/WorkflowHookEventRecorder.swift) 在 App 启动最早阶段检查 `--hook-event`

命中后只执行以下工作：

1. 从 stdin 读取事件 JSON
2. 提取统计和状态机需要的最小字段
3. 获取文件锁
4. 追加一条完整 JSONL
5. 在同一个锁事务中标记维护状态
6. 立即退出

handler 超时由事件决定：

| 事件 | 超时 |
| --- | --- |
| `SessionEnd` | 3 秒 |
| 其他事件 | 5 秒 |

锁等待预算为 handler 超时减 2 秒。获取锁时从 1 ms 开始指数退避，单次等待最多 20 ms。

stdin 无效、文件锁超时或写入失败都会被吞掉。Hook 子进程不能因为统计失败而阻断 Codex。

### 为什么仍然返回成功

Hook 统计是 CodexBar 的辅助能力，不是 Codex 完成任务的必要步骤。如果 recorder 把解析或磁盘错误作为非零退出码返回，一次统计故障就可能让用户的 Codex 流程失败。

因此显式进入 `--hook-event` 后，无论输入是否有效都返回已处理并退出成功。失败只意味着少一条统计，不升级为上游任务故障。

### 锁内事务为什么同时写事件和维护状态

一次采集在同一把 `stats.lock` 内完成：

```text
检查当前文件身份
  -> 必要时开始新 source generation
  -> append 完整 JSONL 行
  -> 标记该日期 pending
  -> 原子保存 maintenance.json
```

如果 append 和 pending 分成两个锁事务，App 可能在中间完成一次维护并认为当天已经追平。随后 recorder 只写事件却来不及标记 pending，新行会静默等待到下一次全目录对账。

锁内联合提交让“文件已经增长”和“维护知道需要读取”保持一致。

### 为什么锁等待只使用超时预算的一部分

Codex 对 `SessionEnd` 最多等待 3 秒，其他事件最多 5 秒。recorder 把锁等待限制为总预算减 2 秒。

预留时间用于编码、append、保存维护状态和进程退出。如果把全部预算花在等锁上，Codex 可能正好在写入中途终止进程，留下半行或未配对的维护状态。

等待从 1 ms 指数退避到最多 20 ms。主 App 的正常持锁区很短，小步起始能在锁刚释放时迅速继续，上限则避免高竞争时 busy loop。

### 锁文件为什么用一次 `open(O_CREAT)` 创建并打开

不能先判断文件不存在，创建后再打开。两个进程可能分别创建不同 inode，后创建的一方替换目录项后，双方会各自锁住不同文件并都认为自己独占。

单次 `open` 让创建和打开成为同一个原子入口，所有参与者对同一路径上的同一 inode 使用 `flock`

## 采集字段

原始记录只保留计算统计和实时状态所需的信息：

- 时间戳和事件名
- 工作目录
- tool 名称
- model 和 reasoning effort
- permission 与 approval reviewer
- session ID 和 turn ID
- agent 与 parent 关系
- 归一化来源 `origin`

对于 `UserPromptSubmit` 和 `PermissionRequest`，输入事件可能不包含 reviewer 或 effort。recorder 会在必要时从 rollout transcript 尾部回查匹配的 `turn_context`

回查范围如下：

- 单次最多读取 512 KB
- 只提取 reviewer 和 effort 等结构字段
- 不把 prompt 或 response 内容写入 Hook 统计

### 来源归一化

`WorkflowHookEvent.origin` 是 CodexBar 自己维护的有限枚举，不是 rollout 原始 `source` 的副本。构造器和解码器都在事件输入边界应用同一套来源解析规则，因此下游只读取归一化后的 `origin`：

| 有效来源 | 判定 |
| --- | --- |
| `main` | `source` 是已知顶层字符串来源 `cli`, `vscode`, `exec`, `mcp`，或有效对象来源 `{ "custom": "..." }` |
| `autoReview` | `source.subagent.other` 与 `guardian` 完全匹配，或 rollout 来源为 `unknown` 且 model 与 `codex-auto-review` 完全匹配 |
| `auxiliary` | `source` 明确表示其他 subagent，包括 `review`, `thread_spawn` 和 Memories 相关来源 |
| `unknown` | 字段缺失、结构损坏、无法读取或遇到未知顶层来源，并且 model 不满足 Auto-review 后备判定 |

来源读取从文件起点按 32 KiB 分块，遇到第一个 newline 立即停止，总预算为 256 KiB。第一条完整记录不是 `session_meta`、超过预算或任何文件与解码操作失败时，rollout 来源回退到 `unknown`，不等待、不重试，也不能让 Hook 失败。model 后备判定只接受精确字符串，不做前缀、别名或模糊匹配。

recorder 在写入前完成来源解析，JSONL 的来源字段只保存上述枚举值。`transcript_path`、原始 `source`、任意 `other` 字符串和 transcript 内容都不会写入 Hook 文件或系统日志。

JSONL 中缺少 `origin`，或枚举值无法识别时，来源字段先解码为 `unknown`。`WorkflowHookEvent` 解码器随后应用相同的精确 model 后备判定，因此 `model == "codex-auto-review"` 的事件在内存中的 `origin` 为 `autoReview`。读取过程不会回填或重写原始 JSONL。

来源分类只改变实时活动过滤，不改变历史统计输入。Auto-review 事件仍参与 session、turn、model、tool、project 和事件计数；聚合 schema 和 CloudKit 投影不包含来源分类。

### 输入归一化

Hook payload 在不同版本中可能把标识或时间表示为不同 JSON 类型。`WorkflowHookPayload` 集中做宽松归一化：

- string 会去掉首尾空白，空串转为缺失
- number 标识转换为字符串
- 时间同时接受 ISO-8601、本地 timestamp、Unix 秒和 Unix 毫秒
- 缺失时间回退到 recorder 当前时间
- 缺失 cwd 回退到子进程当前目录

宽松只发生在外部输入边界。一旦转成 `WorkflowHookEvent`，下游使用统一类型，不在聚合器和 monitor 中重复猜测协议差异。

### rollout 尾部回查的边界

回查只读取 transcript 最后 512 KB、丢弃可能被截断的第一行，再从后向前寻找匹配 turn 的 `turn_context`

从后向前是因为同一个 turn 的最新上下文更接近文件尾。限制读取范围是为了守住 Hook 超时，找不到时保留字段缺失而不是扩大成无界扫描。

## 本地文件

默认数据根目录是：

```text
~/Library/Application Support/CodexBar/HookEvents/
```

目录结构如下：

```text
HookEvents/
  events/
    YYYY-MM-DD.jsonl
  daily.jsonl
  maintenance.json
  stats.lock
  Sync/
    state.json
    cache.jsonl
    cursor.data
```

| 文件 | 作用 |
| --- | --- |
| `events/YYYY-MM-DD.jsonl` | 按天保存原始 Hook 事件 |
| `daily.jsonl` | 按日期和来源代际保存聚合结果 |
| `maintenance.json` | 保存待处理维护和 schema 状态 |
| `stats.lock` | 协调 Hook 子进程和 App 维护任务 |
| `Sync/*` | CloudKit 同步游标和缓存 |

原始事件和日聚合最长保留 210 天。session ID 和 turn ID 的明细列表只保留 3 天，更早日期压缩为计数，降低本地文件体积和身份信息留存。

### 为什么选择 JSONL

JSONL 与这一链路的写入模式匹配：

- recorder 只需要在文件尾追加一条完整记录
- 单行损坏可以被隔离，不必让整个文件解码失败
- 文件可以按日切分和保留期清理
- 人工排查时仍可检查单条结构
- 聚合缓存和远端缓存也能使用相同的逐行恢复策略

普通 JSON 数组每次 append 都要改写尾部结构。数据库会增加 schema、锁和部署复杂度，但当前查询只按日期顺序扫描，没有足够收益。

### 完整行是提交单位

reader 只推进到最后一个 newline 对应的 offset。文件尾如果正在写入半行，本轮保留旧 offset，下一轮等完整行出现后再处理。

`JSONLines.decodeWithFailures` 按行解码。一条坏行只增加 corrupt count，不会连带丢掉同一读取块中的其他正确事件。

### 为什么身份明细只保留 3 天

session 和 turn ID 用于近期精确去重，但长期展示只需要计数。

3 天后把 identifiers 压缩为 count，可以同时降低文件体积和身份信息保留。聚合模型必须记录该字段当前是 retained 还是 compacted，否则无法判断后续新事件能否继续用 ID 精确去重。

原始事件仍在 210 天保留期内，所以算法升级时可以完整重建。CloudKit 从不上传这些原始身份。

## 增量读取与来源代际

聚合器记录每个原始文件的 inode, size, offset 和 source generation：

- 正常追加时从上次 offset 继续读取
- inode 改变表示文件被替换
- size 小于 offset 表示文件被截断
- 替换或截断会创建新的 source generation

source generation 让同一天的不同原始来源可被区分。同源结果按替换处理，明确独立的 generation 可以累加，用户完整重建则通过同步层的 replacement 标记声明旧 generation 全部失效。

### `pending` 和 `dirty` 的区别

`maintenance.json` 对每个日期维护两类待办：

| 状态 | 何时使用 | 下一步 |
| --- | --- | --- |
| `pending` | 已确认是同一来源上的正常追加 | 从旧 offset 增量聚合 |
| `dirty` | 来源变化、schema 变化、缓存缺失或上次处理失败 | 从文件起点完整重建 |

`dirty` 优先于 `pending`。同一天同时出现在两个集合时只生成重建任务，避免先追加到旧聚合再完整覆盖。

这种显式状态比通过 `offset == 0` 猜测任务类型更安全。全新空文件、被截断文件和主动重建都可能具有 offset 0，但它们的 source generation 和同步语义不同。

### 如何判断文件还是同一来源

维护层综合 4 类证据：

- inode 标识是否变化
- 当前 size 是否小于已处理 offset
- 当前 size 是否与维护记录的上次 size 一致
- offset 前 4 KB 的 boundary hash 是否仍匹配

inode 与 size 能发现替换和截断，boundary hash 能发现保持相同长度的原地改写。

### boundary hash 为什么还配合 mtime

每轮都给 210 天内所有文件重算 hash 会长时间持有 `stats.lock`，直接增加 Hook recorder 的等待概率。

维护状态记录上次验证 boundary 时的 nanosecond mtime。inode, size 和 mtime 都没变化时直接跳过 hash。文件变化后才重算 offset 前 4 KB。

正常 append 只修改 offset 之后的字节，所以 boundary 仍匹配，maintenance 可以继续增量处理。boundary 改变则创建新 generation 并标脏。

### build 和 commit 为什么分开

聚合器不能在读取整天文件时一直持有 `stats.lock`，否则 Hook 子进程可能连续超时。

实际流程是：

```text
锁内 prepare
  -> 固定 sourceGeneration, inode, startOffset 和读取上界
解锁后 build
  -> 分块读取并生成候选 aggregate
锁内 validate
  -> generation 仍相同
  -> inode 仍匹配
  -> 候选上界仍存在
  -> boundary hash 仍匹配
提交 daily.jsonl
锁内再次 validate 并推进 maintenance offset
```

读取期间允许 recorder 继续 append。只要候选上界之前的字节没变，本次结果仍然有效，新增尾部会保留为下一轮 pending。

如果来源在 build 期间被替换，候选结果不会提交，maintenance 会开始新 generation 并等待重建。

## 聚合规则

日级结果包括：

- Hook 事件总数和各事件计数
- session 数和 turn 数
- tool call 数
- compaction 数
- subagent 数
- project 分布
- model 分布

成对事件可能只有一侧成功落盘。因此计数使用能够避免重复且允许缺失的规则：

- tool call 使用 `max(PreToolUse, PostToolUse)`
- compaction 使用 `max(PreCompact, PostCompact)`
- subagent 使用 `max(SubagentStart, SubagentStop)`

字段缺失与数值 `0` 的含义不同：

- 缺失表示该日期的历史来源无法提供该指标
- `0` 表示来源可用且明确没有发生

解码和 UI 展示必须保留这个区别。

### 为什么成对事件使用 `max`

`PreToolUse` 和 `PostToolUse` 描述同一次工具调用的两侧。recorder 允许失败后，任意一侧都可能缺失：

- 相加会把完整的一次调用统计为 2 次
- 只看 pre 会漏掉 pre 写入失败而 post 成功的调用
- 只看 post 会漏掉工具开始后进程中断的调用
- `max(pre, post)` 在没有稳定 call ID 时给出最不容易重复的估计

compaction 和 subagent 成对事件使用相同规则。

如果未来 Hook 协议提供稳定 operation ID，去重算法可以升级为集合去重，但这属于聚合语义变化，必须递增 schema 并完整重建。

### 可用性如何穿过旧数据

旧版本聚合可能没有某类 Hook count。重建时不能因为当前代码认识该事件，就假定旧来源也采集过。

`WorkflowHookCountAvailability` 保存每类计数是否有来源。重建会继承现有日期对旧字段的可用性，新鲜来源则可以声明当前字段全部可用。

这使 UI 能区分：

- 明确发生 0 次
- 当前日期的历史采集没有这个指标

## Schema 演进与重建

当前聚合 schema 为 `5`，由 `WorkflowMaintenanceState.currentAggregationSchema` 管理。

以下变化必须递增 schema：

- 原始事件到聚合结果的算法变化
- 输出字段增删
- 字段含义变化
- 去重规则变化
- 来源代际合并语义变化

升级后统一从 210 天保留期内的原始 JSONL 完整重建，不做字段级历史迁移。这种策略让聚合缓存始终能够由同一套当前算法生成。

用户手动重建时也走同一条完整重算路径，并向同步层标记需要替换的日期。

### aggregation schema 与 source generation 不同

| 标识 | 描述 | 何时变化 |
| --- | --- | --- |
| aggregation schema | 当前代码如何从原始事件计算聚合 | 算法、字段或语义变化 |
| source generation | 某一天的原始文件属于哪一代来源 | 替换、截断、主动重建或边界改写 |

schema 变化通常把保留期内所有事件日期标脏。source generation 变化只影响具体日期。

两者都不能用 App 版本号替代。一个 App 版本可能不改变聚合，开发构建也可能在不变更版本号时多次迭代 schema。

### 为什么不做字段级迁移

`daily.jsonl` 本来就是派生缓存，原始 JSONL 又在保留期内。为每个旧字段编写迁移会同时维护旧算法和新算法，更容易产生混合语义。

完整重建的一次性成本可控，换来以下保证：

- 同一 schema 下所有日期由同一套代码生成
- 删除或改变字段语义时没有残留值
- 损坏的聚合行也能一起修复
- CloudKit replacement 可以统一跟随 source generation

只有原始来源本身缺少字段时，才通过 missing 保留历史能力差异。

### 用户手动重建的提交语义

批量重建按日期独立处理。单日失败不会阻断已经成功的日期，失败日期会标脏交给常规维护继续尝试。

成功和失败日期都会先登记 CloudKit replacement。原因是失败日期已经进入新 generation，后续自动重建成功时会使用新 record identity。如果没有提前标记，旧 generation 可能留在云端与新值叠加。

只有所有日期都失败时，操作整体返回失败。部分成功会返回详细 summary，包括成功日期、损坏行和 replacement pending 状态。

## 维护调度

[`WorkflowService.swift`](../../CodexBar/Services/Workflow/WorkflowService.swift) 是 actor，串行执行读取、聚合、清理和重建。

维护任务与额度刷新周期协调，但两条数据链路没有数据依赖。Workflow ViewModel 对 UI 的最短刷新间隔为 5 秒，避免频繁文件变更造成重复渲染。

### 为什么空转维护不写普通日志

维护默认跟随 60 秒刷新。空闲机器一天会执行上千次没有变化的检查。

`WorkflowService` 累计连续 idle 轮数，只有真正写入、跳过、失败或清理时才输出一条摘要，并附带之前空转次数。这样日志既能证明维护一直在运行，又不会淹没真正故障。

### scheduler 如何合并请求

`WorkflowSyncScheduler` 串行处理 3 类请求：

1. 用户重建，优先级最高
2. 带同步的维护
3. 仅本地维护

同步完成后有 8 秒冷却。冷却期间的多个请求合并成一次，并保留最先到达的 trigger 作为真正起因。

UI 打开只读取当前本地快照，不自动越过 scheduler 发起无条件 CloudKit 请求。

## 新增 Hook 事件或指标的步骤

1. 在 `CodexHookEvent` 登记协议名、配置名和 handler timeout
2. 确认 recorder 只持久化计算所需的最小字段
3. 更新 Hook 安装完整性校验
4. 在 accumulator 中定义计数和去重语义
5. 更新 aggregate 的 Codable 与 JSONL 编码，保留旧字段 missing 语义
6. 递增 `WorkflowMaintenanceState.currentAggregationSchema`
7. 更新 CloudKit record schema、上传和下载映射
8. 确认旧 App 与新 record 共存策略后再修改兼容格式
9. 补充 UI 展示和隐私边界
10. 手动验证正常 append、单侧事件缺失、文件替换和完整重建

## 建议验证的故障场景

- 多个 Codex session 并发写入时每行完整且无覆盖
- 主 App 持锁时 Hook recorder 能在预算内成功或安全放弃
- stdin 非 JSON 或缺少 event name 时子进程仍立即成功退出
- 文件尾半行不会推进 offset，补全后下一轮能读取
- 单条损坏 JSONL 只增加 corrupt count
- inode 变化、文件缩小和 boundary 改写都触发新 generation
- build 期间继续 append 时只提交固定上界，尾部保留 pending
- schema 变化后保留期内日期全部用当前算法重建
- 旧日期缺失字段仍显示 unavailable，不变成 `0`
- 禁用 CodexBar Hook 不删除用户 handler 和信任项
- 快速开关 Hook 时旧 RPC 结果不能覆盖最后一次操作

## 故障边界

- 单条损坏 JSONL 不应让整个保留期不可读
- 文件来源改变后不能继续使用旧 offset
- 重建失败时保留最后一份可用聚合
- 维护中断不能把部分结果当作完整日期提交
- Hook 不可用时 UI 应表达来源不可用，而不是清空为 `0`
- 配置写入失败不能破坏原有 handler

## 关键源码

- [`CodexHookSettings.swift`](../../CodexBar/Services/Settings/CodexHookSettings.swift)
- [`WorkflowHookEventRecorder.swift`](../../CodexBar/Services/Workflow/WorkflowHookEventRecorder.swift)
- [`CodexHookEvent.swift`](../../CodexBar/Models/CodexHookEvent.swift)
- [`JSONLines.swift`](../../CodexBar/Services/Workflow/JSONLines.swift)
- [`WorkflowService.swift`](../../CodexBar/Services/Workflow/WorkflowService.swift)
- [`CodexWorkflowModels.swift`](../../CodexBar/Models/CodexWorkflowModels.swift)

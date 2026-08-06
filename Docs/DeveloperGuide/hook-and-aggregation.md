# Hook 采集与历史聚合

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

`isEnabled` 只表示 handler 存在，`isVerified` 表示最近一次 app-server 校验通过。UI 只有在 `isOperable` 成立时把 Hook 当作可工作数据源。

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

stdin 无效，文件锁超时或写入失败都会被吞掉。Hook 子进程不能因为统计失败而阻断 Codex。

## 采集字段

原始记录只保留计算统计和实时状态所需的信息：

- 时间戳和事件名
- 工作目录
- tool 名称
- model 和 reasoning effort
- permission 与 approval reviewer
- session ID 和 turn ID
- agent 与 parent 关系

对于 `UserPromptSubmit` 和 `PermissionRequest`，输入事件可能不包含 reviewer 或 effort。recorder 会在必要时从 rollout transcript 尾部回查匹配的 `turn_context`

回查范围如下：

- 单次最多读取 512 KB
- 只提取 reviewer 和 effort 等结构字段
- 不把 prompt 或 response 内容写入 Hook 统计

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

## 增量读取与来源代际

聚合器记录每个原始文件的 inode，size，offset 和 source generation：

- 正常追加时从上次 offset 继续读取
- inode 改变表示文件被替换
- size 小于 offset 表示文件被截断
- 替换或截断会创建新的 source generation

source generation 让同一天的来源替换可被显式表达，避免把旧文件贡献和新文件贡献直接相加。

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

## 维护调度

[`WorkflowService.swift`](../../CodexBar/Services/Workflow/WorkflowService.swift) 是 actor，串行执行读取，聚合，清理和重建。

维护任务与额度刷新周期协调，但两条数据链路没有数据依赖。Workflow ViewModel 对 UI 的最短刷新间隔为 5 秒，避免频繁文件变更造成重复渲染。

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

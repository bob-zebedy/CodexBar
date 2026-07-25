# Codex Hook 与工作流统计

CodexBar Hook 是可选功能, 用于记录本机 Codex 工作流事件; 它为实时任务, 任务中心, 任务通知, 防休眠, 每日工作流统计和跨设备同步提供数据

## 注册与关闭

Hook 配置文件位于

```text
${CODEX_HOME}/hooks.json
```

未设置 `CODEX_HOME` 时使用

```text
~/.codex/hooks.json
```

开启 Hook 时, CodexBar 会

1. 通过 app-server 确认 Codex 没有全局禁用 Hook
2. 保留现有配置, 只移除当前 CodexBar 可执行文件的旧条目
3. 为全部受支持事件追加独立 command handler
4. 原子写回 `hooks.json`
5. 通过 `hooks/list` 验证事件, 命令, 来源和启用状态
6. 必要时通过 `config/batchWrite` 更新 `hooks.state` 中对应的信任哈希

handler 命令格式为

```text
'<CodexBar 可执行文件>' --hook-event
```

单个 handler 超时为 5 秒

关闭 Hook 时, CodexBar 只删除同时匹配当前可执行路径和 `--hook-event` 的 handler, 并只清理这些 Hook 的信任项; 其他应用或用户自行配置的 Hook 保持不变

## 事件范围

CodexBar 注册以下事件

| 事件 | 用途 |
| --- | --- |
| `SessionStart` | 会话开始 |
| `UserPromptSubmit` | 新任务或新轮次开始 |
| `PreToolUse` | 工具调用开始 |
| `PostToolUse` | 工具调用结束 |
| `PermissionRequest` | 权限审批请求 |
| `PreCompact` | 上下文压缩开始 |
| `PostCompact` | 上下文压缩结束 |
| `Stop` | 任务完成 |
| `SubagentStart` | 子 Agent 开始 |
| `SubagentStop` | 子 Agent 结束 |

事件名解析会忽略大小写, 下划线和连字符差异

## Hook 子进程

应用启动入口最先检查 `--hook-event`; 处于 Hook 模式时不会创建菜单栏, 窗口或普通服务, 而是

1. 从 stdin 读取一份 JSON payload
2. 归一化事件字段
3. 追加一行本地 JSONL
4. 立即退出

原始事件行包含

```text
timestamp, event, model, effort, permission, approval,
session, turn, agent, tool, cwd
```

除事件名外, 其余字段允许缺失; 时间戳缺失时使用当前时间, 工作目录缺失时使用子进程当前目录

`PermissionRequest` 和 `UserPromptSubmit` 可以从 payload 中的 rollout 路径读取对应 `turn_context`, 补充审批路由和推理强度; 只有审批路由为 `user` 时, 实时任务才进入"等待批准"; `auto_review` 和 `guardian_subagent` 仍按运行状态处理

## 本地文件

工作流数据目录为

```text
~/Library/Application Support/CodexBar/HookEvents/
```

| 文件 | 内容 |
| --- | --- |
| `events/YYYY-MM-DD.jsonl` | 按本地日期拆分的原始 Hook 事件 |
| `daily.jsonl` | 每日聚合结果 |
| `maintenance.json` | 维护 schema, 文件位置, 待增量和待重建状态 |
| `stats.lock` | Hook 子进程与主 App 共用的进程级文件锁 |
| `Sync/` | 开启跨设备同步后使用的本地同步状态和缓存 |

Hook 子进程在跨进程排他锁内完成文件追加和维护状态更新; 主 App 的聚合读取在锁外执行, 提交前后再检查源文件大小, inode 和边界哈希, 避免把截断, 替换或并发写入误认为连续追加

JSONL 中的坏行会被跳过并计数, 不会使整天数据失效

## 每日聚合

主 App 根据维护状态执行两类任务

- `pending`: 从已记录的文件 offset 增量读取新增事件
- `dirty`: 从当天事件文件开头重新构建聚合

以下情况会触发全量重建: 维护 schema 不匹配, 每日聚合缺失或损坏, 事件文件被截断或替换, 已处理边界发生变化

每日聚合保存

- 事件总数
- 各 Hook 事件计数
- 会话数和轮次数
- 项目计数
- 模型计数
- 来源 generation

统计口径

| 展示指标 | 计算方式 |
| --- | --- |
| 会话总数 | 优先使用去重会话 ID 或压缩后的计数, 回退到 `SessionStart` 数量 |
| 对话轮次 | 优先使用去重轮次 ID 或压缩后的计数, 回退到 `Stop` 数量 |
| 工具调用 | `PreToolUse` 与 `PostToolUse` 的较大值 |
| 上下文压缩 | `PreCompact` 与 `PostCompact` 的较大值 |
| 子 Agent | `SubagentStart` 与 `SubagentStop` 的较大值 |
| 权限请求 | `PermissionRequest` 数量 |
| 最热模型 | 模型事件计数最高者; 并列时按名称排序 |

会话 ID 和轮次 ID 只在最近 3 个本地自然日的聚合中保留, 用于持续去重; 更早日期只保存计数; 原始事件和每日聚合最多保留最近 210 天, 维护时删除过期的原始事件文件

## 实时任务

`HookEventTailReader` 启动时读取最近 24 小时事件, 然后每 2 秒增量读取当天文件; 日期切换时会先读完旧文件, 再开始新文件

实时任务以 `session + turn` 为主要标识, 缺少字段时回退到 session 或项目; 状态由 Hook 事件和 Codex rollout 生命周期共同确定

- `UserPromptSubmit` 创建运行任务
- 工具, 压缩和子 Agent 事件更新运行状态
- `PermissionRequest` 在审批路由为用户时进入等待状态
- `Stop` 记录完成
- rollout 中的 `task_complete` 和 `turn_aborted` 补充可靠终态与时长

rollout reader 每秒检查活跃任务, 只读取任务开始, 上下文, 完成和终止字段, 不解析对话正文或工具内容

任务中心保留最近 10 分钟的完成和终止记录; 菜单栏完成状态高亮约 30 秒; 实时恢复窗口为最近 24 小时

## 手动重建

设置中的"重建数据"允许选择最近 210 天内的日期范围; CodexBar 只处理范围内存在非空原始事件文件的日期, 并逐日重建 `daily.jsonl`

单日失败不会中止其他日期; 失败日期保持为待重建状态, 后续维护会继续处理; 跨设备同步开启时, 所选日期还会登记为当前设备的待替换数据; 详见 [跨设备同步](CrossDeviceSync.md)

## 隐私

Hook 原始事件和本地聚合默认只保存在本机; CodexBar 不记录对话正文, 工具输入输出或认证内容; 跨设备同步仅使用每日脱敏聚合, 不上传原始事件, session ID, turn ID 或 agent ID

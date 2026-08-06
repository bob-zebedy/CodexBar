# 实时任务监控

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

## HookEventTailReader

[`HookEventTailReader.swift`](../../CodexBar/Services/Workflow/HookEventTailReader.swift) 是 actor，默认每 2 秒检查 Hook 事件文件。

### Bootstrap

首次启动读取最近 24 小时文件以建立任务基线：

- 每块最多读取 512 KB
- 最多尝试 3 次获得稳定文件边界
- 使用 inode 和 size 判断读取期间是否发生替换或追加
- bootstrap 结果不会触发历史完成或等待通知

如果无法得到稳定边界，reader 会跳到当前文件末尾并发布显式不健康状态。这样不会把不完整历史误解释为真实任务变化。

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

调用发生前已经在执行的读取不能满足屏障。reader 被替换，数据源不可用或任务取消时，调用方不能使用旧快照继续判定。

## Rollout 生命周期读取

[`CodexSessionLifecycleReader.swift`](../../CodexBar/Services/Workflow/CodexSessionLifecycleReader.swift) 读取 `$CODEX_HOME/sessions` 和 `$CODEX_HOME/archived_sessions`

读取规则如下：

- 默认每 1 秒检查一次
- 初始尾部窗口为 512 KB
- effort 等 turn context 字段最多回查 8 MB
- 只解析生命周期，turn，progress，effort 和 reviewer
- 不读取或保存对话内容用于产品展示

Hook 的 `Stop` 只是完成候选。rollout 中的 terminal 状态用于区分真正完成，用户取消和异常中断。

## 任务身份

任务 key 按可用信息选择最精确身份：

1. `session ID + turn ID`
2. `session ID`
3. 匿名 project key

新的 prompt 会替代同一 session 的旧 turn。旧 turn 进入最长 5 秒 terminal grace，给迟到的结束事件留出对账时间。

subagent 事件更新父任务的 subagent 活动，不创建独立顶层任务卡片。

### 匿名任务

`WorkflowHookEvent.sessionId` 缺失时, task key 使用匿名 project key. `isAnonymous` 会保留到 `CodexActivityTaskSnapshot`, `CodexActivityCompletion` 和 `CodexActivityTermination`

匿名任务仍进入活动快照和最近终态记录. 活动卡片与任务中心统一显示橙色 `person.crop.circle.dashed` 图标, help 为 `匿名任务不参与防睡眠`. 活动卡片的 `+N` 只表示其他活跃任务总数

匿名运行任务不展示精确运行时长, 匿名完成和终止记录也不包含精确耗时

匿名任务不向通知消费者发布等待批准或完成 transition, 不触发任务触觉反馈, 不进入 KeepAlive 的运行中或等待任务集合, 不参与异常会话保护. `activityProtectionIdentifier` 对匿名 key 返回 nil, 保护状态文件不会保存匿名任务记录

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

## 系统睡眠与唤醒

系统即将睡眠时暂停异常会话保护判断。唤醒后执行严格恢复顺序：

1. 进入恢复状态并继续暂停保护
2. 等待 `HookEventTailReader.drainNow()` 成功
3. 重置 rollout 生命周期解析的 fallback
4. 使用新 Hook 结果和 rollout 结果统一对账
5. 恢复异常会话保护判断

如果新一轮读取失败，reader 被更换或数据源不可用，不得使用睡眠前快照继续判断任务静默。

## 异常会话保护

异常会话保护只在防睡眠主开关开启时工作, 只处理非匿名 `running` 任务

等待批准任务不参与静默阈值判断。原因是等待批准本身就是一个合法的无进展状态。

可选阈值为：

- 30 分钟
- 1 小时，默认值
- 2 小时
- 4 小时

任务达到阈值后：

1. 先持久化保护记录
2. 从活动快照中隐藏任务
3. 尝试发送保护通知
4. 如果任务出现新进展，清除抑制并恢复展示

通知提交有 3 秒宽限，但隐藏任务不依赖通知成功。这可以保证通知权限或系统服务失败时，防睡眠仍能释放。

保护判断在以下阶段暂停：

- Hook bootstrap
- 系统睡眠
- 唤醒恢复
- Hook 数据源不可用
- reader 正在更换

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

任务身份使用 SHA-256 摘要, 不把 session ID 或 turn ID 原文写入该状态文件. 匿名任务没有保护标识, 不写入该文件

## 代际和旧结果隔离

Monitor 为 reader 和异步恢复任务维护 generation：

- reader 更换后丢弃旧 reader 的迟到结果
- bootstrap 未完成时不发布转场副作用
- 取消的 drain 不满足恢复屏障
- 数据源显式不健康时不沿用最后健康快照做静默判断

这些约束避免系统唤醒，Hook 重装或 `CODEX_HOME` 变化时出现错误完成通知和错误释放。

## 关键源码

- [`CodexActivityMonitor.swift`](../../CodexBar/Services/Workflow/CodexActivityMonitor.swift)
- [`CodexActivityTask.swift`](../../CodexBar/Services/Workflow/CodexActivityTask.swift)
- [`CodexActivityTerminalResolution.swift`](../../CodexBar/Services/Workflow/CodexActivityTerminalResolution.swift)
- [`HookEventTailReader.swift`](../../CodexBar/Services/Workflow/HookEventTailReader.swift)
- [`CodexSessionLifecycleReader.swift`](../../CodexBar/Services/Workflow/CodexSessionLifecycleReader.swift)
- [`CodexActivityProtection.swift`](../../CodexBar/Services/Workflow/CodexActivityProtection.swift)
- [`ActivityProtectionStateStore.swift`](../../CodexBar/Services/Workflow/ActivityProtectionStateStore.swift)

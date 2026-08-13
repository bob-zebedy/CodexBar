# 设计原则与关键决策

这篇文档解释 CodexBar 为什么采用现在的结构，以及这些结构在解决什么问题。

它不是源码目录索引，也不是功能列表。阅读目标是建立一套判断标准：当实现需要变化时，哪些只是可以替换的手段，哪些是必须继续成立的系统不变量。

## 从产品目标推导架构

CodexBar 看起来只是一个菜单栏 App，但它同时横跨 4 个性质完全不同的边界：

- Codex 自己的本机协议和配置
- 持续变化的 Hook 与 rollout 文件
- macOS 窗口、通知和电源管理
- 带 root 权限的系统级睡眠与定时唤醒控制

这些边界不能用同一种失败策略处理。

例如，额度刷新失败时保留上一次数据通常比清空更有价值。Hook 采集失败时必须立即放弃，因为统计不能阻塞 Codex。防睡眠释放失败时则不能静默退出，因为系统设置可能仍被 CodexBar 持有。

因此项目没有追求一个包办所有工作的全局 service，而是先按输入来源和失败语义拆开，再在 UI 和副作用层组合只读快照。

## 决策优先级

遇到实现取舍时，按以下顺序判断：

1. 不阻断用户正在执行的 Codex 任务
2. 不遗留或误改系统级状态
3. 不把旧数据、缺失数据或不确定状态伪装成当前事实
4. 不让迟到的异步结果覆盖更新的用户意图
5. 不扩大特权进程、网络和持久化数据的边界
6. 在上述条件成立后再优化延迟、文件大小和 UI 动画

这个顺序解释了很多看起来不对称的处理：

- Hook recorder 获取锁超时后丢弃本次统计，而不是继续等待
- App 退出时可以被延后，直到 helper 确认释放由 CodexBar 拥有的睡眠状态并取消自动重置唤醒计划
- app-server 补充接口失败时可以展示带陈旧标记的缓存，但 method unsupported 必须展示来源缺失
- 唤醒恢复如果没有通过新的 Hook 读取屏障，异常会话保护继续暂停

## 事实、快照与副作用

项目中的状态分为 3 层：

| 层级 | 含义 | 示例 |
| --- | --- | --- |
| 事实 | 外部系统或本地日志已经发生的输入 | Hook 事件、rollout terminal、app-server 响应 |
| 快照 | 对一组事实按当前规则得到的可展示状态 | `CodexQuotaSnapshot`, `WorkflowSnapshot`, `CodexActivitySnapshot` |
| 副作用 | 因可信状态变化而执行的一次性动作 | 通知、触觉反馈、XPC 租约、CloudKit 上传 |

设计上刻意不让 View 从原始事实直接执行副作用。

例如，通知服务不扫描任务中心列表猜测哪个任务刚完成，而是消费 monitor 发布的 transition。防睡眠控制器也不解析 Hook，它只消费活动快照中的运行和等待任务。

这样做有两个原因：

- 快照可以重复读取，transition 必须最多消费一次
- 同一个状态机可以统一处理 bootstrap、去重、迟到事件和 rollout 对账，消费者不需要各自实现一套近似规则

## 3 条数据链路为什么必须独立

### app-server 链路

app-server 提供账户、额度和 token 用量的周期性快照。它适合按分钟刷新，允许在短暂故障时展示同账户缓存。

### Hook 历史链路

历史链路把 append-only 原始事件转成日级聚合。它允许延迟，可以从原始 JSONL 重建，主要目标是长期一致性。

### 实时任务链路

实时链路关心秒级任务状态和一次性转场。它需要组合 Hook 与 rollout，不能等待日级聚合完成，也不能把十分钟前的终态当成一条新通知。

如果把三者合并成一条链路，会产生错误耦合：

- app-server 暂时失败会让本来仍可读取的本地任务状态消失
- 聚合重建会阻塞实时任务更新
- 为通知设计的 terminal 去重会污染历史计数
- CloudKit 或网络故障会反向影响本地 Hook 展示

允许它们在 UI 层组合，但不允许互相充当事实来源，是 CodexBar 最重要的架构边界之一。

## 用户意图、依赖可用性与实际效果

设置类功能通常同时存在 3 种状态：

```text
用户意图 -> 依赖是否可用 -> 实际效果
```

防睡眠是最完整的例子：

- `isEnabled` 表示用户愿意让 CodexBar 管理睡眠
- Hook、helper、电量和时长共同决定当前是否具备执行条件
- `isPreventingSleep` 表示 App 与 helper 已经确认实际效果

依赖暂时不可用时不能把 `isEnabled` 写回 `false`。否则一次 RPC 故障就会永久修改用户偏好，恢复后也无法自动继续。

Hook 设置同样区分：

- `isEnabled` 表示配置文件中安装了 handler
- `isVerified` 表示 app-server 最近一次给出明确可用结论
- `isOperable` 才是下游依赖应使用的状态

这个三层模型比一个布尔值多一些状态，但避免了把配置、诊断和效果混成不可解释的开关。

## 不确定性必须进入类型和 UI

项目中多处保留 `nil`, stale 或 degraded，而不是统一回落为零或空数组。

### 缺失不等于零

旧 Hook 数据没有某个计数字段时，`nil` 表示当时没有采集能力。`0` 才表示数据源明确确认没有发生。

如果把两者合并，历史图表会把不可知数据画成真实零值，后续无法再修复解释。

### 陈旧不等于失败

同一账户的 app-server 补充接口暂时失败时，旧额度或用量仍有参考价值。快照用 `isRateLimitsStale` 和 `isUsageStale` 标记它们，UI 通过透明度表达可信度下降，通知则完全跳过陈旧额度。

### 降级 bootstrap 不等于空闲

实时 reader 无法获得稳定文件边界时会跳到文件末尾，但同时发布 degraded 和数据源不健康。这不是“确认当前没有任务”，而是“无法可靠恢复现有任务”。

## 为什么大量使用 generation

CodexBar 的 I/O 大多具有以下共同风险：

1. 请求 A 开始
2. 用户改变设置或 reader 被替换
3. 请求 B 开始并先完成
4. 请求 A 最后返回

只取消 Task 不足以解决这个问题。某些系统 API 和同步桥接不能真正取消，旧回调仍可能到达。

因此关键异步路径同时维护单调递增 generation：

- 刷新协调器只允许当前 generation 提交
- Hook 设置只允许最新操作更新 UI
- tail reader 替换后丢弃旧 reader batch
- 唤醒恢复同时校验 reader generation 和 recovery generation
- XPC 租约请求用 generation 防止迟到的 acquire 覆盖 release
- helper 状态请求和 CloudKit 可用性检查也按 generation 丢弃旧结果

generation 的价值不是“更容易取消”，而是让提交资格成为可以验证的显式条件。

## 为什么使用 actor、MainActor 和锁三种并发手段

三者解决的问题不同：

| 手段 | 解决范围 | 典型对象 |
| --- | --- | --- |
| `MainActor` | UI 可观察状态和 AppKit 生命周期 | Controller, ViewModel, Settings, Monitor |
| Swift actor | 单进程内异步可变状态 | app-server、聚合、reader、CloudKit service |
| `flock` | 多进程共享文件事务 | Hook recorder 与主 App 的统计文件 |

actor 不能保护另一个 CodexBar Hook 子进程。`flock` 也不适合承载 UI 状态。选择并发工具时先确认竞争发生在哪个边界，不要因为项目已经使用 actor 就把所有同步问题都塞进 actor。

默认 `MainActor` 让 UI 类型更安全，代价是任何阻塞式文件或 pipe 等待都必须显式移出主 actor。`AppServerSession` 和底层 pipe reader 使用受锁保护的非隔离边界，上层 `CodexStatusService` actor 再串行管理连接。

## 为什么原始日志与派生缓存分开

Hook 原始 JSONL 是可审计事实，`daily.jsonl` 是当前算法生成的缓存。

这种结构提供 3 个长期收益：

- 聚合算法修正后可以重建历史，不需要为每个旧字段设计迁移
- 写入关键路径只追加一行，不需要在 Codex 等待的几秒内读改写整份统计
- CloudKit 同步可以只上传聚合，保持原始身份和路径留在本机

代价是必须明确管理 schema、offset 和来源替换。因此维护状态保存 `sourceGeneration`, inode, size, boundary hash 和 dirty/pending 状态。

## `sourceGeneration` 解决的不是版本号问题

同一天的事件文件可能被替换、截断或由用户重建。日期相同并不代表它还是同一份事实来源。

`sourceGeneration` 给“这份日期数据来自哪一代原始文件”一个稳定身份：

- 正常追加保持同一 generation
- inode 变化、文件缩小或已消费边界被改写时创建新 generation
- CloudKit record name 可以区分不同 generation
- 展示层只把明确独立的贡献相加，同源结果按替换处理

如果只用日期作为身份，重建后的新值会和旧云端值叠加，产生永久双重计数。

## 为什么实时任务同时读取 Hook 和 rollout

两种来源各自只解决一半问题：

| 来源 | 优势 | 缺口 |
| --- | --- | --- |
| Hook | 延迟低、事件类型清楚、适合实时 UI | `Stop` 不能总是区分完成与中断，部分上下文字段可能缺失 |
| rollout | terminal, effort 和 reviewer 更权威 | 文件定位和解析更慢，不适合作为唯一低延迟信号 |

monitor 先用 Hook 建立活动状态，再用 rollout 补齐生命周期。`Stop` 形成完成候选，`SessionEnd` 或新 prompt 会把任务移入短暂终态确认窗口，rollout 在宽限期内给出准确分类。

这不是简单的“双源合并”。冲突时需要按语义决定谁更权威，还要防止迟到事件复活已经完成的任务。

## 为什么特权 helper 只接受受限电源操作

App 需要 root 权限修改 `pmset disablesleep` 和登记系统 `wake` 事件，但任务识别、自动重置判断、网络和文件解析不需要 root。

把策略放进 helper 会显著扩大攻击面和故障恢复范围。当前边界把 helper 限制为一个小型执行器：

- 输入只有睡眠租约、generation、状态查询、更新恢复标识和有限的 Unix 唤醒时间戳
- 睡眠命令固定为 `/usr/bin/pmset` 的固定参数组合，唤醒计划固定为 CodexBar owner 和 `wake` 类型
- 客户端通过 code-signing requirement 校验
- helper 不读取 Codex 文件、不访问网络、不接受任意路径或命令

App 决定“应该怎样”，helper 只负责“以受限权限执行并验证”。

## 为什么租约还需要所有权记录

租约解决“还有没有活跃 App 请求”，所有权解决“当前系统值是不是 CodexBar 改的”。

两者不能互相替代：

- 没有租约时 helper 应撤销自己的效果
- 但如果 `SleepDisabled=1` 原本由用户或其他 App 设置，CodexBar 没有权恢复为 `0`
- 如果 CodexBar 完成了 `0 -> 1`，helper 必须先持久化 owned，崩溃后才能恢复

因此释放条件是“最后一个租约结束并且 ownership 为 owned”，而不是简单看到没有客户端就写 `0`

## 为什么 CloudKit 同步聚合而不是原始事件

跨设备展示只需要日级统计。上传原始事件会带来额外身份信息、更大的数据量和更复杂的去重，却不增加当前产品能力。

同步聚合的收益包括：

- session, turn 和 agent ID 保留在本机
- 网络和 CloudKit 操作量由事件数降为日期数
- 本机仍然可以独立重建，云端只保存各设备贡献
- 设备间合并规则可以围绕 `deviceId + date + sourceGeneration` 定义

project 显示名仍可能敏感，所以同步必须由用户主动开启，不能因为已经登录 iCloud 就默认上传。

## 容易忽略的小巧思

### `@Published` 回调参数比现场回读更可靠

Combine 的发布发生在 `willSet`。订阅闭包执行时，属性本身可能仍是旧值。

因此 Hook 可用性、同步 activation 和防睡眠依赖在订阅路径中使用闭包参数计算，而不是立刻回读对象属性。这是多个看似重复的状态镜像存在的原因。

### 边界 hash 只覆盖已经消费的尾部

历史聚合不对每个文件每轮全量 hash。它只保存 offset 前 4 KB 的 boundary hash，再用 mtime 判断是否需要重算。

正常追加只发生在 offset 之后，不会改变这个边界。这既能发现已消费内容被原地改写，又避免长期持有 `stats.lock`，让 Hook 子进程更快落盘。

### 状态排序有 UUID 兜底

多个任务时间戳可能相同，而 Swift sort 不稳定。快照在时间相等时再按 UUID 字符串排序，避免 SwiftUI diff 因无意义的顺序抖动反复刷新。

### 通知提交前再次检查相关性

等待批准和异常保护通知从判定到系统真正接收之间存在异步窗口。任务可能已经恢复运行。

通知服务在每次提交和重试前调用 `isStillRelevant`，失效则撤回 pending 与 delivered notification。这比只在状态变化时尝试删除更可靠。

### XPC 请求超时不能清除“可能持有租约”

请求超时只能说明回复没有到达，不能证明 helper 没有执行 acquire。`mayHaveHelperLease` 因此一直保留到一次明确成功的 release。

如果超时就直接清零，App 退出时可能跳过释放，让 helper 等到 watchdog 才恢复系统状态。

### 外部睡眠来源需要持续观察

任务开始时如果系统已经 `SleepDisabled=1`，helper 将来源标记为 external。但外部来源可能在任务仍运行时自行撤销。

helper 定期读取实际值。一旦 external 消失而租约仍有效，CodexBar 可以安全完成自己的 `0 -> 1` 并取得 owned，防睡眠不会悄悄失效。

### 菜单栏锚点必须先验证

全局快捷键触发时，`NSStatusBarButton` 可能暂时没有可用 window 或位于另一块屏幕。直接展示 popover 会出现位置错误或完全不显示。

控制器先验证锚点尺寸和屏幕交集，不可信时在鼠标所在屏幕使用 fallback panel。两种容器共享同一个 SwiftUI 内容，业务层不用知道当前是哪一种。

### 只调度最近一个真实截止时间

任务过期、完成高亮、terminal grace 和异常静默都不是靠高频 UI timer 扫描。monitor 收集所有截止时间，只为最近一个建立 Task，到点后重算并安排下一次。

这样能减少菜单栏 App 常驻时的无意义唤醒，也让每个保留期在代码中有明确来源。

## 修改设计时的检查方法

新增功能或修改核心语义前，依次回答以下问题：

1. 新数据来自哪条链路，它的权威来源是什么
2. 数据缺失、旧值、明确零值和失败是否被区分
3. 这是可重复读取的状态，还是最多执行一次的 transition
4. 异步结果返回时如何证明自己仍属于当前 generation
5. 是否扩大了网络、持久化、CloudKit 或 root helper 的边界
6. 是否影响旧 UserDefaults、本地 schema、CloudKit record 或 Debug 与 Release 共存
7. 崩溃、强制退出、系统睡眠和文件替换后如何恢复
8. 哪些日志足以区分正常降级和真实故障，同时不泄露用户数据
9. 哪些手动场景能验证设计不变量，而不只是验证理想路径

如果其中任何一项没有明确答案，说明实现还没有形成完整的生命周期设计。

## 不应轻易改变的不变量

- Hook 子进程失败不能阻断 Codex
- 3 条数据链路保持独立
- `CodexActivityMonitor` 是实时任务唯一状态来源
- bootstrap 不发布历史 transition
- `drainNow()` 保证请求后的新读取屏障
- 缺失的计数字段不解释为 `0`
- 原始事件是聚合缓存的重建来源
- 聚合语义变化递增 schema 并完整重建
- root helper 不获得网络、任意命令或额外文件读取能力
- 只有 CodexBar 自己取得的睡眠所有权可以由 CodexBar 恢复
- 自动重置只替换或取消 CodexBar 固定 owner 的 `wake` 事件，不修改其他计划事件
- 通知描述系统效果时，必须在效果已经确认后发送
- 匿名任务不进入通知、防睡眠和异常会话保护
- 兼容性变化必须先确定迁移与降级策略

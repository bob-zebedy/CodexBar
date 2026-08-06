# CloudKit 同步

## 同步范围

CloudKit 同步用于在同一 iCloud 账户的 Mac 之间合并 Hook 日级统计

同步对象是聚合结果, 不是原始 Hook 事件

```text
本机原始 Hook JSONL
  -> 本机日级聚合
  -> 当前设备 CloudKit 记录
  -> 下载其他设备记录
  -> 按日期合并展示
```

账户, 额度, token 总量, 实时任务和防睡眠状态不参与同步

## 设计目标和非目标

同步的目标不是复制一台 Mac 的数据库, 而是让多台设备对同一天的独立贡献可以安全相加

因此设计优先级是

1. 不上传原始工作内容和可直接关联硬件的身份
2. 本机统计永远不依赖 CloudKit 才能展示
3. 重扫和文件替换不能制造重复计数
4. 网络失败时保留最后一份可解释的远端快照
5. 重试必须幂等, 不依赖请求恰好只执行一次

以下内容明确不属于同步协议

- 实时任务状态, 因为它变化快且需要本机低延迟判断
- 账户额度, 因为它属于 Codex 账户而不是设备工作历史
- 防睡眠状态, 因为它是当前 Mac 的系统副作用
- 原始事件, 因为跨设备统计只需要可合并的日级事实

把同步放在聚合层之后还有一个维护收益: 原始 Hook 格式可以独立演进, CloudKit 只面对稳定的日级投影

## 权威来源如何划分

同步展示同时使用 3 类值

| 数据 | 权威来源 | 断网时行为 |
| --- | --- | --- |
| 当前设备当天和历史贡献 | 本机 `daily.jsonl` | 继续实时更新 |
| 其他设备贡献 | `cache.jsonl` 中最近成功拉取的记录 | 保留最后快照 |
| 上传确认和增量位置 | `state.json` 与 `cursor.data` | 下次继续或重建 |

当前设备始终 local-first. CloudKit 中的本机副本是传给其他设备的复制品, 不是当前设备 UI 的真相来源. 这个规则避免网络往返期间出现先增加一次, 拉取后又重复增加一次的闪烁

远端缓存是可重建投影, 游标只是加速状态. 任何游标错误都可以退化成全量读取 custom zone, 不要求用户清理本地文件

## CloudKit 结构

[`WorkflowSyncService.swift`](../../CodexBar/Services/Workflow/WorkflowSyncService.swift) 使用 App 的 CloudKit private database

| 项目 | 值 |
| --- | --- |
| Container | `iCloud.app.zabrian.codexbar` |
| Custom zone | `CodexBarZone` |
| 元数据 record type | `CodexBarSyncMetadata` |
| 日聚合 record type | `CodexBarDailyAggregate` |

private database 中的数据只属于当前 iCloud 账户, 不写入 public database

custom zone 的意义不只是命名空间. 它提供 zone change token 和删除事件, 使设备可以增量同步新增, 修改和删除, 而不需要每轮扫描整个 private database

zone 已确认状态和账户 salt 会在 actor 内跨同步轮次缓存, 省去每轮两个固定网络往返. 任意同步失败会使这两项缓存失效, 因为 iCloud 账户切换也可能首先表现为一次请求失败. 下一轮重新确认比继续使用错误账户上下文更安全

## 启用条件

同步只有在以下条件全部成立时运行

- 用户打开 CloudKit 同步
- Hook 已启用并校验通过
- 当前 iCloud 账户可用
- 本地聚合服务可用

首次启用会标记 backfill, 上传本地保留期内需要同步的日期. 同步调度有最短 8 秒冷却, 合并短时间内的多次本地变化

## 设备匿名化

同步需要区分设备贡献, 但不能直接上传硬件标识

1. 在 private database 创建 32 字节随机账户 salt
2. 读取本机 `IOPlatformUUID`
3. 使用账户 salt 对 UUID 执行 HMAC-SHA256
4. 把结果作为云端 `deviceId`

原始 `IOPlatformUUID` 不会上传. 同一设备在同一 iCloud 账户中得到稳定 pseudonym, 不同账户得到不同结果

这里使用 HMAC 而不是普通 SHA-256. 硬件 UUID 的输入空间有固定格式, 单纯 hash 仍是跨账户稳定标识. 账户私有 salt 让同一硬件在不同 iCloud 账户中产生不可关联的 pseudonym

salt 存在同一个 private custom zone 中. 多台设备先后创建时通过 CloudKit 冲突后回读现有记录收敛到同一份 salt, 而不是让每台设备各自产生不兼容身份

本地状态记录最近解析出的 `deviceId`. 如果它变化, 同步会清除旧游标和远端缓存, 但保留待 replacement 日期. 设备身份变化意味着缓存的账户作用域已经不可信, 不能继续增量套用

## 日聚合字段

每条日记录包含

- schema
- device ID pseudonym
- 日期
- source generation
- Hook 事件计数
- session 数和 turn 数
- project 计数
- model 计数
- 更新时间

不会上传

- 原始 Hook JSONL
- session ID 或 turn ID 原文
- 完整工作目录
- prompt 或 response 内容
- Codex 账户和额度
- token 或 `auth.json`
- App 请求日志
- 异常会话保护状态

更完整的数据边界见 [数据与隐私边界](data-and-privacy.md)

## 一次同步的阶段

```text
确认 iCloud 账户
  -> 创建或确认 custom zone
  -> 读取账户 salt 并解析设备 pseudonym
  -> 读取本地同步状态和缓存
  -> 上传当前设备变化日期
  -> 拉取远端变更
  -> 更新本地 CloudKit 缓存
  -> 清理超过保留期的记录
  -> 发布合并结果
```

实际顺序刻意在上传前先拉取

- 上传前知道远端是否已经有同设备同日记录, 才能选择更新, 新建 generation 记录或跳过
- replacement 前必须先全量拉取, 才能找到增量缓存可能遗漏的旧 generation
- 上传后再次拉取, 才能把本轮写入和其他设备并发写入统一进本地缓存
- 最后清理过期记录, 避免清理失败阻断本轮有效数据上传

每个阶段都写入日志中的 `stage`, 失败信息因此能回答问题发生在 zone, device, fetch, upload 还是 prune, 而不只得到一个笼统的 CloudKit error

- 上传每批最多 25 条记录
- 单批操作最长等待 20 秒
- 拉取单页最多 200 条变更
- 本地内容使用 SHA-256 hash 跳过未改变记录

20 秒是整轮上传预算, 不是每条记录的超时. 达到预算后剩余日期保留为未确认状态, 后续调度继续处理. 这样一次历史 backfill 不会长时间占用 actor 和用户可见刷新链路

每个日期的稳定 JSON 只编码并 hash 一次, 同一结果同时用于筛选和成功确认. 如果在不同阶段重新编码, 字典顺序或可选字段差异可能让"是否改变"判断自行漂移

上传使用 `atomically: false`. 单批部分成功时, 每条 CloudKit 结果分别确认, 失败日期移除本地 hash 以便重试. 协议依赖单记录幂等身份, 不要求 25 条全部成功才前进

## 合并语义

同一天可能有多个设备记录, 也可能有当前设备尚未上传的最新本地结果

合并规则是

- 其他设备贡献按字段相加
- 当前设备使用最新本地聚合替换云端的同源贡献
- 同一 source generation 最多计算一份
- 已确认属于不同来源的 generation 可以累加
- 当前设备本地数据缺失时才使用云端缓存贡献

用本地值替换当前设备云端值可以避免同步刚上传但本地 UI 已更新时发生双重计数

### 同设备同日为什么可能有多条记录

早期记录名只包含 `deviceId + date`. 新鲜来源可额外使用 `deviceId + date + sourceGeneration`

generation 记录用于表达某一份原始来源的身份. 同源的本地和云端结果是替换关系, 明确不同的来源则可能是同一天先后产生的独立贡献

读取层先寻找与本地 `sourceGeneration` 匹配的 record. 匹配项只取本地或远端中更完整的一份, 其他 generation 继续累加. 旧 legacy record 没有 generation 时, 内容完全相同也可视为同源, 用于兼容早期记录

"所有旧 generation 都应失效"不是从 generation 本身推断, 而是由显式 `replacementDates` 事务表达. 这一区分避免正常文件换代丢掉独立贡献, 又让用户主动完整重建可以删除历史副本

上传目标的选择遵循以下原则

| 远端状态 | 本地来源 | 动作 |
| --- | --- | --- |
| 没有同日记录 | 任意 | 创建 legacy 或 generation record |
| 有同源记录 | 本地不少于远端 | 更新该记录 |
| 有同源且远端事件更多 | 本地带 generation | 保留远端, 避免较短的陈旧扫描覆盖较完整结果 |
| 有其他来源记录 | 本地来源新鲜 | 创建当前 generation record |
| 有其他来源记录 | 本地来源不新鲜 | 跳过, 等待权威重建 |

`sourceIsFresh` 是一次读取对原始来源完整性的判断, 不是时间新旧. 文件被替换, 截断或仍在稳定边界确认中时, 较新的时间戳也不代表更权威

### missing 为什么不能转成 0

CloudKit record schema 演进时, 旧记录可能没有新计数字段. `nil` 表示该设备那天无法提供这项统计, `0` 表示明确观察到零次

合并时保留可用性信息, UI 才能区分"所有设备合计为 0"和"部分历史来源不支持该指标". 把缺失解码成 0 会制造无法在以后修复的虚假事实

## 来源替换与重建

Hook 原始文件被替换或完整重建时, 聚合层会改变 source generation. 同步层必须把这个变化解释为替换, 不能把新旧代际相加

用户执行重新扫描时

1. 本地聚合从原始 JSONL 重建
2. 受影响日期标记为 replacement
3. 当前设备对应日期的云端记录被覆盖或删除后重建
4. 其他设备记录保持不变

这种设计让重建只修正当前设备贡献

### replacement 为什么是持久化事务

重建和 CloudKit 同步不一定在同一进程生命周期完成. `replacementDates` 因此保存在 `state.json`, 不能只留在内存

对每个 replacement 日期, 同步执行

1. 全量重建远端缓存
2. 枚举当前设备同日所有已知 legacy 和 generation record ID
3. 删除这些旧贡献, `unknownItem` 按幂等成功处理
4. 从本地 hash 表移除该日期, 强制重新上传
5. 只有新内容得到确认后才清除 replacement 标记

replacement 进行中时, 快照会临时过滤当前设备该日期的云端缓存, 同时展示本机最新聚合. 即使 App 在删除和重传之间退出, UI 也不会把旧云端贡献与新本地贡献相加

先全量拉取是这一事务最关键的小细节. 增量 cursor 只保证从游标之后的变化完整, 不保证本地缓存从未因旧版本或手动删除丢过记录. 删除前全量枚举才能避免遗留幽灵 generation

## 增量游标与本地缓存

同步状态位于

```text
~/Library/Application Support/CodexBar/HookEvents/Sync/
```

| 文件 | 作用 |
| --- | --- |
| `state.json` | 同步 schema, 本地 hash, backfill 和替换状态 |
| `cache.jsonl` | 远端设备日聚合缓存 |
| `cursor.data` | CloudKit zone change token |

当前 CloudKit record schema 为 `5`. 本地同步状态 schema 为 `4`, 能读取上一版 schema `3`

3 个文件有不同的可恢复等级

| 文件 | 丢失后代价 | 恢复方式 |
| --- | --- | --- |
| `state.json` | 失去上传 hash 和 replacement 进度 | 重新比较并上传, replacement 需依赖仍存在的标记 |
| `cache.jsonl` | 暂时看不到其他设备贡献 | 全量拉取 custom zone |
| `cursor.data` | 失去增量位置 | 全量拉取并重新建立 baseline |

`cursor.data` 使用 secure coding 保存 CloudKit opaque token. 代码不解析其内部结构. 全量拉取后还要建立新的 cursor baseline, 否则下一轮可能从空游标重复消费刚拉取的全部变化

本地 schema `3 -> 4` 的读取路径会先重建远端缓存再提交新状态. 未知 schema 则回到空同步状态, 因为错误解释上传确认信息比重新同步更危险

任何 record 字段, identity 或 schema 的变化都是兼容性决策. 需要同时考虑旧 App 仍在写入, 新 App 如何读取旧字段, 以及降级后是否会覆盖新记录, 不能只递增一个常量

## 调度器为什么独立存在

本地维护和 CloudKit 同步共享聚合输入, 但触发频率不同. `WorkflowSyncScheduler` 把多处触发合并为单线程状态机

优先级为

```text
用户请求重建 > 可立即执行的同步维护 > 纯本地维护 > 冷却中的同步
```

关键细节包括

- 同步完成后 8 秒内的新请求合并到下一轮, 避免一次 Hook burst 触发多轮网络操作
- 合并请求保留最早 trigger, 因为它才是这轮工作的真实起因
- 重建会取消前一个尚未开始的重建 completion, 不让调用方永远等待
- 同步在等待期间被关闭时清除 pending sync, 但仍允许必要的本地维护继续
- `@Published` 订阅发生在 `willSet`, 从回调内读取属性仍是旧值, 因此 activation 由新回调参数显式计算后传入

最后一点是 Combine 生命周期中很容易被"整理代码"破坏的小巧思. 现场重新读取 settings 看起来更简洁, 实际会用旧值决定是否同步

## 失败和恢复语义

同步失败不回滚已经确认的独立 record, 也不清空最后一份可用 cache. 下轮通过 hash, record ID 和 CloudKit 幂等 API 继续收敛

| 失败点 | 已保留状态 | 下轮动作 |
| --- | --- | --- |
| zone 或账户确认 | 本地聚合和旧 cache | 重新确认 zone 和 salt |
| 增量拉取 | 旧 cache | 退化为全量重建 |
| 部分上传 | 已成功日期 hash | 仅重试未确认日期 |
| replacement 删除 | replacement 标记 | 重新枚举并幂等删除 |
| prune | 有效期内数据和上传结果 | 后续再清理 |

账户级缓存会在失败后失效, 但磁盘 cache 不会立刻作为新账户事实发布. availability 和 device identity 重新确认后才恢复同步快照

## 修改同步协议时的检查顺序

1. 先定义字段语义, 尤其是 missing, 0 和空集合是否不同
2. 决定 record identity 是否仍然幂等
3. 评估旧 App 与新 App 并发写入的结果
4. 明确本地 state, cache 和 cursor 的升级或重建路径
5. 检查 replacement 是否能删除所有旧代际
6. 检查隐私边界和用户 opt-in 是否仍成立
7. 用两台设备和一次中途失败验证最终收敛

## 保留与清理

CloudKit 记录保留期与本地 Hook 历史一致, 最长 210 天

- 本地原始和日聚合过期后删除
- 当前设备过期云端记录进入清理
- 本地远端缓存同步移除过期日期
- 清理失败不影响仍在保留期内的数据展示

## 错误分类

同步层区分以下状态, 供设置页展示和通知

- 网络不可用
- iCloud 账户不可用
- CloudKit 服务不可用
- 服务端要求稍后重试
- 本地数据或 schema 不兼容
- 同步成功或无需变化

临时错误保留最后一份可用远端缓存. 账户切换或身份失效时不能继续把旧账户缓存当作当前账户数据

## 手动验证矩阵

- 首次启用后上传保留期内本机聚合
- 第二台设备能够合并显示, 不重复当前设备贡献
- 关闭同步后只显示本地统计
- iCloud 未登录时显示明确状态, 本地统计继续工作
- 网络断开后使用最后缓存, 恢复后完成增量同步
- 本机重建后只替换当前设备记录
- 超过 210 天的本地和远端缓存被清理
- iCloud 账户切换后不显示前一账户缓存

## 关键源码

- [`WorkflowSyncService.swift`](../../CodexBar/Services/Workflow/WorkflowSyncService.swift)
- [`WorkflowSyncScheduler.swift`](../../CodexBar/Services/Workflow/WorkflowSyncScheduler.swift)
- [`WorkflowSyncSettings.swift`](../../CodexBar/Services/Settings/WorkflowSyncSettings.swift)
- [`CodexWorkflowModels.swift`](../../CodexBar/Models/CodexWorkflowModels.swift)
- [`CodexBar.entitlements`](../../CodexBar/Resources/CodexBar.entitlements)

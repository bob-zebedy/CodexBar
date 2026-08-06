# CloudKit 同步

## 同步范围

CloudKit 同步用于在同一 iCloud 账户的 Mac 之间合并 Hook 日级统计。

同步对象是聚合结果，不是原始 Hook 事件：

```text
本机原始 Hook JSONL
  -> 本机日级聚合
  -> 当前设备 CloudKit 记录
  -> 下载其他设备记录
  -> 按日期合并展示
```

账户，额度，token 总量，实时任务和防睡眠状态不参与同步。

## CloudKit 结构

[`WorkflowSyncService.swift`](../../CodexBar/Services/Workflow/WorkflowSyncService.swift) 使用 App 的 CloudKit private database：

| 项目 | 值 |
| --- | --- |
| Container | `iCloud.app.zabrian.codexbar` |
| Custom zone | `CodexBarZone` |
| 元数据 record type | `CodexBarSyncMetadata` |
| 日聚合 record type | `CodexBarDailyAggregate` |

private database 中的数据只属于当前 iCloud 账户，不写入 public database。

## 启用条件

同步只有在以下条件全部成立时运行：

- 用户打开 CloudKit 同步
- Hook 已启用并校验通过
- 当前 iCloud 账户可用
- 本地聚合服务可用

首次启用会标记 backfill，上传本地保留期内需要同步的日期。同步调度有最短 8 秒冷却，合并短时间内的多次本地变化。

## 设备匿名化

同步需要区分设备贡献，但不能直接上传硬件标识：

1. 在 private database 创建 32 字节随机账户 salt
2. 读取本机 `IOPlatformUUID`
3. 使用账户 salt 对 UUID 执行 HMAC-SHA256
4. 把结果作为云端 `deviceId`

原始 `IOPlatformUUID` 不会上传。同一设备在同一 iCloud 账户中得到稳定 pseudonym，不同账户得到不同结果。

## 日聚合字段

每条日记录包含：

- schema
- device ID pseudonym
- 日期
- source generation
- Hook 事件计数
- session 数和 turn 数
- project 计数
- model 计数
- 更新时间

不会上传：

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

- 上传每批最多 25 条记录
- 单批操作最长等待 20 秒
- 拉取单页最多 200 条变更
- 本地内容使用 SHA-256 hash 跳过未改变记录

## 合并语义

同一天可能有多个设备记录，也可能有当前设备尚未上传的最新本地结果。

合并规则是：

- 其他设备贡献按字段相加
- 当前设备使用最新本地聚合替换云端同设备贡献
- 同一设备同一天只取当前 source generation
- 当前设备本地数据缺失时才使用云端缓存贡献

用本地值替换当前设备云端值可以避免同步刚上传但本地 UI 已更新时发生双重计数。

## 来源替换与重建

Hook 原始文件被替换或完整重建时，聚合层会改变 source generation。同步层必须把这个变化解释为替换，不能把新旧代际相加。

用户执行重新扫描时：

1. 本地聚合从原始 JSONL 重建
2. 受影响日期标记为 replacement
3. 当前设备对应日期的云端记录被覆盖或删除后重建
4. 其他设备记录保持不变

这种设计让重建只修正当前设备贡献。

## 增量游标与本地缓存

同步状态位于：

```text
~/Library/Application Support/CodexBar/HookEvents/Sync/
```

| 文件 | 作用 |
| --- | --- |
| `state.json` | 同步 schema，本地 hash，backfill 和替换状态 |
| `cache.jsonl` | 远端设备日聚合缓存 |
| `cursor.data` | CloudKit zone change token |

当前 CloudKit record schema 为 `5`。本地同步状态 schema 为 `4`，能读取上一版 schema `3`

## 保留与清理

CloudKit 记录保留期与本地 Hook 历史一致，最长 210 天：

- 本地原始和日聚合过期后删除
- 当前设备过期云端记录进入清理
- 本地远端缓存同步移除过期日期
- 清理失败不影响仍在保留期内的数据展示

## 错误分类

同步层区分以下状态，供设置页展示和通知：

- 网络不可用
- iCloud 账户不可用
- CloudKit 服务不可用
- 服务端要求稍后重试
- 本地数据或 schema 不兼容
- 同步成功或无需变化

临时错误保留最后一份可用远端缓存。账户切换或身份失效时不能继续把旧账户缓存当作当前账户数据。

## 手动验证矩阵

- 首次启用后上传保留期内本机聚合
- 第二台设备能够合并显示，不重复当前设备贡献
- 关闭同步后只显示本地统计
- iCloud 未登录时显示明确状态，本地统计继续工作
- 网络断开后使用最后缓存，恢复后完成增量同步
- 本机重建后只替换当前设备记录
- 超过 210 天的本地和远端缓存被清理
- iCloud 账户切换后不显示前一账户缓存

## 关键源码

- [`WorkflowSyncService.swift`](../../CodexBar/Services/Workflow/WorkflowSyncService.swift)
- [`WorkflowSyncScheduler.swift`](../../CodexBar/Services/Workflow/WorkflowSyncScheduler.swift)
- [`WorkflowSyncSettings.swift`](../../CodexBar/Services/Settings/WorkflowSyncSettings.swift)
- [`CodexWorkflowModels.swift`](../../CodexBar/Models/CodexWorkflowModels.swift)
- [`CodexBar.entitlements`](../../CodexBar/Resources/CodexBar.entitlements)

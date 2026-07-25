# 跨设备同步

CodexBar 使用 CloudKit 私有数据库同步每日工作流聚合; 同步是可选功能, 仅在 CodexBar Hook 已开启, 用户打开同步开关且当前 iCloud 账号可用时生效

## 同步范围

每台设备按日期上传一条或多条来源明确的聚合记录, 内容包括

- 日期和来源 generation
- Hook 事件总数
- 会话开始和任务完成计数
- 工具调用前后计数
- 权限请求计数
- 上下文压缩前后计数
- 子 Agent 开始和结束计数
- 已压缩的会话数和轮次数
- 项目计数字典
- 模型计数字典
- 设备标识和更新时间

以下内容不会同步

- 原始 Hook 事件
- session ID, turn ID, agent ID
- 对话正文, 工具输入输出和 Codex rollout 文件
- app-server 请求日志
- Codex `auth.json`, access token 或其他认证文件
- 账号额度和 Token 用量

## CloudKit 结构

容器

```text
iCloud.app.zabrian.codexbar
```

数据库和自定义 zone

```text
privateCloudDatabase / CodexBarZone
```

记录类型

| 类型 | 内容 |
| --- | --- |
| `CodexBarSyncMetadata` | 账号级随机 salt 和同步 schema |
| `CodexBarDailyAggregate` | 单台设备, 单个日期, 单个来源 generation 的每日聚合 |

当前写入的 CloudKit schema 版本为 `4`

## 设备标识

CodexBar 不直接上传 Mac 的 `IOPlatformUUID`; 应用先在当前 iCloud 私有 zone 中创建或读取 32 字节随机 salt, 再计算

```text
HMAC-SHA256(IOPlatformUUID, account salt)
```

计算结果作为同步设备标识; 不同 iCloud 私有数据库使用不同 salt, 原始硬件 UUID 不写入 CloudKit

## 本地同步状态

同步目录位于

```text
~/Library/Application Support/CodexBar/HookEvents/Sync/
```

| 文件 | 内容 |
| --- | --- |
| `state.json` | schema, 当前设备 ID, 各日期确认 hash, 待替换日期和最近上传时间 |
| `cache.jsonl` | 保留范围内所有设备的 CloudKit 每日记录缓存 |
| `cursor.data` | CloudKit zone 增量变化游标 |

当前本地同步 state schema 为 `4`, 可读取上一版 schema `3` 并通过全量远端缓存重建迁移

## 同步流程

一次同步按以下顺序执行

1. 确认自定义 zone 存在
2. 创建或读取账号级 salt, 并计算当前设备 ID
3. 设备 ID 变化时清理本地游标和远端缓存
4. 使用 zone 游标拉取增量变化; 没有游标或增量失败时全量查询
5. 将本机 `daily.jsonl` 转换为同步聚合并计算稳定 hash
6. 上传尚未确认的日期
7. 再次拉取 CloudKit 变化并更新本地缓存
8. 每天清理当前设备超过 210 天的云端记录

单批最多处理 25 条上传, 每轮上传预算为 20 秒; 未处理完成的日期保留为待同步状态, 由后续刷新继续

首次开启同步会请求补传保留范围内的本机聚合; 日常同步由工作流调度器合并, 主要触发来源包括

- app-server 自动刷新后的工作流维护
- 同步开关开启
- Codex Hook 重新开启
- iCloud 同步账号恢复可用

连续同步之间使用 8 秒冷却窗口, 期间的新请求合并为一次后续同步

## 合并规则

界面展示会合并本机聚合和 `cache.jsonl` 中的远端记录

- 其他设备的记录按日期累加
- 当前设备与本机相同 generation 的远端副本不会重复累加
- 相同来源中 `eventCount` 更大的记录作为较完整版本
- 没有 generation 的旧记录只有在全部同步字段一致时才视为本机副本
- 明确从空文件开始的新 generation 可以作为独立来源累加
- 来源不明确的替换优先保留已有远端记录, 避免把同一批数据重复计数

上传同样遵循来源连续性; 相同来源的远端记录事件数更大时, 本机不会用较小聚合覆盖它

## 数据重建与替换

用户在设置中重建日期范围后, CodexBar 将这些日期登记为当前设备的待替换数据; 下一次可用同步会

1. 全量刷新 CloudKit 本地缓存
2. 删除当前设备在对应日期的旧记录, 包括 legacy 和 generation 记录
3. 从本地缓存移除这些旧副本
4. 上传重建后的新 generation
5. 新记录确认后清除待替换标记

替换只影响当前设备和所选日期, 不删除其他设备或范围外记录; 删除, 上传或网络请求中断时, 待替换标记会保留并在后续同步继续

## 保留期

本地工作流聚合和 CloudKit 缓存只参与最近 210 天的展示; CodexBar 每天清理当前设备超过保留期的 CloudKit 记录, 并从本地同步状态中移除对应确认 hash

其他设备的过期记录由对应设备在同步时清理; 即使远端仍存在, 当前设备加载缓存时也会过滤保留期外的数据

## 状态与错误

设置页显示最近一次实际上传时间; 主面板底部 iCloud 图标表示

- 同步未开启
- 正在同步
- 同步可用及最近上传时间
- 网络, 账号, 服务或重试类错误

同步失败会保留本地数据和待处理状态; zone 与账号 salt 的进程内缓存会失效, 下一轮重新确认当前 iCloud 账号状态

## 发布要求

CloudKit Production 环境必须包含当前 `CodexBarSyncMetadata` 和 `CodexBarDailyAggregate` 字段; 代码不会在运行时把 Development schema 部署到 Production

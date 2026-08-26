# 数据、同步与隐私

简体中文 | [English](../en/UserGuide/sync-data-privacy.md)

## 跨设备同步的内容

跨设备同步用于合并多台 Mac 的每日 Hook 聚合，不同步账户、额度、Token 用量、重置次数或自动重置设置。

启用条件如下：

- CodexBar Hook 已开启
- 当前 iCloud 账户可用
- 用户主动打开 `跨设备同步`

开启后，CodexBar 会回填本机保留期内的每日 Hook 聚合，并在后续统计维护时上传变化的日期。

每台设备的同日数据独立保存，展示时会合并不同设备的贡献，同时避免重复叠加当前设备的本地副本和云端副本。

同步使用 `iCloud.app.zabrian.codexbar` 容器的 CloudKit private database。

## 同步状态

主面板底部和设置页会显示以下状态：

| 状态 | 含义 |
| --- | --- |
| 同步未开启 | 用户没有开启同步或 CodexBar Hook 已关闭 |
| 正在同步 | 正在读取或写入 CloudKit |
| 已同步 | 最近一轮同步成功 |
| 同步失败 | 网络、iCloud 账户或服务暂时不可用 |

设置页还会显示最近一次成功上传时间。

## 重建数据

`设置 > 高级 > 重建数据` 用于从本机原始 Hook 事件重新生成所选日期的每日聚合。

适合以下场景：

- 旧聚合缺少新版本新增的统计字段
- 某些日期统计异常
- 本机原始事件发生过替换或截断
- 需要用本机结果替换当前设备同日的云端贡献

重建流程如下：

1. 日期选择器只允许选择原始 Hook 数据保留期内的日期
2. 有原始数据的日期会显示标记
3. 确认后重新解析所选日期的本机 JSONL
4. 无法解析的行会跳过并计入结果
5. 开启同步时，重建日期会在后续同步中替换当前设备对应日期的云端贡献

重建不会修改 Codex 账户、额度或 Token 用量。

## 本机保存的数据

| 数据 | 内容 | 位置或生命周期 |
| --- | --- | --- |
| Hook 原始事件 | 选定的结构化事件字段 | `~/Library/Application Support/CodexBar/HookEvents/events`，保留 210 天 |
| Hook 每日聚合 | 事件计数、会话与轮次、项目名计数和模型计数 | `~/Library/Application Support/CodexBar/HookEvents/daily.jsonl`，保留 210 天 |
| Hook 维护状态 | 文件 `offset`、`generation` 和待处理日期 | `~/Library/Application Support/CodexBar/HookEvents/maintenance.json` |
| 同步缓存 | CloudKit 缓存、游标和上传状态 | `~/Library/Application Support/CodexBar/HookEvents/Sync` |
| 异常会话保护 | 哈希任务标识和时间戳 | `~/Library/Application Support/CodexBar/ActivityProtection/state.json`，最长 24 小时 |
| CodexBarHelper 所有权 | 睡眠所有权状态和恢复事务 | `/Library/Application Support/CodexBar/helper-state.json` |
| 自动重置唤醒计划 | CodexBar 固定 owner、`wake` 类型和下一次时间 | macOS 系统电源管理，触发或取消后移除 |
| App 偏好 | 开关、阈值、快捷键、自动重置提前量和通知去重状态 | macOS UserDefaults |
| app-server 交互日志 | 最近 500 条请求和响应 | 只存在当前 App 进程内存 |

每日聚合只在最近 3 天保留 session 和 turn ID 列表，更早日期转换为计数并删除列表。

CodexBarHelper 所有权文件由 root 持有，用于 App 或 CodexBarHelper 异常退出后的睡眠状态恢复。

自动重置唤醒计划不包含账户、重置次数、`creditId` 或幂等键。CodexBarHelper 启动时会清理同一构建身份遗留的计划，App 也会在任务变化、功能关闭和正常退出时取消计划。

匿名任务不参与异常会话保护，因此不会生成哈希任务标识或写入保护状态文件。

## CloudKit 上传字段

每条每日聚合记录可能包含以下内容：

- iCloud 账户范围内的设备伪标识
- 日期
- 本机 Hook 数据来源 `generation`
- 各类 Hook 事件计数
- 会话数和对话轮次数
- 项目显示名计数
- 模型名计数
- 更新时间

设备伪标识由设备 UUID 和 iCloud private database 中的随机 salt 计算，不直接上传原始设备 UUID。

## CloudKit 不上传的内容

- 原始 Hook 事件文件
- session ID、turn ID 和 agent ID
- 完整工作目录路径
- prompt、Codex 回复、工具参数或工具输出
- Codex 账户、额度和 Token 用量
- 重置次数明细、自动重置设置和消费状态
- app-server 交互日志
- 异常会话保护记录
- Codex 认证 token

项目显示名和模型名属于同步内容，如果项目名本身包含敏感信息，不应开启跨设备同步。

## 数据读取边界

CodexBar 会读取以下本机数据：

- 通过本机 app-server 获取账户、额度、Token 用量、手动重置次数明细和 Codex 配置
- 读取 Hook 原始事件以生成统计和实时任务
- 读取本机 Codex rollout 的首条来源和生命周期字段，以排除 Auto-review 实时任务、区分完成与终止并补充进展时间

rollout 来源读取最多 256 KiB，只保存 `main`, `autoReview`, `auxiliary` 或 `unknown` 四种归一化结果。CodexBar 不保存 rollout 路径或原始来源值；其他 rollout 读取也只提取生命周期、时间和推理强度等字段，不展示或保存会话正文和工具内容。

用户主动开启自动重置后，CodexBar 通过同一个本机 app-server 使用明确列出的临期重置次数。原始 `creditId` 和幂等键不写入磁盘或 CloudKit；`UserDefaults` 只保存功能开关、提前量、自动重置通知开关、音效选择和哈希后的通知去重键。

CodexBar 不复制或持久化 Codex 认证 token。

## 网络行为

| 网络访问 | 目的 | 触发条件 |
| --- | --- | --- |
| Sparkle 更新源 | 检查并安装 CodexBar 更新 | 自动检查开启或用户手动检查时 |
| CloudKit private database | 同步多设备每日 Hook 聚合 | 用户开启跨设备同步时 |

账户、额度、Token 用量、手动重置次数明细和用户开启的自动重置操作通过本机 app-server 的 stdio 通信完成。自动重置不会增加 CloudKit 请求；自动重置只向 CodexBarHelper 提交固定系统唤醒计划的时间，不提交账户或重置次数数据。

## 日志隐私

系统日志只记录操作结果、状态分类、计数和错误阶段。

系统日志不应记录账户额度数值、Token 用量、项目名、任务内容、session ID、turn ID 或 OAuth token。

App 内 app-server 交互日志可能包含请求和响应内容，但只存在当前进程内存，只有用户主动打开日志窗口时才显示。

返回 [用户手册](README.md)

# 数据与隐私边界

简体中文 | [English](../en/DeveloperGuide/data-and-privacy.md)

## 原则

CodexBar 只读取实现账户展示、自动重置、Hook 统计、实时任务和防睡眠所需的数据：

- 原始数据能留在本机时不上传
- 可以保存聚合时不保存正文
- 可以保存哈希身份时不保存原始身份
- 数据源不可用时显式标记缺失

隐私边界不是一份静态字段黑名单，而是每条数据链路的架构约束。新字段即使技术上容易读取，也必须先回答“它是否是完成产品目标所必需的”。

## 数据分类模型

开发时把数据分成 4 类有助于决定存储和传播范围：

| 分类 | 示例 | 默认处理 |
| --- | --- | --- |
| 内容 | prompt, response, tool 参数和输出 | 不采集 |
| 身份和上下文 | session ID、完整路径、project 名 | 仅在必要链路最小化使用，上传前脱敏或删除 |
| 聚合指标 | 每日事件数、model 计数 | 可本地持久化，用户 opt-in 后上传规定字段 |

“只保存在本机”不等于没有隐私成本。本地日志、crash report、备份和同机其他进程仍可能扩大暴露面，所以不需要的数据应在解析入口就丢弃。

## 信任边界

```text
Codex hook stdin / rollout / app-server
                  |
                  v
          普通用户权限的 CodexBar
           |                    |
           v                    v
   CloudKit private DB     受限 XPC 接口
                                |
                                v
                       root CodexBarHelper
```

边界含义如下：

- Codex 输入文件和协议数据都视为外部输入，解码失败不能扩大成任意文件访问或命令执行
- CloudKit 是用户主动开启的远端边界，即使使用 private database 也只允许规定聚合字段
- root helper 是权限提升边界，接口能力必须比 App 业务能力更窄
- Debug 和 Release 是两个 App 身份，但部分本地文件有意共享，因此需要进程锁和兼容 schema

## 最小化发生在采集入口

只在上传时删除敏感字段不够，因为原始字段可能已经进入本地 JSONL、内存日志或错误信息。

CodexBar 的最小化顺序是：

1. Hook recorder 从 stdin 只提取白名单结构字段
2. rollout reader 使用最小 Codable 结构跳过正文
3. 聚合器把较老 identity 明细压成计数
4. sync model 再投影成 CloudKit 允许字段
5. 日志层只记录阶段、分类和非敏感计数

每一层都收窄一次数据形状，因此下游新增一个字段不能自动获得上游所有原文。

## 数据流总览

| 来源 | CodexBar 使用方式 | 是否持久化 | 是否上传 CloudKit |
| --- | --- | --- | --- |
| app-server 账户、额度和 Reset Credits | 主面板、通知判断和用户启用的自动重置 | 仅短期状态 | 否 |
| Hook 结构化事件 | 历史聚合和实时任务 | 是，最长 210 天 | 只上传日聚合 |
| rollout 生命周期 | terminal 和进展对账 | 不单独持久化 | 否 |
| App 设置 | 功能开关和阈值 | UserDefaults | 否 |
| Activity Protection | 异常会话恢复 | 哈希身份，最长 24 小时 | 否 |
| CodexBarHelper ownership | 系统睡眠恢复 | root 状态文件 | 否 |
| 自动重置唤醒计划 | 固定 owner、`wake` 类型和下一次时间 | 系统电源管理 | 否 |

### 为什么 3 条业务链路保持独立

app-server、Hook 历史和实时活动读取不同事实，具有不同的新鲜度与失败模式：

- app-server 失败不应让本地历史消失
- Hook 聚合维护失败不应冻结实时任务
- rollout 暂时不可用不应把额度标成错误
- CloudKit 失败不应阻断当前设备聚合

如果把它们压成一个“全局加载成功”状态，任一低敏感度或低优先级链路都会扩大另一条链路的数据访问和可用性影响面。

## 本地读取

### Codex app-server

App 通过本机 `codex app-server --listen stdio://` 获取账户、额度、token 用量、Reset Credits 明细和 Codex 配置。用户主动开启自动重置后，App 还会通过同一 stdio 会话调用 Reset Credit 消费方法。

CodexBar 不自行实现账户登录。app-server 是否访问 OpenAI 服务由 Codex CLI 的正常认证和协议行为决定。

CodexBar 只通过 stdio 与本机进程通信，不从 app-server 响应中复制认证材料。request log 保存规范化后的完整请求与响应 JSON，只存在当前 App 进程内存，不持久化。内容可能包含账户响应、opaque credit ID 和幂等键，不能把它当作脱敏摘要。

### Hook 事件

Hook 子进程从 stdin 提取：

- 时间和事件类型
- 工作目录
- tool, model 和 effort
- permission 和 reviewer
- session, turn 和 agent 身份

`transcript_path` 可用时，Hook 子进程还会从 rollout 第一条完整 `session_meta` 中提取并归一化来源，只持久化 `main`, `autoReview`, `auxiliary` 或 `unknown`。读取按 32 KiB 分块且总计不超过 256 KiB。

不把 prompt, response, tool 参数或 tool 输出写入 CodexBar Hook 文件。

工作目录只用于派生 project display name 和实时归属。原始 Hook JSONL 仍可能包含 `cwd`，因此它属于本地敏感上下文，受保留期和文件权限约束。rollout 路径、原始 source 和任意 subagent `other` 值不会持久化。CloudKit 只上传派生后的 project 名计数，并明确依赖用户 opt-in。

### Rollout 文件

Hook recorder 通过 `transcript_path` 读取当前 rollout，实时活动 reader 还会访问 `$CODEX_HOME/sessions` 和 `$CODEX_HOME/archived_sessions`

这些读取只解析来源分类、生命周期、时间、turn context, progress, effort 和 reviewer 等结构字段，不把对话正文复制到 CodexBar 存储或展示到 UI。

rollout reader 从文件尾部按预算扫描，一方面减少 I/O，另一方面降低无关历史内容进入进程内存的范围。解析 DTO 只声明所需字段，JSONDecoder 自动忽略其余内容。

这不是对 rollout 文件的完整隐私隔离，因为 reader 仍需打开原文件。因此如果未来加入全文搜索或 prompt 展示，应视为新的产品隐私能力，不能当作现有 reader 的自然扩展。

### Reset Credits 明细

`account/rateLimits/read` 在 app-server 响应中返回 Reset Credits 数量和可选明细。

- `availableCount` 是可用总数的权威值
- `credits == nil` 表示服务端只提供数量
- 空明细数组表示服务端已读取明细，但没有返回可用凭证
- 明细列表可能被截断，不能用数组长度覆盖总数
- 菜单和临期通知只使用仍为 `available` 且尚未过期的 `expiresAt`
- 自动重置只处理新鲜响应明确列出的 `available + codexRateLimits + expiresAt` 明细
- opaque credit ID 和确定性幂等键只存在于当前进程内存，包括 app-server 响应与缓存、额度快照、自动重置状态机和内存请求日志，不持久化或上传
- 自动重置通知写入 UserDefaults 的去重 key 只包含账户与 credit ID 的 SHA-256 组合，不保存原值

额度响应来自旧缓存时可以继续展示，但不能触发新的临期通知或消费操作。自动重置设置和调度状态不进入 CloudKit，Mac 之间只通过服务端消费接口的确定性幂等键收敛。

## 本地持久化

### App 用户目录

```text
~/Library/Application Support/CodexBar/
  HookEvents/
    events/YYYY-MM-DD.jsonl
    daily.jsonl
    maintenance.json
    stats.lock
    Sync/
  ActivityProtection/
    state.json
```

| 路径 | 内容 | 生命周期 |
| --- | --- | --- |
| `HookEvents/events` | 原始结构化 Hook 事件 | 210 天 |
| `HookEvents/daily.jsonl` | 日级聚合 | 210 天 |
| `HookEvents/maintenance.json` | 文件游标、generation 和维护状态 | 持续更新 |
| `HookEvents/Sync` | CloudKit 缓存和游标 | 同步状态有效期间 |
| `ActivityProtection/state.json` | 哈希任务身份和时间戳 | 最后进展后最长 24 小时 |

最近 3 天的日聚合可以保留 session 和 turn ID 明细用于准确去重。更早数据只保留计数。

3 天 identity 明细是精确去重与长期最小化之间的折中：

- 近期 Hook 文件仍可能补写或重复，需要 identity 集合正确合并
- 远期数据变化概率低，只保留总数可显著缩小长期身份暴露
- 压缩后不能从计数恢复 identity，因此算法变化统一从仍在 210 天保留期内的原始 JSONL 重建

原始事件和日聚合使用相同的 210 天上限，避免派生数据已经清理但更敏感的原始数据仍无限保留。

匿名任务不生成异常会话保护标识，因此不会写入 `ActivityProtection/state.json`

### UserDefaults

UserDefaults 保存：

- 功能开关和设置选项
- 通知阈值和声音名称
- 全局快捷键
- 菜单栏显示选择
- 自动重置开关和提前量
- 有界的通知去重 key
- CodexBarHelper fingerprint 等运行配置

持久化 key 改名、结构变化或默认值变化需要考虑旧版本升级行为。

UserDefaults 不是无 schema 存储。对已有 key 改名、枚举 raw value 变化或缺失默认值变化都会改变升级用户行为。这类修改属于兼容性问题，必须先确定迁移和降级策略。

### CodexBarHelper 目录

```text
/Library/Application Support/CodexBar/helper-state.json
```

文件只保存 CodexBarHelper 是否拥有 `SleepDisabled` 的恢复事务，不包含 Codex 任务、账户或 Hook 数据。

自动重置唤醒计划由系统电源管理保存，只包含 CodexBar 固定 owner、`wake` 类型和下一次时间。helper 不接收或保存账户、`creditId`、幂等键或网络数据。

目录和文件由 root 管理。详细权限和恢复策略见 [防睡眠系统](sleep-prevention.md)

## 内存日志和系统日志

App 内 [`RequestLog.swift`](../../CodexBar/Services/CodexStatus/RequestLog.swift) 是最多 500 条的内存 ring buffer，进程退出后消失。

请求日志用于诊断 app-server 协议。即使只存在内存，也不应写入 OAuth token 或 Hook 内容。

ring buffer 的 500 条上限既控制内存，也限制打开日志窗口时的渲染成本。它不是审计日志，不能承担跨启动问题追踪。需要跨启动诊断时使用统一系统日志，仍需遵守相同字段边界。

统一系统日志 subsystem 为 `app.zabrian.codexbar`，Debug 版本带 `.debug` 后缀。

系统日志只应记录：

- 操作阶段和结果
- 状态分类
- 不敏感计数
- 可定位模块的错误信息

系统日志不应记录：

- OAuth token
- prompt, response 或 tool 内容
- session ID, turn ID 或 agent ID
- 完整项目路径或敏感项目名
- 账户额度和 token 用量明细

## 网络访问

| 目标 | 用途 | 触发条件 |
| --- | --- | --- |
| CloudKit private database | 同步日级 Hook 聚合 | 用户主动开启同步 |
| Sparkle appcast 和更新资源 | 检查或安装更新 | 自动检查或用户手动检查 |

账户、额度、token 用量、Reset Credits 明细和用户明确开启的 Reset Credit 消费通过本机 app-server stdio 完成。CodexBar 不为自动重置增加独立 HTTP 客户端。

CodexBarHelper 不进行任何网络访问。

## CloudKit 边界

CloudKit 只上传日级聚合字段：

- 设备 pseudonym
- 日期和 source generation
- Hook 事件计数
- session 和 turn 计数
- project 显示名计数
- model 计数
- 更新时间

CloudKit 不上传：

- 原始 Hook JSONL
- session, turn 或 agent ID
- 完整工作目录
- prompt, response, tool 参数或输出
- Codex 账户、额度和 token 用量
- Reset Credits 明细、自动重置设置和消费状态
- access token
- App 请求日志
- Activity Protection 状态

project 显示名可能由目录名派生，仍可能包含用户敏感信息。同步开关必须保持用户主动选择。

HMAC 设备 pseudonym 只降低硬件身份关联，不会自动匿名化 project 名。private database 也不等于“数据不离开设备”。因此设置文案和开发文档都必须继续说明同步内容，不能因为 CloudKit 属于用户账户就改成默认开启。

## root helper 的数据隔离

CodexBarHelper 只需要知道 4 类状态：

- 哪个已验证客户端持有哪一代 lease
- `SleepDisabled` 当前实测值
- CodexBar 是否拥有恢复责任
- 自动重置唤醒计划的有限 Unix 时间戳和当前连接所有者

它不需要 task ID、project 名、Hook 路径、账户状态、`creditId` 或用户设置全文。XPC 只传布尔请求、client session ID、generation、update identifier 和有限 Unix 时间戳。

这种能力最小化意味着即使普通 App 层以后新增网络或数据功能，root 进程也不会自动获得这些能力。不应为了复用文件读取或网络代码把业务 service 链接进 helper。

helper 的 ownership 文件不是用户偏好，而是 crash recovery 事务记录。它必须由 root 拥有，拒绝 group 或 world 可写目录，并通过 full sync 加原子 rename 确保重启后能判断是否需要恢复。

## 文件安全

- Hook 子进程和 App 聚合器通过 `flock` 协调写入
- JSONL 只追加完整行
- 聚合和状态文件使用可恢复写入流程
- Activity Protection 文件权限为 `0600`
- CodexBarHelper 状态通过 root owner、权限检查、full sync 和原子 rename 提交
- Debug 和 Release 共享的数据必须使用锁和兼容 schema

## 缺失、陈旧和不可用的隐私含义

数据不可用时不能用看似友好的默认值掩盖：

| 状态 | 正确表达 | 错误做法 |
| --- | --- | --- |
| 字段从旧来源缺失 | `nil` 或 unavailable | 解码成明确的 0 |
| app-server 缓存过期 | stale 快照 | 继续触发通知 |
| rollout reader 不可用 | 暂停实时判定 | 使用旧任务继续防睡眠 |
| CloudKit 离线 | 保留带来源的旧 cache | 当作当前账户新数据 |
| 电池读取失败 | 保留上次判定并标记 unreadable | 当作没有电池 |

显式降级不仅提升正确性，也避免为了填满 UI 而读取更多备用来源或保存额外数据。

## 新增数据字段前的审查清单

1. 写明产品目标以及没有该字段时无法完成的行为
2. 确认字段属于凭据、内容、身份上下文还是聚合指标
3. 定义采集入口和最早可以丢弃原文的层
4. 明确内存、UserDefaults, Application Support, system log 和 CloudKit 中的存在范围
5. 定义保留期、删除触发和失败后的清理行为
6. 检查 Debug 与 Release 是否共享文件或 identity
7. 检查字段缺失与明确空值的区别
8. 检查日志和错误对象是否会间接复制原文
9. 如涉及 CloudKit、网络或日志数据，先更新隐私说明并取得明确产品决策
10. 如涉及 schema 或旧版本共存，先确认兼容方案再改代码

## 建议的隐私故障验证

- 用包含明显标记字符串的 prompt 和 tool 参数运行任务，确认 Hook JSONL、App 日志和 CloudKit cache 均没有该字符串
- 让项目目录名包含敏感测试词，确认它只出现在允许的本地展示和 opt-in 聚合字段
- 模拟 Reset Credits 请求失败，确认 access token 不出现在内存日志和 unified log
- 检查 CloudKit record 不包含 session, turn, agent ID 或完整路径
- 以非 root 用户验证 helper 状态目录不可写
- 损坏各类缓存文件，确认系统降级或重建，而不是扩大到备用数据采集

## 关键源码

- [`WorkflowHookEventRecorder.swift`](../../CodexBar/Services/Workflow/WorkflowHookEventRecorder.swift)
- [`WorkflowService.swift`](../../CodexBar/Services/Workflow/WorkflowService.swift)
- [`CodexSessionLifecycleReader.swift`](../../CodexBar/Services/Workflow/CodexSessionLifecycleReader.swift)
- [`WorkflowSyncService.swift`](../../CodexBar/Services/Workflow/WorkflowSyncService.swift)
- [`ActivityProtectionStateStore.swift`](../../CodexBar/Services/Workflow/ActivityProtectionStateStore.swift)
- [`RequestLog.swift`](../../CodexBar/Services/CodexStatus/RequestLog.swift)
- [`CodexBarHelper/main.swift`](../../CodexBarHelper/main.swift)

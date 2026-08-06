# 数据与隐私边界

## 原则

CodexBar 只读取实现账户展示，Hook 统计，实时任务和防睡眠所需的数据：

- 原始数据能留在本机时不上传
- 可以保存聚合时不保存正文
- 可以保存哈希身份时不保存原始身份
- 数据源不可用时显式标记缺失

## 数据流总览

| 来源 | CodexBar 使用方式 | 是否持久化 | 是否上传 CloudKit |
| --- | --- | --- | --- |
| app-server 账户和额度 | 主面板和通知判断 | 仅设置和短期状态 | 否 |
| Hook 结构化事件 | 历史聚合和实时任务 | 是，最长 210 天 | 只上传日聚合 |
| rollout 生命周期 | terminal 和进展对账 | 不单独持久化 | 否 |
| `auth.json` token | 查询 Reset Credits 到期时间 | 不复制 | 否 |
| App 设置 | 功能开关和阈值 | UserDefaults | 否 |
| Activity Protection | 异常会话恢复 | 哈希身份，最长 24 小时 | 否 |
| CodexBarHelper ownership | 系统睡眠恢复 | root 状态文件 | 否 |

## 本地读取

### Codex app-server

App 通过本机 `codex app-server --listen stdio://` 获取账户，额度，token 用量和 Codex 配置。

CodexBar 不自行实现账户登录。app-server 是否访问 OpenAI 服务由 Codex CLI 的正常认证和协议行为决定。

### Hook 事件

Hook 子进程从 stdin 提取：

- 时间和事件类型
- 工作目录
- tool，model 和 effort
- permission 和 reviewer
- session，turn 和 agent 身份

不把 prompt，response，tool 参数或 tool 输出写入 CodexBar Hook 文件。

### Rollout 文件

实时活动 reader 会访问 `$CODEX_HOME/sessions` 和 `$CODEX_HOME/archived_sessions`

它只解析生命周期，时间，turn context，progress，effort 和 reviewer 等结构字段。不把对话正文复制到 CodexBar 存储或展示到 UI。

### Codex 凭据

Reset Credits 数量大于 `0` 时，App 读取现有 `auth.json` access token，只用于调用到期时间接口：

- 不修改 `auth.json`
- 不保存 token 副本
- 不把 token 写入 UserDefaults，Hook 文件，CloudKit 或日志
- 请求结束后只保留解析出的业务结果

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
| `HookEvents/maintenance.json` | 文件游标，generation 和维护状态 | 持续更新 |
| `HookEvents/Sync` | CloudKit 缓存和游标 | 同步状态有效期间 |
| `ActivityProtection/state.json` | 哈希任务身份和时间戳 | 最后进展后最长 24 小时 |

最近 3 天的日聚合可以保留 session 和 turn ID 明细用于准确去重。更早数据只保留计数。

### UserDefaults

UserDefaults 保存：

- 功能开关和设置选项
- 通知阈值和声音名称
- 全局快捷键
- 菜单栏显示选择
- 有界的通知去重 key
- CodexBarHelper fingerprint 等运行配置

持久化 key 改名，结构变化或默认值变化需要考虑旧版本升级行为。

### CodexBarHelper 目录

```text
/Library/Application Support/CodexBar/helper-state.json
```

文件只保存 CodexBarHelper 是否拥有 `SleepDisabled` 的恢复事务，不包含 Codex 任务，账户或 Hook 数据。

目录和文件由 root 管理。详细权限和恢复策略见 [防睡眠系统](sleep-prevention.md)

## 内存日志和系统日志

App 内 [`RequestLog.swift`](../../CodexBar/Services/CodexStatus/RequestLog.swift) 是最多 500 条的内存 ring buffer，进程退出后消失。

请求日志用于诊断 app-server 协议。即使只存在内存，也不应写入 OAuth token 或 Hook 内容。

统一系统日志 subsystem 为 `app.zabrian.codexbar`，Debug 版本带 `.debug` 后缀。

系统日志只应记录：

- 操作阶段和结果
- 状态分类
- 不敏感计数
- 可定位模块的错误信息

系统日志不应记录：

- OAuth token
- prompt，response 或 tool 内容
- session ID，turn ID 或 agent ID
- 完整项目路径或敏感项目名
- 账户额度和 token 用量明细

## 网络访问

| 目标 | 用途 | 触发条件 |
| --- | --- | --- |
| OpenAI Reset Credits endpoint | 查询手动重置次数到期时间 | 可用数量大于 `0` |
| CloudKit private database | 同步日级 Hook 聚合 | 用户主动开启同步 |
| Sparkle appcast 和更新资源 | 检查或安装更新 | 自动检查或用户手动检查 |

账户，额度和 token 用量通过本机 app-server stdio 获取，CodexBar 不直接请求对应账户 API。

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
- session，turn 或 agent ID
- 完整工作目录
- prompt，response，tool 参数或输出
- Codex 账户，额度和 token 用量
- access token
- App 请求日志
- Activity Protection 状态

project 显示名可能由目录名派生，仍可能包含用户敏感信息。同步开关必须保持用户主动选择。

## 文件安全

- Hook 子进程和 App 聚合器通过 `flock` 协调写入
- JSONL 只追加完整行
- 聚合和状态文件使用可恢复写入流程
- Activity Protection 文件权限为 `0600`
- CodexBarHelper 状态通过 root owner，权限检查，full sync 和原子 rename 提交
- Debug 和 Release 共享的数据必须使用锁和兼容 schema

## 关键源码

- [`WorkflowHookEventRecorder.swift`](../../CodexBar/Services/Workflow/WorkflowHookEventRecorder.swift)
- [`WorkflowService.swift`](../../CodexBar/Services/Workflow/WorkflowService.swift)
- [`CodexSessionLifecycleReader.swift`](../../CodexBar/Services/Workflow/CodexSessionLifecycleReader.swift)
- [`WorkflowSyncService.swift`](../../CodexBar/Services/Workflow/WorkflowSyncService.swift)
- [`ActivityProtectionStateStore.swift`](../../CodexBar/Services/Workflow/ActivityProtectionStateStore.swift)
- [`RequestLog.swift`](../../CodexBar/Services/CodexStatus/RequestLog.swift)
- [`CodexBarHelper/main.swift`](../../CodexBarHelper/main.swift)

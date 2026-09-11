# 整体架构

简体中文 | [English](../en/DeveloperGuide/architecture.md)

进程、数据链路与恢复路径的交互式总览见[运行架构](https://codexbar.zabrian.app/architecture)

## 技术基线

CodexBar 是 macOS 15+ 菜单栏应用，使用 Swift 6, SwiftUI, AppKit 和 MVVM。

工程只有 `CodexBar` scheme，包含两个 target：

| Target | 职责 |
| --- | --- |
| `CodexBar` | 菜单栏 UI、Codex 数据采集、自动重置、通知、同步和系统电源编排 |
| `CodexBarHelper` | 以 root LaunchDaemon 运行，负责固定的系统睡眠开关和自动重置唤醒计划 |

两个 target 通过 [`CodexBarHelperXPC.swift`](../../Shared/CodexBarHelperXPC.swift) 共享 XPC 协议。

App 使用 Sparkle 检查更新。工程默认启用 `MainActor` 隔离，Debug 和 Release 使用不同的 App 与 CodexBarHelper bundle ID。

## 进程与信任边界

```text
Codex
  | 启动 --hook-event 子进程, 通过 stdin 传入事件
  v
CodexBar executable
  |-- Hook 模式: 最小解析 + flock + JSONL append + exit
  |
  `-- 普通模式
       |-- stdio JSON-RPC <-> codex app-server（账户、额度、Reset Credits）
       |-- 本地只读 <-> Hook JSONL / rollout JSONL
       |-- HTTPS <-> Sparkle
       |-- CloudKit private database <-> 日级聚合
       `-- signed XPC lease / wake date <-> root CodexBarHelper
              |-- fixed pmset commands
              `-- fixed IOPM wake event
```

边界设计有两个关键点：

- 同一个可执行文件承载 Hook 模式可以让 handler 始终指向当前 App 版本，不需要额外部署采集工具
- root helper 不知道 Codex 任务、账户或重置凭证，只接收经过签名校验的睡眠租约和自动重置唤醒时间

### 进程生命周期差异

| 进程 | 生命周期 | 可以做什么 | 不能做什么 |
| --- | --- | --- | --- |
| Hook 子进程 | 单个事件，最长几秒 | 读取 stdin、提取最小字段、追加本地 JSONL | 初始化 UI、建立网络连接、等待长期服务 |
| 主 App | 用户登录会话内长期运行 | 编排 UI、数据链路和副作用 | 直接以 root 修改系统设置 |
| app-server | 达到 1 小时后的下一次请求重建 | 通过 JSON-RPC 提供账户和配置能力 | 成为 Hook 历史或实时任务的替代来源 |
| CodexBarHelper | LaunchDaemon | 执行固定 `pmset` 操作、管理固定 owner 的 `wake` 事件并恢复系统状态 | 访问账户、Hook、rollout、网络或任意命令 |

## 目录职责

```text
CodexBar/
  App/             App 入口
  Controllers/     AppKit 窗口, 菜单栏和面板控制器
  Models/          DTO, 状态快照和展示模型
  Services/        数据获取, 状态机, 设置, 通知和系统服务
  Views/           SwiftUI 视图
  Resources/       Info.plist, entitlement, 本地化和声音资源
CodexBarHelper/     root LaunchDaemon
Shared/             跨 target XPC 接口
Config/             版本配置
Scripts/            构建, DMG, appcast 和 CodexBarHelper 清理脚本
```

## 启动顺序

[`CodexBarApp.swift`](../../CodexBar/App/CodexBarApp.swift) 按以下顺序分流启动：

```text
进程启动
  -> WorkflowHookEventRecorder.handleIfRequested()
      -> 命中 --hook-event 时读取 stdin, 写入 JSONL, 立即退出
      -> 普通启动时继续
  -> 创建 CodexBarAppDelegate
  -> AppDelegate 装配长期服务
  -> 创建菜单栏和辅助窗口
  -> 启动刷新、活动监控、自动重置、通知和系统电源协调
```

`--hook-event` 是 Codex 调用的短命子进程模式。它必须在任何 UI、CloudKit、通知或长期服务初始化之前完成。采集失败也不能阻断 Codex 主流程。

普通模式由 `CodexBarAppDelegate` 统一创建和持有长期对象，主要包括：

- `CodexStatusService` 和 `CodexStatusViewModel`
- `CodexProxySettings`
- `WorkflowService` 和对应 ViewModel
- `CodexHookSettings`
- `CodexActivityMonitor`
- `KeepAliveController`
- `AutoResetController`
- `WorkflowSyncSettings` 和同步调度器
- `CodexNotificationService`
- 菜单栏、快捷键、设置窗口和更新服务

App 退出时需要先取消自动重置唤醒计划并释放防睡眠状态。如果 CodexBarHelper 尚未回读确认两类系统状态都已恢复，终止流程会等待或取消退出。helper 启动时还会在接受新连接前清除固定 owner 的遗留唤醒事件，用于收敛突然断电或强制终止留下的状态。

### Hook 启动分流

`@NSApplicationDelegateAdaptor` 会把 AppKit 生命周期接入 SwiftUI App。一旦普通生命周期开始，可能创建菜单栏对象、注册通知 delegate 或访问 CloudKit。

Hook handler 在 Codex 的关键路径上，它需要的是接近命令行工具的行为。因此 `WorkflowHookEventRecorder.handleIfRequested()` 必须在 `CodexBarApp.init()` 的第一段执行，命中后直接 `exit(EXIT_SUCCESS)`

这个顺序还保证 Hook 采集失败不会污染正常退出诊断。`AppProcessDiagnostics.install()` 只在 `applicationDidFinishLaunching` 中执行，Hook 子进程不会被误记为一次异常退出的完整 App。

### 退出协调

`applicationShouldTerminate` 先调用 `KeepAliveController.prepareForTermination()` 并返回 `.terminateLater`

如果 helper 明确确认自动重置唤醒事件已经取消且防睡眠 release 已完成，App 再回复允许退出。任一清理失败时，本次退出被取消，controller 回到正常协调状态并继续按当前设置运行。

直接在 `applicationWillTerminate` 中异步释放已经太晚，因为该回调不能可靠延长进程寿命。

## 3 条独立数据链路

三条数据链路分别管理不同的输入、时效和失败状态：

| 链路 | 输入 | 输出 | 主要消费者 |
| --- | --- | --- | --- |
| app-server | `codex app-server` JSON-RPC | 账户、额度、token 用量、Reset Credit 使用、Hook 配置能力 | 主面板、菜单栏额度、设置、自动重置状态机 |
| Hook 历史 | Hook JSONL | 日级事件、session, turn, tool, model 聚合 | 活跃度热力图、历史统计、CloudKit |
| 实时任务 | Hook 增量事件加 rollout 生命周期 | 运行、等待批准、完成、中断 | 菜单栏状态、任务中心、通知、防睡眠 |

### 依赖方向

```text
CodexStatusService ----------------> CodexStatusViewModel ----------------> UI
CodexStatusViewModel --------------> CodexNotificationService
CodexStatusService ----------------> AutoResetController
CodexStatusViewModel --------------> AutoResetController
AutoResetController ---------------> CodexNotificationService
AutoResetController ---------------> KeepAliveController ---> AutoResetWakeScheduler ---> helper

WorkflowService -------> WorkflowViewModel -----------> UI

Hook + rollout --------> CodexActivityMonitor --------> UI
                              |          |
                              |          +------------> CodexNotificationService
                              `-----------------------> KeepAliveController --> helper
```

箭头表示数据或只读状态的消费方向。下游不能反向成为上游的事实来源。

### 共享刷新触发

历史维护默认挂在 60 秒额度刷新完成事件上，这是为了减少常驻 timer 和日志噪音。两条链路共享调度时机，但没有共享事实。

因此修改刷新节奏时需要区分：

- 触发来源可以调整
- 维护任务仍必须在 app-server 失败时具备独立执行能力
- UI 打开时的轻量统计刷新不能隐式发起 CloudKit 网络操作

## 并发边界

工程启用 Swift 6 严格并发和默认 `MainActor` 隔离。

### MainActor 对象

- SwiftUI ViewModel 和 Settings
- AppKit Controller
- `CodexActivityMonitor`
- `KeepAliveController`
- `CodexNotificationService`
- `AutoResetController`
- `AutoResetWakeScheduler`

这些对象负责可观察状态和 UI 协调，不应直接执行阻塞 I/O。

### Actor 服务

- `CodexStatusService` 管理 app-server 连接和刷新
- `WorkflowService` 管理历史聚合
- `HookEventTailReader` 管理 Hook 文件游标
- `CodexSessionLifecycleReader` 管理 rollout 文件游标
- `WorkflowSyncService` 管理 CloudKit 状态
- `ActivityProtectionStateStore` 管理跨进程保护记录

跨 actor 传递的 DTO 必须是不可变值类型，并按需要声明 `Sendable` 或 `nonisolated`

### Monitor 的 MainActor 边界

`CodexActivityMonitor` 的输入读取在 actor 中完成，但状态机本身与多个 Combine 消费者紧密相连。

把 monitor 放在 `MainActor` 有以下收益：

- `@Published snapshot` 和 transition 发布顺序天然串行
- 通知与防睡眠消费者看到相同的状态提交顺序
- App 睡眠、唤醒和 Hook 设置变化可以与 UI 生命周期统一排序

前提是 monitor 不能直接执行阻塞文件读取。`HookEventTailReader`, `CodexSessionLifecycleReader` 和 `ActivityProtectionStateStore` 各自承担 I/O 边界。

## 模型分层

模型按外部输入、持久化、领域状态和展示职责分层：

| 模型类型 | 作用 | 设计要求 |
| --- | --- | --- |
| 外部 DTO | 解码 app-server, Hook, rollout 或 CloudKit | 宽容版本差异，不承载 UI 副作用 |
| 持久化模型 | 保存可恢复状态和 schema | 兼容旧值，明确 missing 语义 |
| 领域快照 | 向消费者表达当前可信状态 | 不可变、可比较、跨 actor 安全 |
| transition | 表达一次 live 状态变化 | 不从历史快照反推，需要上游去重 |
| 展示格式 | 日期、百分比、文案和颜色 | 按各展示字段的地区设置或固定格式输出，不参与业务判定 |

例如 `CodexQuotaSnapshot` 可以同时携带当前值和 stale 标记。`CodexActivitySnapshot` 只保存展示需要的任务字段，原始 session ID 不进入 View。

## 生命周期与保留时间

各类状态的生命周期如下：

| 状态 | 生命周期 | 原因 |
| --- | --- | --- |
| app-server connection | 请求时检查 1 小时复用上限 | 后续请求重建连接时使用磁盘上的 binary |
| app-server supplemental cache | 当前账户内 | 避免跨账户串值 |
| Hook live bootstrap window | 24 小时 | 覆盖可能仍在运行的长任务 |
| 菜单栏完成或终止提示 | 10 秒 | 最新终态的短时反馈 |
| 任务中心 terminal 历史 | 10 分钟 | 提供近期上下文但不长期占用 UI |
| terminal 去重记忆 | 24 小时 | 防止迟到 Hook 或 rollout 复活旧任务 |
| Hook 原始和日聚合 | 210 天 | 支持长期统计和重建 |
| 日聚合身份明细 | 3 天 | 近期精确去重与隐私、文件体积折中 |
| Activity Protection 记录 | 最后进展后 24 小时 | 跨重启保持抑制，同时限制身份留存 |

修改其中一个时间窗口时，要先确认是否存在配对不变量。例如 tail reader bootstrap 窗口必须和活动任务保留窗口一致。

## 状态所有权

| 状态 | 唯一所有者 | 其他模块的权限 |
| --- | --- | --- |
| app-server 连接与同账户缓存 | `CodexStatusService` | 通过服务方法读取数据、修改配置或重连 |
| 代理草稿、测试和开关交互 | `CodexProxySettings` | 设置页通过方法提交，`CodexStatusService` 应用正式连接配置 |
| 主面板账户加载状态 | `CodexStatusViewModel` | 观察发布值 |
| 自动重置的目标、deadline 和重试 | `AutoResetController` | 设置页只修改开关和提前量 |
| 自动重置唤醒时间同步 | `AutoResetWakeScheduler` | `AutoResetController` 只提交下一次时间，`KeepAliveController` 只提交 helper 就绪状态 |
| Hook 安装与验证 | `CodexHookSettings` | 读取 `isOperable` |
| 历史聚合和维护游标 | `WorkflowService` | 请求快照或重建 |
| 实时任务 | `CodexActivityMonitor` | 读取 snapshot 或 transition |
| 同步游标与远端缓存 | `WorkflowSyncService` | 请求合并快照 |
| 防睡眠策略与 App assertion | `KeepAliveController` | 读取派生状态或调用设置入口 |
| root 睡眠所有权 | `CodexBarHelper` | 通过 XPC 请求和查询 |
| root 自动重置唤醒事件 | `CodexBarHelper` | 通过 XPC 替换或取消固定 owner 的单个 `wake` 事件 |
| 通知去重 | `CodexNotificationService` | 上游只发布候选事件 |

新增消费者时，优先订阅已有快照。如果现有快照缺字段，应在状态所有者处扩展稳定值类型，不应让消费者重新读取原始文件。

## 错误和降级原则

- 短暂网络或 RPC 失败优先保留上一次可解释的状态
- 数据源不可用必须显式表达，不能伪装为空数据
- bootstrap 阶段只建立基线，不发送历史状态变化通知
- reader 更换或数据源代际变化时丢弃旧异步结果
- 恢复流程必须完成新的读取屏障后才能继续判定
- 持久化文件写入需要原子替换或文件锁，避免 Debug 与 Release 并发破坏

### 错误分类

| 错误类别 | 典型处理 | 不应采取的处理 |
| --- | --- | --- |
| 明确业务不支持 | 缓存 method unsupported，显示来源缺失 | 每分钟重复请求或展示 `0` |
| 短暂业务失败 | 同账户范围内使用 stale 缓存 | 清空整个账户快照 |
| transport 失败 | 丢弃连接，最多重建一次 | 在不可信 pipe 上继续请求 |
| 数据源身份变化 | 新 generation，从原始来源重建 | 沿用旧 offset 继续追加 |
| 迟到异步结果 | generation 不匹配时丢弃 | 覆盖新设置或新 reader 状态 |
| 特权状态不确定 | 保留可能租约或唤醒事件并主动确认清理 | 假定 helper 没有执行 |
| Hook recorder 失败 | 吞掉本次采集并退出成功 | 阻断 Codex 或弹 UI |

## 系统集成

| 能力 | 系统接口 |
| --- | --- |
| 菜单栏 | `NSStatusItem` |
| 主面板 | `NSPopover` 和浮动备用面板 |
| 全局快捷键 | Carbon Hot Key API |
| App 防空闲睡眠 | IOKit power assertion |
| 系统睡眠控制 | CodexBarHelper 调用固定参数的 `/usr/bin/pmset` |
| 自动重置系统唤醒 | CodexBarHelper 调用 `IOPMSchedulePowerEvent` 和 `IOPMCancelScheduledPowerEvent` |
| CodexBarHelper 安装和启动 | `SMAppService` |
| App 与 CodexBarHelper 通信 | XPC |
| 通知 | `UNUserNotificationCenter` |
| 云同步 | CloudKit private database |
| 自动更新 | Sparkle |

## 关键源码

- [`CodexBarApp.swift`](../../CodexBar/App/CodexBarApp.swift) 定义启动入口
- [`CodexBarAppDelegate.swift`](../../CodexBar/Controllers/CodexBarAppDelegate.swift) 负责普通模式服务装配
- [`StatusItemController.swift`](../../CodexBar/Controllers/StatusItemController.swift) 负责菜单栏编排
- [`CodexStatusService.swift`](../../CodexBar/Services/CodexStatus/CodexStatusService.swift) 管理 app-server
- [`WorkflowService.swift`](../../CodexBar/Services/Workflow/WorkflowService.swift) 管理 Hook 历史聚合
- [`CodexActivityMonitor.swift`](../../CodexBar/Services/Workflow/CodexActivityMonitor.swift) 管理实时任务
- [`AutoResetController.swift`](../../CodexBar/Services/CodexStatus/AutoResetController.swift) 管理自动重置目标和重试
- [`AutoResetWakeScheduler.swift`](../../CodexBar/Services/KeepAlive/AutoResetWakeScheduler.swift) 同步下一次系统唤醒时间
- [`KeepAliveController.swift`](../../CodexBar/Services/KeepAlive/KeepAliveController.swift) 管理 helper 注册、防睡眠策略和唤醒调度就绪状态
- [`WorkflowSyncService.swift`](../../CodexBar/Services/Workflow/WorkflowSyncService.swift) 管理 CloudKit 同步
- [`CodexBarHelperXPC.swift`](../../Shared/CodexBarHelperXPC.swift) 定义受限特权接口
- [`CodexBarHelper/main.swift`](../../CodexBarHelper/main.swift) 执行并验证系统睡眠与唤醒操作

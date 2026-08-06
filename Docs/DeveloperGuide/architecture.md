# 整体架构

## 技术基线

CodexBar 是 macOS 15+ 菜单栏应用，使用 Swift 6，SwiftUI，AppKit 和 MVVM。

工程只有 `CodexBar` scheme，包含两个 target：

| Target | 职责 |
| --- | --- |
| `CodexBar` | 菜单栏 UI，Codex 数据采集，通知，同步和防睡眠编排 |
| `CodexBarHelper` | 以 root LaunchDaemon 运行，仅负责系统睡眠开关 |

两个 target 通过 [`CodexBarHelperXPC.swift`](../../Shared/CodexBarHelperXPC.swift) 共享 XPC 协议。

App 使用 Sparkle 检查更新。工程默认启用 `MainActor` 隔离，Debug 和 Release 使用不同的 App 与 CodexBarHelper bundle ID。

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

[`CodexBarApp.swift`](../../CodexBar/App/CodexBarApp.swift) 的初始化顺序是架构约束，不是实现细节：

```text
进程启动
  -> WorkflowHookEventRecorder.handleIfRequested()
      -> 命中 --hook-event 时读取 stdin, 写入 JSONL, 立即退出
      -> 普通启动时继续
  -> 创建 CodexBarAppDelegate
  -> AppDelegate 装配长期服务
  -> 创建菜单栏和辅助窗口
  -> 启动刷新, 活动监控, 通知和防睡眠协调
```

`--hook-event` 是 Codex 调用的短命子进程模式。它必须在任何 UI，CloudKit，通知或长期服务初始化之前完成。采集失败也不能阻断 Codex 主流程。

普通模式由 `CodexBarAppDelegate` 统一创建和持有长期对象，主要包括：

- `CodexStatusService` 和 `CodexStatusViewModel`
- `WorkflowService` 和对应 ViewModel
- `CodexHookSettings`
- `CodexActivityMonitor`
- `KeepAliveController`
- `WorkflowSyncSettings` 和同步调度器
- `CodexNotificationService`
- 菜单栏，快捷键，设置窗口和更新服务

App 退出时需要先释放防睡眠状态。如果 CodexBarHelper 尚未确认恢复，终止流程会等待或取消退出，避免遗留系统级睡眠状态。

## 3 条独立数据链路

CodexBar 不使用一个聚合服务承载所有状态。3 条链路的输入，时效和失败语义不同：

| 链路 | 输入 | 输出 | 主要消费者 |
| --- | --- | --- | --- |
| app-server | `codex app-server` JSON-RPC | 账户，额度，token 用量，Hook 配置能力 | 主面板，菜单栏额度，设置 |
| Hook 历史 | Hook JSONL | 日级事件，session，turn，tool，model 聚合 | 活跃度热力图，历史统计，CloudKit |
| 实时任务 | Hook 增量事件加 rollout 生命周期 | 运行，等待批准，完成，中断 | 菜单栏状态，任务中心，通知，防睡眠 |

链路之间可以共享基础设施和模型，但不能互相替代：

- app-server 不提供完整的实时任务状态
- 历史聚合允许延迟和重建，实时任务不能等待聚合完成
- 实时任务快照不可作为历史统计的持久来源
- 某条链路不可用时，其他链路仍应保持可用

## 并发边界

工程启用 Swift 6 严格并发和默认 `MainActor` 隔离。

### MainActor 对象

- SwiftUI ViewModel 和 Settings
- AppKit Controller
- `CodexActivityMonitor`
- `KeepAliveController`
- `CodexNotificationService`

这些对象负责可观察状态和 UI 协调，不应直接执行阻塞 I/O。

### Actor 服务

- `CodexStatusService` 管理 app-server 连接和刷新
- `WorkflowService` 管理历史聚合
- `HookEventTailReader` 管理 Hook 文件游标
- `CodexSessionLifecycleReader` 管理 rollout 文件游标
- `WorkflowSyncService` 管理 CloudKit 状态
- `ActivityProtectionStateStore` 管理跨进程保护记录

跨 actor 传递的 DTO 必须是不可变值类型，并按需要声明 `Sendable` 或 `nonisolated`

## 状态所有权

实时任务状态只有一个权威来源，即 [`CodexActivityMonitor.swift`](../../CodexBar/Services/Workflow/CodexActivityMonitor.swift)

它的快照被以下模块消费：

- 菜单栏图标和主面板任务卡片
- 活动中心
- 完成和等待批准通知
- 防睡眠是否存在有效任务的判断
- 异常会话保护

消费者只能基于快照展示或执行副作用，不能各自重建一套任务状态机。

## 错误和降级原则

- 短暂网络或 RPC 失败优先保留上一次可解释的状态
- 数据源不可用必须显式表达，不能伪装为空数据
- bootstrap 阶段只建立基线，不发送历史状态变化通知
- reader 更换或数据源代际变化时丢弃旧异步结果
- 恢复流程必须完成新的读取屏障后才能继续判定
- 持久化文件写入需要原子替换或文件锁，避免 Debug 与 Release 并发破坏

## 系统集成

| 能力 | 系统接口 |
| --- | --- |
| 菜单栏 | `NSStatusItem` |
| 主面板 | `NSPopover` 和浮动备用面板 |
| 全局快捷键 | Carbon Hot Key API |
| App 防空闲睡眠 | IOKit power assertion |
| 系统睡眠控制 | CodexBarHelper 调用固定参数的 `/usr/bin/pmset` |
| CodexBarHelper 安装和启动 | `SMAppService` |
| App 与 CodexBarHelper 通信 | XPC |
| 通知 | `UNUserNotificationCenter` |
| 云同步 | CloudKit private database |
| 自动更新 | Sparkle |

## 关键源码

- [`CodexBarApp.swift`](../../CodexBar/App/CodexBarApp.swift) 定义启动入口
- [`StatusItemController.swift`](../../CodexBar/Controllers/StatusItemController.swift) 包含 AppDelegate 和菜单栏编排
- [`CodexStatusService.swift`](../../CodexBar/Services/CodexStatus/CodexStatusService.swift) 管理 app-server
- [`WorkflowService.swift`](../../CodexBar/Services/Workflow/WorkflowService.swift) 管理 Hook 历史聚合
- [`CodexActivityMonitor.swift`](../../CodexBar/Services/Workflow/CodexActivityMonitor.swift) 管理实时任务
- [`KeepAliveController.swift`](../../CodexBar/Services/KeepAlive/KeepAliveController.swift) 管理防睡眠策略
- [`WorkflowSyncService.swift`](../../CodexBar/Services/Workflow/WorkflowSyncService.swift) 管理 CloudKit 同步

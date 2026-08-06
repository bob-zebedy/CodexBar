# CodexBar 开发者指南

本指南面向希望理解 CodexBar 架构，调试数据链路或参与开发的开发者。

内容覆盖 CodexBar 的架构，数据链路，核心状态机和系统集成。产品功能和操作方式见 [用户指南](../UserGuide/README.md)

## 阅读路线

第一次了解项目时，建议按以下顺序阅读：

1. [整体架构](architecture.md)
2. [app-server 数据链路](app-server.md)
3. [Hook 采集与历史聚合](hook-and-aggregation.md)
4. [实时任务监控](activity-monitor.md)
5. [防睡眠系统](sleep-prevention.md)
6. [CloudKit 同步](sync.md)

## 按职责查找

| 文档 | 内容 |
| --- | --- |
| [整体架构](architecture.md) | 进程，模块，生命周期，actor 边界和 3 条数据链路 |
| [app-server 数据链路](app-server.md) | CLI 定位，JSON-RPC 会话，账户，额度和用量刷新 |
| [Hook 采集与历史聚合](hook-and-aggregation.md) | Hook 安装，事件落盘，聚合，保留期和 schema 演进 |
| [实时任务监控](activity-monitor.md) | 增量读取，rollout 对账，状态机和异常会话保护 |
| [防睡眠系统](sleep-prevention.md) | IOKit assertion，CodexBarHelper，XPC 租约和恢复策略 |
| [CloudKit 同步](sync.md) | 私有数据库，设备匿名化，上传，合并和重建 |
| [通知系统](notifications.md) | 通知触发，去重，声音，触觉和点击行为 |
| [UI 与应用生命周期](ui-and-lifecycle.md) | 菜单栏，面板，焦点，全局快捷键和服务装配 |
| [数据与隐私边界](data-and-privacy.md) | 本地文件，网络访问，云端字段和日志边界 |
| [开发与验证](development.md) | 工程结构，构建检查，调试和变更验收 |

## 核心设计约束

- 启动时必须先处理 `--hook-event` 模式，该模式不能初始化 UI
- app-server 额度与用量，Hook 历史聚合，实时任务监控是 3 条独立数据链路
- `CodexActivityMonitor` 是任务状态的唯一来源
- UI，Controller，ViewModel 和 Settings 默认在 `MainActor` 上运行
- 阻塞 I/O 和共享可变状态必须离开主 actor
- CodexBarHelper 只负责睡眠控制，不增加网络，任意命令执行或额外文件访问
- Hook 配置修改必须保留用户和其他应用已有的 handler
- 聚合语义变化必须递增聚合 schema，并从原始事件完整重建
- 缺失的 Hook 计数字段表示历史来源不可用，不能解释为明确的 `0`

## 主要入口

- App 启动入口：[`CodexBarApp.swift`](../../CodexBar/App/CodexBarApp.swift)
- 服务装配入口：[`StatusItemController.swift`](../../CodexBar/Controllers/StatusItemController.swift)
- app-server 服务：[`CodexStatusService.swift`](../../CodexBar/Services/CodexStatus/CodexStatusService.swift)
- Hook 子进程入口：[`WorkflowHookEventRecorder.swift`](../../CodexBar/Services/Workflow/WorkflowHookEventRecorder.swift)
- 实时任务状态机：[`CodexActivityMonitor.swift`](../../CodexBar/Services/Workflow/CodexActivityMonitor.swift)
- 防睡眠编排：[`KeepAliveController.swift`](../../CodexBar/Services/KeepAlive/KeepAliveController.swift)
- CodexBarHelper: [`main.swift`](../../CodexBarHelper/main.swift)

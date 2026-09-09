# CodexBar 开发者指南

简体中文 | [English](../en/DeveloperGuide/README.md)

## 按职责查找

| 文档 | 内容 |
| --- | --- |
| [整体架构](architecture.md) | 进程、模块、生命周期、actor 边界和 3 条数据链路 |
| [设计原则与关键决策](design-decisions.md) | 状态所有权、并发提交、数据恢复和特权边界 |
| [app-server 数据链路](app-server.md) | CLI 定位、代理配置与测试、JSON-RPC 会话、账户、额度、用量刷新和自动重置状态机 |
| [Hook 采集与历史聚合](hook-and-aggregation.md) | Hook 安装、事件落盘、聚合、保留期和 schema 演进 |
| [实时任务监控](activity-monitor.md) | 增量读取、rollout 对账、状态机和异常会话保护 |
| [防睡眠系统](sleep-prevention.md) | IOKit assertion、CodexBarHelper、XPC 租约、自动重置唤醒计划和恢复策略 |
| [CloudKit 同步](sync.md) | 私有数据库、设备匿名化、上传、合并和重建 |
| [通知系统](notifications.md) | 通知触发、去重、声音、触觉和点击行为 |
| [UI 与应用生命周期](ui-and-lifecycle.md) | 菜单栏、面板、焦点、全局快捷键和服务装配 |
| [数据与隐私边界](data-and-privacy.md) | 本地文件、网络访问、云端字段和日志边界 |
| [开发与验证](development.md) | 工程结构、构建检查、调试和变更验收 |

## 在线资料

- [运行架构](https://codexbar.zabrian.app/architecture)
- [性能报告](https://codexbar.zabrian.app/performance)

## 核心术语

| 术语 | 在本项目中的准确含义 |
| --- | --- |
| snapshot | 可重复读取的当前状态，不代表刚刚发生了一次事件 |
| transition | 由可信 live 输入产生的一次性状态变化，可驱动通知等副作用 |
| bootstrap | 从现有本地数据恢复内存基线，不应补发历史副作用 |
| stale | 有可展示旧值，但本轮未能从来源确认 |
| unavailable | 当前无法得到可信来源，不能等价为空或 `0` |
| generation | 数据源或异步操作的代际，用于拒绝迟到结果 |
| source generation | 某日原始 Hook 文件的来源身份，与代码 schema 不同 |
| owned | CodexBar 已持久化系统睡眠恢复责任 |
| external | 系统状态已经由 CodexBar 之外的来源设置 |

## 主要入口

- App 启动入口：[`CodexBarApp.swift`](../../CodexBar/App/CodexBarApp.swift)
- 服务装配入口：[`CodexBarAppDelegate.swift`](../../CodexBar/Controllers/CodexBarAppDelegate.swift)
- app-server 服务：[`CodexStatusService.swift`](../../CodexBar/Services/CodexStatus/CodexStatusService.swift)
- Hook 子进程入口：[`WorkflowHookEventRecorder.swift`](../../CodexBar/Services/Workflow/WorkflowHookEventRecorder.swift)
- 实时任务状态机：[`CodexActivityMonitor.swift`](../../CodexBar/Services/Workflow/CodexActivityMonitor.swift)
- 自动重置状态机：[`AutoResetController.swift`](../../CodexBar/Services/CodexStatus/AutoResetController.swift)
- 自动重置唤醒同步：[`AutoResetWakeScheduler.swift`](../../CodexBar/Services/KeepAlive/AutoResetWakeScheduler.swift)
- 防睡眠编排：[`KeepAliveController.swift`](../../CodexBar/Services/KeepAlive/KeepAliveController.swift)
- CodexBarHelper：[`main.swift`](../../CodexBarHelper/main.swift)

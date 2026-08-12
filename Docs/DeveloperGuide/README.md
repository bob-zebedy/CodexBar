# CodexBar 开发者指南

本指南面向希望理解 CodexBar 架构、调试数据链路或参与开发的开发者。

内容不仅描述模块做什么，还解释为什么这样划分职责，哪些失败路径是刻意保守处理，以及修改实现时必须继续维持哪些不变量。

产品功能和操作方式见 [用户指南](../UserGuide/README.md)

## 文档目标

开发者指南需要帮助读者完成 4 类工作：

- 建立系统模型，理解数据从哪里来，在哪里变成状态，最终由谁消费
- 定位修改入口，知道某个行为的唯一状态所有者和副作用边界
- 理解设计取舍，避免把看似多余的 generation, stale 标记或恢复步骤简化掉
- 验证改动，能从不变量和故障场景推导验收范围

每篇专题文档尽量按同一顺序组织：

```text
目标与约束
  -> 数据或控制流
  -> 状态所有权
  -> 关键设计理由
  -> 失败与恢复
  -> 修改指南
  -> 验证场景
```

## 阅读路线

第一次了解项目时，建议按以下顺序阅读：

1. [整体架构](architecture.md)
2. [设计原则与关键决策](design-decisions.md)
3. [app-server 数据链路](app-server.md)
4. [Hook 采集与历史聚合](hook-and-aggregation.md)
5. [实时任务监控](activity-monitor.md)
6. [防睡眠系统](sleep-prevention.md)
7. [CloudKit 同步](sync.md)
8. [通知系统](notifications.md)
9. [UI 与应用生命周期](ui-and-lifecycle.md)
10. [数据与隐私边界](data-and-privacy.md)
11. [开发与验证](development.md)

## 按职责查找

| 文档 | 内容 |
| --- | --- |
| [整体架构](architecture.md) | 进程、模块、生命周期、actor 边界和 3 条数据链路 |
| [设计原则与关键决策](design-decisions.md) | 跨模块设计动机、系统不变量、失败优先级和实现小巧思 |
| [app-server 数据链路](app-server.md) | CLI 定位、JSON-RPC 会话、账户、额度和用量刷新 |
| [Hook 采集与历史聚合](hook-and-aggregation.md) | Hook 安装、事件落盘、聚合、保留期和 schema 演进 |
| [实时任务监控](activity-monitor.md) | 增量读取、rollout 对账、状态机和异常会话保护 |
| [防睡眠系统](sleep-prevention.md) | IOKit assertion, CodexBarHelper, XPC 租约和恢复策略 |
| [CloudKit 同步](sync.md) | 私有数据库、设备匿名化、上传、合并和重建 |
| [通知系统](notifications.md) | 通知触发、去重、声音、触觉和点击行为 |
| [UI 与应用生命周期](ui-and-lifecycle.md) | 菜单栏、面板、焦点、全局快捷键和服务装配 |
| [数据与隐私边界](data-and-privacy.md) | 本地文件、网络访问、云端字段和日志边界 |
| [开发与验证](development.md) | 工程结构、构建检查、调试和变更验收 |

## 按修改目标查找

| 修改目标 | 先读 | 同时核对 |
| --- | --- | --- |
| 新增账户或用量字段 | [app-server 数据链路](app-server.md) | [数据与隐私边界](data-and-privacy.md) |
| 新增 Hook 事件或历史指标 | [Hook 采集与历史聚合](hook-and-aggregation.md) | [CloudKit 同步](sync.md) |
| 修改任务状态或 terminal 判定 | [实时任务监控](activity-monitor.md) | [通知系统](notifications.md)、[防睡眠系统](sleep-prevention.md) |
| 修改菜单、窗口或快捷键 | [UI 与应用生命周期](ui-and-lifecycle.md) | [开发与验证](development.md) |
| 修改通知触发或去重 | [通知系统](notifications.md) | 对应的数据来源专题 |
| 修改防睡眠策略或 helper | [防睡眠系统](sleep-prevention.md) | [数据与隐私边界](data-and-privacy.md) |
| 修改同步字段或合并规则 | [CloudKit 同步](sync.md) | [Hook 采集与历史聚合](hook-and-aggregation.md) |
| 修改持久化结构或默认值 | [开发与验证](development.md) | [设计原则与关键决策](design-decisions.md) |

## 核心设计约束

- 启动时必须先处理 `--hook-event` 模式，该模式不能初始化 UI
- app-server 额度与用量、Hook 历史聚合、实时任务监控是 3 条独立数据链路
- `CodexActivityMonitor` 是任务状态的唯一来源
- UI, Controller, ViewModel 和 Settings 默认在 `MainActor` 上运行
- 阻塞 I/O 和共享可变状态必须离开主 actor
- CodexBarHelper 只负责睡眠控制，不增加网络、任意命令执行或额外文件访问
- Hook 配置修改必须保留用户和其他应用已有的 handler
- 聚合语义变化必须递增聚合 schema，并从原始事件完整重建
- 缺失的 Hook 计数字段表示历史来源不可用，不能解释为明确的 `0`

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
| owned | 系统状态由 CodexBar 完成切换并有权恢复 |
| external | 系统状态已经由 CodexBar 之外的来源设置 |

## 阅读源码的建议

先确认状态所有者，再沿消费者反向阅读。

例如修改等待批准行为时，推荐顺序是：

```text
CodexActivityTask
  -> CodexActivityMonitor
  -> CodexActivitySnapshot / transition
  -> CodexNotificationService
  -> KeepAliveController
  -> SwiftUI View
```

从 View 开始搜索通常只能看到最终展示条件，容易漏掉 bootstrap、去重和恢复语义。

## 主要入口

- App 启动入口：[`CodexBarApp.swift`](../../CodexBar/App/CodexBarApp.swift)
- 服务装配入口：[`CodexBarAppDelegate.swift`](../../CodexBar/Controllers/CodexBarAppDelegate.swift)
- app-server 服务：[`CodexStatusService.swift`](../../CodexBar/Services/CodexStatus/CodexStatusService.swift)
- Hook 子进程入口：[`WorkflowHookEventRecorder.swift`](../../CodexBar/Services/Workflow/WorkflowHookEventRecorder.swift)
- 实时任务状态机：[`CodexActivityMonitor.swift`](../../CodexBar/Services/Workflow/CodexActivityMonitor.swift)
- 防睡眠编排：[`KeepAliveController.swift`](../../CodexBar/Services/KeepAlive/KeepAliveController.swift)
- CodexBarHelper：[`main.swift`](../../CodexBarHelper/main.swift)

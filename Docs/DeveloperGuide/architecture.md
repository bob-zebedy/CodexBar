# 整体架构

## 这套架构要解决什么

CodexBar 的核心挑战不是绘制菜单栏界面, 而是在一个长期运行的 `LSUIElement` App 中同时协调短命 Hook 子进程, 本机 app-server, 持续追加的文件, CloudKit, 系统通知和 root helper

架构需要持续满足以下目标

- 任意一条数据链路失败时, 不连带关闭其他功能
- 短命 Hook 模式和普通 App 模式共用可执行文件, 但生命周期完全隔离
- UI 只观察可解释的快照, 不直接承担 I/O, 去重或恢复逻辑
- 特权操作保持最小接口, 业务策略留在普通 App 进程
- 每个异步结果都能证明自己仍属于当前配置和数据源代际
- 可重建数据与不可重放副作用分开处理

更完整的取舍背景见 [设计原则与关键决策](design-decisions.md)

## 技术基线

CodexBar 是 macOS 15+ 菜单栏应用, 使用 Swift 6, SwiftUI, AppKit 和 MVVM

工程只有 `CodexBar` scheme, 包含两个 target

| Target | 职责 |
| --- | --- |
| `CodexBar` | 菜单栏 UI, Codex 数据采集, 通知, 同步和防睡眠编排 |
| `CodexBarHelper` | 以 root LaunchDaemon 运行, 仅负责系统睡眠开关 |

两个 target 通过 [`CodexBarHelperXPC.swift`](../../Shared/CodexBarHelperXPC.swift) 共享 XPC 协议

App 使用 Sparkle 检查更新. 工程默认启用 `MainActor` 隔离, Debug 和 Release 使用不同的 App 与 CodexBarHelper bundle ID

## 进程与信任边界

```text
Codex
  | 启动 --hook-event 子进程, 通过 stdin 传入事件
  v
CodexBar executable
  |-- Hook 模式: 最小解析 + flock + JSONL append + exit
  |
  `-- 普通模式
       |-- stdio JSON-RPC <-> codex app-server
       |-- 本地只读 <-> Hook JSONL / rollout JSONL
       |-- HTTPS <-> Reset Credits / Sparkle
       |-- CloudKit private database <-> 日级聚合
       `-- signed XPC lease <-> root CodexBarHelper <-> fixed pmset commands
```

边界设计有两个关键点

- 同一个可执行文件承载 Hook 模式可以让 handler 始终指向当前 App 版本, 不需要额外部署采集工具
- root helper 不知道 Codex 任务, 只知道经过签名校验的租约, 因而不会把业务输入直接带入特权边界

### 进程生命周期差异

| 进程 | 生命周期 | 可以做什么 | 不能做什么 |
| --- | --- | --- | --- |
| Hook 子进程 | 单个事件, 最长几秒 | 读取 stdin, 提取最小字段, 追加本地 JSONL | 初始化 UI, 建立网络连接, 等待长期服务 |
| 主 App | 用户登录会话内长期运行 | 编排 UI, 数据链路和副作用 | 直接以 root 修改系统设置 |
| app-server | 最长复用 1 小时 | 通过 JSON-RPC 提供账户和配置能力 | 成为 Hook 历史或实时任务的替代来源 |
| CodexBarHelper | LaunchDaemon | 执行固定 `pmset` 操作并恢复所有权 | 访问账户, Hook, rollout, 网络或任意命令 |

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

[`CodexBarApp.swift`](../../CodexBar/App/CodexBarApp.swift) 的初始化顺序是架构约束, 不是实现细节

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

`--hook-event` 是 Codex 调用的短命子进程模式. 它必须在任何 UI, CloudKit, 通知或长期服务初始化之前完成. 采集失败也不能阻断 Codex 主流程

普通模式由 `CodexBarAppDelegate` 统一创建和持有长期对象, 主要包括

- `CodexStatusService` 和 `CodexStatusViewModel`
- `WorkflowService` 和对应 ViewModel
- `CodexHookSettings`
- `CodexActivityMonitor`
- `KeepAliveController`
- `WorkflowSyncSettings` 和同步调度器
- `CodexNotificationService`
- 菜单栏, 快捷键, 设置窗口和更新服务

App 退出时需要先释放防睡眠状态. 如果 CodexBarHelper 尚未确认恢复, 终止流程会等待或取消退出, 避免遗留系统级睡眠状态

### 为什么 Hook 判断必须放在 `App.init`

`@NSApplicationDelegateAdaptor` 会把 AppKit 生命周期接入 SwiftUI App. 一旦普通生命周期开始, 可能创建菜单栏对象, 注册通知 delegate 或访问 CloudKit

Hook handler 在 Codex 的关键路径上, 它需要的是接近命令行工具的行为. 因此 `WorkflowHookEventRecorder.handleIfRequested()` 必须在 `CodexBarApp.init()` 的第一段执行, 命中后直接 `exit(EXIT_SUCCESS)`

这个顺序还保证 Hook 采集失败不会污染正常退出诊断. `AppProcessDiagnostics.install()` 只在 `applicationDidFinishLaunching` 中执行, Hook 子进程不会被误记为一次异常退出的完整 App

### 为什么由 AppDelegate 持有长期对象

SwiftUI View 会因为布局, 条件分支和窗口重建而重复创建. 如果 service 的所有权落在 View 中, 一个看似普通的界面变化就可能终止 reader, app-server 或 XPC 连接

`CodexBarAppDelegate` 因而承担 composition root 职责

- 只在这里创建长期 service, settings 和 ViewModel
- 在这里建立 monitor, notification 和 keep-alive 之间的回调
- View 只接收已经创建好的引用
- App 退出时从同一个所有者反向停止服务

这不是要求所有逻辑都堆进 AppDelegate. 它只负责装配和生命周期, 业务规则仍在各自 service 或 controller 中

### 退出为什么可以被取消

`applicationShouldTerminate` 先调用 `KeepAliveController.prepareForTermination()` 并返回 `.terminateLater`

如果 helper 明确确认 release, App 再回复允许退出. 如果释放失败, 本次退出被取消, controller 回到正常协调状态并继续尝试维持正在运行的任务

直接在 `applicationWillTerminate` 中异步释放已经太晚, 因为该回调不能可靠延长进程寿命

## 3 条独立数据链路

CodexBar 不使用一个聚合服务承载所有状态. 3 条链路的输入, 时效和失败语义不同

| 链路 | 输入 | 输出 | 主要消费者 |
| --- | --- | --- | --- |
| app-server | `codex app-server` JSON-RPC | 账户, 额度, token 用量, Hook 配置能力 | 主面板, 菜单栏额度, 设置 |
| Hook 历史 | Hook JSONL | 日级事件, session, turn, tool, model 聚合 | 活跃度热力图, 历史统计, CloudKit |
| 实时任务 | Hook 增量事件加 rollout 生命周期 | 运行, 等待批准, 完成, 中断 | 菜单栏状态, 任务中心, 通知, 防睡眠 |

链路之间可以共享基础设施和模型, 但不能互相替代

- app-server 不提供完整的实时任务状态
- 历史聚合允许延迟和重建, 实时任务不能等待聚合完成
- 实时任务快照不可作为历史统计的持久来源
- 某条链路不可用时, 其他链路仍应保持可用

### 依赖方向

```text
CodexStatusService ----> CodexStatusViewModel ----+
                                                 |
WorkflowService -------> WorkflowViewModel -------+--> UI
                                                 |
Hook + rollout --------> CodexActivityMonitor ----+
                              |          |
                              |          +--> CodexNotificationService
                              `-------------> KeepAliveController --> helper
```

箭头表示数据或只读状态的消费方向. 下游不能反向成为上游的事实来源

例如, 菜单栏可以把额度进度和任务状态画在同一个图标上, 但图标是否存在不能决定任务 monitor 是否运行. 同步 scheduler 可以复用历史维护的触发时机, 但 CloudKit 是否可用不能决定本地聚合是否执行

### 共享触发不等于数据依赖

历史维护默认挂在 60 秒额度刷新完成事件上, 这是为了减少常驻 timer 和日志噪音. 两条链路共享调度时机, 但没有共享事实

因此修改刷新节奏时需要区分

- 触发来源可以调整
- 维护任务仍必须在 app-server 失败时具备独立执行能力
- UI 打开时的轻量统计刷新不能隐式发起 CloudKit 网络操作

## 并发边界

工程启用 Swift 6 严格并发和默认 `MainActor` 隔离

### MainActor 对象

- SwiftUI ViewModel 和 Settings
- AppKit Controller
- `CodexActivityMonitor`
- `KeepAliveController`
- `CodexNotificationService`

这些对象负责可观察状态和 UI 协调, 不应直接执行阻塞 I/O

### Actor 服务

- `CodexStatusService` 管理 app-server 连接和刷新
- `WorkflowService` 管理历史聚合
- `HookEventTailReader` 管理 Hook 文件游标
- `CodexSessionLifecycleReader` 管理 rollout 文件游标
- `WorkflowSyncService` 管理 CloudKit 状态
- `ActivityProtectionStateStore` 管理跨进程保护记录

跨 actor 传递的 DTO 必须是不可变值类型, 并按需要声明 `Sendable` 或 `nonisolated`

### 为什么 monitor 仍在 MainActor

`CodexActivityMonitor` 的输入读取在 actor 中完成, 但状态机本身与多个 Combine 消费者紧密相连

把 monitor 放在 `MainActor` 有以下收益

- `@Published snapshot` 和 transition 发布顺序天然串行
- 通知与防睡眠消费者看到相同的状态提交顺序
- App 睡眠, 唤醒和 Hook 设置变化可以与 UI 生命周期统一排序

前提是 monitor 不能直接执行阻塞文件读取. `HookEventTailReader`, `CodexSessionLifecycleReader` 和 `ActivityProtectionStateStore` 各自承担 I/O 边界

### 非隔离 pipe reader 为什么使用锁

app-server 是 stdio 协议, 底层需要组合 `FileHandle`, `DispatchSourceRead` 和 semaphore. 这些类型不是天然 `Sendable`, 也不适合每读取一行都跨 Swift actor hop

`PipeReadBuffer` 把不安全边界收口在一个 `@unchecked Sendable` 类型中, 所有可变状态由 `NSLock` 保护, 读事件固定在专用 queue 上. 上层只看到完整行和关闭状态

这里的 `@unchecked` 是经过封装的局部承诺, 不是关闭整个模块的并发检查

### 跨进程文件不能只依赖 actor

Hook recorder 是另一个进程, 所以 `WorkflowService` actor 无法保护它. `stats.lock` 使用 `flock` 对事件文件和维护状态的联合修改提供进程级排他事务

同一个流程中会同时出现 actor 和 `flock`

- actor 保证主 App 内多项维护不会并行改状态
- `flock` 保证主 App 与短命 Hook 子进程不会同时提交冲突文件修改

## 模型分层

项目没有让 app-server DTO, 持久化模型和 View 直接共用同一个大对象

| 模型类型 | 作用 | 设计要求 |
| --- | --- | --- |
| 外部 DTO | 解码 app-server, Hook, rollout 或 CloudKit | 宽容版本差异, 不承载 UI 副作用 |
| 持久化模型 | 保存可恢复状态和 schema | 兼容旧值, 明确 missing 语义 |
| 领域快照 | 向消费者表达当前可信状态 | 不可变, 可比较, 跨 actor 安全 |
| transition | 表达一次 live 状态变化 | 不从历史快照反推, 需要上游去重 |
| 展示格式 | 日期, 百分比, 文案和颜色 | 跟随 locale, 不反向参与业务判定 |

例如 `CodexQuotaSnapshot` 可以同时携带当前值和 stale 标记. `CodexActivitySnapshot` 只保存展示需要的任务字段, 原始 session ID 不进入 View

## 生命周期与保留时间

不同状态有不同的生命周期, 不能用一个统一缓存期限替代

| 状态 | 生命周期 | 原因 |
| --- | --- | --- |
| app-server connection | 最长 1 小时 | 复用降低启动成本, 定期重建让磁盘升级生效 |
| app-server supplemental cache | 当前账户内 | 避免跨账户串值 |
| Hook live bootstrap window | 24 小时 | 覆盖可能仍在运行的长任务 |
| 完成高亮 | 30 秒 | 菜单栏短时反馈 |
| 任务中心 terminal 历史 | 10 分钟 | 提供近期上下文但不长期占用 UI |
| terminal 去重记忆 | 24 小时 | 防止迟到 Hook 或 rollout 复活旧任务 |
| Hook 原始和日聚合 | 210 天 | 支持长期统计和重建 |
| 日聚合身份明细 | 3 天 | 近期精确去重与隐私, 文件体积折中 |
| Activity Protection 记录 | 最后进展后 24 小时 | 跨重启保持抑制, 同时限制身份留存 |

修改其中一个时间窗口时, 要先确认是否存在配对不变量. 例如 tail reader bootstrap 窗口必须和活动任务保留窗口一致

## 状态所有权

实时任务状态只有一个权威来源, 即 [`CodexActivityMonitor.swift`](../../CodexBar/Services/Workflow/CodexActivityMonitor.swift)

它的快照被以下模块消费

- 菜单栏图标和主面板任务卡片
- 活动中心
- 完成和等待批准通知
- 防睡眠是否存在有效任务的判断
- 异常会话保护

消费者只能基于快照展示或执行副作用, 不能各自重建一套任务状态机

### 状态所有权表

| 状态 | 唯一所有者 | 其他模块的权限 |
| --- | --- | --- |
| app-server 连接与同账户缓存 | `CodexStatusService` | 请求只读结果 |
| 主面板账户加载状态 | `CodexStatusViewModel` | 观察发布值 |
| Hook 安装与验证 | `CodexHookSettings` | 读取 `isOperable` |
| 历史聚合和维护游标 | `WorkflowService` | 请求快照或重建 |
| 实时任务 | `CodexActivityMonitor` | 读取 snapshot 或 transition |
| 同步游标与远端缓存 | `WorkflowSyncService` | 请求合并快照 |
| 防睡眠策略与 App assertion | `KeepAliveController` | 读取派生状态或调用设置入口 |
| root 睡眠所有权 | `CodexBarHelper` | 通过 XPC 请求和查询 |
| 通知去重 | `CodexNotificationService` | 上游只发布候选事件 |

新增消费者时, 优先订阅已有快照. 如果现有快照缺字段, 应在状态所有者处扩展稳定值类型, 不应让消费者重新读取原始文件

## 错误和降级原则

- 短暂网络或 RPC 失败优先保留上一次可解释的状态
- 数据源不可用必须显式表达, 不能伪装为空数据
- bootstrap 阶段只建立基线, 不发送历史状态变化通知
- reader 更换或数据源代际变化时丢弃旧异步结果
- 恢复流程必须完成新的读取屏障后才能继续判定
- 持久化文件写入需要原子替换或文件锁, 避免 Debug 与 Release 并发破坏

### 错误分类比统一重试更重要

| 错误类别 | 典型处理 | 不应采取的处理 |
| --- | --- | --- |
| 明确业务不支持 | 缓存 method unsupported, 显示来源缺失 | 每分钟重复请求或展示 `0` |
| 短暂业务失败 | 同账户范围内使用 stale 缓存 | 清空整个账户快照 |
| transport 失败 | 丢弃连接, 最多重建一次 | 在不可信 pipe 上继续请求 |
| 数据源身份变化 | 新 generation, 从原始来源重建 | 沿用旧 offset 继续追加 |
| 迟到异步结果 | generation 不匹配时丢弃 | 覆盖新设置或新 reader 状态 |
| 特权状态不确定 | 保留可能租约并主动确认释放 | 假定 helper 没有执行 |
| Hook recorder 失败 | 吞掉本次采集并退出成功 | 阻断 Codex 或弹 UI |

### 日志为什么记录阶段而不是用户数据

系统日志使用 `trigger`, `stage`, `reason`, `counts` 和 `elapsed` 解释流程, 避免记录额度数值, 项目路径或任务身份

这种日志结构允许区分

- 同步是在 zone, device, fetch, upload 还是 prune 阶段失败
- app-server 使用新连接还是复用连接
- 聚合是空转, 增量写入还是标脏重建
- 防睡眠被哪一个条件阻断

诊断需要的是控制流证据, 不需要复制用户数据

## 变更一个核心流程时怎么落点

### 新增数据来源

1. 先确定它是否属于现有 3 条链路
2. 定义来源缺失, stale 和失败语义
3. 在 actor service 内完成 I/O 和缓存
4. 通过不可变快照进入 MainActor
5. 单独审查网络和隐私边界

### 新增一次性副作用

1. 找到能证明"刚刚发生"的 live transition
2. 不从当前快照或历史列表反推
3. 定义进程内和跨重启去重范围
4. 提交前检查事件是否仍相关
5. 定义副作用失败是否可以影响主状态

### 新增持久化状态

1. 说明为什么内存状态不足
2. 定义 schema, 原子性和并发访问边界
3. 定义旧版本读取新文件和新版本读取旧文件的行为
4. 限制保存字段和保留时间
5. 先确认兼容策略再修改格式

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

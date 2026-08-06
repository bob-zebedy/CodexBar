# 通知系统

## 职责

[`CodexNotificationService.swift`](../../CodexBar/Services/Notifications/CodexNotificationService.swift) 是通知副作用的统一入口。

它观察两类状态：

- app-server 账户，额度和 Reset Credits 快照
- `CodexActivityMonitor` 任务转场和防睡眠恢复事件

View 和其他服务不直接创建系统通知。它们发布状态变化，通知服务负责资格判断，去重，声音和点击行为。

## 通知开关

通知总开关默认关闭。各分类子开关默认开启，触觉反馈默认关闭。

总开关关闭时不会申请系统通知权限，也不会发送任何分类通知。子开关用于在总开关开启后选择具体类型：

| 分类 | 数据来源 |
| --- | --- |
| 额度重置 | app-server 额度窗口 |
| 低额度 | app-server 剩余额度 |
| Reset Credits 到期 | Reset Credits endpoint |
| 任务完成 | 实时任务 terminal 转场 |
| 等待批准 | 实时任务 waiting 转场 |
| 异常会话保护 | Activity Protection |
| 防睡眠停止 | KeepAlive 恢复结果 |

## 额度重置

额度重置通知需要先观察到窗口被消费，再观察到新窗口恢复为未消费状态。

这避免 App 第一次启动时仅因为当前额度是 100% 就发送重置通知。

判断状态按账户和额度窗口隔离。账户变化时不把前一账户的消费状态延续到新账户。

## 低额度

低额度阈值可选 5%, 10% 或 25%，默认 10%。

通知只在剩余额度从阈值上方跨到阈值或下方时发送。持续停留在低额度区域不会每次刷新都重复通知。

首次可信快照已经低于阈值时也视为一次向下穿越，用于覆盖 App 在穿越后才启动的情况。

持久化去重 key 保留 app-server 返回的秒级重置时间。相同账户和额度窗口的重置时间与已记录值相差不超过 60 秒时视为同一周期，只有差值超过 60 秒才视为新的重置周期。

额度恢复到阈值上方后会重新启用穿越判定，但同一重置周期仍只通知一次。进入新的重置周期后，下一次向下跨越可以再次通知。

## Reset Credits 到期

当 Reset Credits 数量大于 `0` 且能够读取到期日时，通知服务在到期前 7 天到 1 天按天提醒。

去重 key 包含账户，到期日和剩余天数。同一天多次刷新不会重复发送。

## 任务完成

任务通知只响应 monitor 发布的新 terminal 转场，不扫描历史列表推导：

- bootstrap 建立的历史任务不发送通知
- terminal ID 在活动监控层保留 24 小时去重
- 通知服务还维护自己的已发送 key
- 同一 turn 的 `Stop` 和 rollout terminal 对账后只发送一次

匿名任务不会发布给任务通知消费者. 通知服务在 transition 入口再次过滤 `isAnonymous`, 因此匿名任务不发送完成或等待批准通知, 也不触发任务触觉反馈

任务完成最短持续时间可选 30, 60, 120 或 300 秒，默认 60 秒。持续时间较短的完成任务不会通知，但仍可以在 UI 中短暂展示。

## 等待批准

只有 `PermissionRequest` 的 reviewer 确认是用户时才发送等待批准通知：

- 自动审批不通知
- 同一等待项只通知一次
- 任务离开等待状态后从相关集合移除
- bootstrap 中已存在的等待状态不补发历史通知

等待状态是否维持防睡眠是独立设置，不影响是否可以发送等待批准通知。

## 异常会话保护

非匿名任务静默达到阈值时, Activity Protection 先保存保护记录并隐藏任务, 然后请求通知. 匿名任务不进入保护候选, 也不会产生保护通知

通知服务在提交前再次检查任务是否仍然被保护。如果 3 秒宽限内出现新进展，过时通知会被取消。

保护通知使用固定默认声音，不复用任务完成分类声音。通知发送失败不撤销已经完成的保护动作。

## 防睡眠停止

低电量或最长时长导致防睡眠停止时，`KeepAliveController` 先释放 App assertion 和 CodexBarHelper 租约。

只有系统状态恢复得到确认后才发布通知事件。这保证通知文字描述的是已经完成的结果。

## 声音

[`NotificationSoundOption.swift`](../../CodexBar/Services/Notifications/NotificationSoundOption.swift) 汇总 3 类选择：

- 无声音
- macOS 可用系统声音
- App bundle 内置声音

内置声音位于 [`NotificationSounds`](../../CodexBar/Resources/NotificationSounds)

已保存的声音名称在新系统或新版 App 中不存在时，回退到默认声音，不阻断通知。

不同通知分类可以保存各自的声音设置。

## 触觉反馈

触觉反馈默认关闭。开启后使用 10 次脉冲，每次间隔约 100 ms。

触觉是系统通知之外的可选本地反馈。不应在没有对应有效通知事件时单独触发。

## 提交与去重

通知通过 `UNUserNotificationCenter` 提交：

- 单次提交失败最多重试 1 次
- 已发送 dedup key 保存到 UserDefaults
- 最多保留 300 个 key
- key 必须包含足够的账户或任务范围，避免不同对象相互压制
- 过期或不再相关的 waiting key 会被移除

持久化去重避免 App 重启后立即重复发送同一事件，但不能替代上游任务 terminal 去重。

## 前台展示与点击

App 是 `LSUIElement`，通知中心 delegate 明确允许 App 在前台时继续展示 banner 和声音。

用户点击通知后打开主面板。打开动作通过状态栏控制器执行，复用现有 popover 或 fallback panel 逻辑。

## Codex TUI 通知

设置页中的 Codex TUI 通知是 Codex 自身配置，通过 app-server 的 `config/batchWrite` 读写。

它与 CodexBar 系统通知完全独立：

- 关闭 CodexBar 通知不代表关闭 TUI 通知
- TUI 设置失败不影响 App 通知状态
- UI 必须清楚区分两个开关的作用域

## 手动验证矩阵

- 首次开启总开关时正确请求系统权限
- 系统拒绝权限时设置页展示可理解状态
- 低额度只在向下跨越阈值时通知
- 初次加载 100% 额度不误报重置
- 完成时长低于和高于阈值时行为正确
- `Stop` 与 rollout terminal 同时出现时只通知一次
- 自动审批不发送等待批准通知
- App 前台时仍展示配置允许的通知
- 点击通知能够激活 `LSUIElement` App 并打开主面板
- 已保存声音资源缺失时回退正确
- App 重启后不重复发送已经持久化的事件

## 关键源码

- [`CodexNotificationService.swift`](../../CodexBar/Services/Notifications/CodexNotificationService.swift)
- [`NotificationSettings.swift`](../../CodexBar/Services/Settings/NotificationSettings.swift)
- [`NotificationSoundOption.swift`](../../CodexBar/Services/Notifications/NotificationSoundOption.swift)
- [`CodexCLINotificationSettings.swift`](../../CodexBar/Services/Settings/CodexCLINotificationSettings.swift)
- [`CodexActivityMonitor.swift`](../../CodexBar/Services/Workflow/CodexActivityMonitor.swift)
- [`KeepAliveController.swift`](../../CodexBar/Services/KeepAlive/KeepAliveController.swift)

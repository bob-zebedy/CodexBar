# 通知系统

简体中文 | [English](../en/DeveloperGuide/notifications.md)

## 职责

[`CodexNotificationService.swift`](../../CodexBar/Services/Notifications/CodexNotificationService.swift) 是通知副作用的统一入口。

它接收四类状态：

- app-server 账户与额度快照
- `CodexActivityMonitor` 任务转场与异常会话保护候选
- `KeepAliveController` 防睡眠恢复结果
- `AutoResetController` 已确认的消费结果或需要告知用户的失败状态

## 设置与系统授权

`NotificationSettings` 分开保存 App 内意图与 macOS 授权：

| 状态 | 含义 |
| --- | --- |
| `isEnabled` | 用户在 CodexBar 内打开总开关 |
| `authorizationStatus` | 系统是否允许通知 |
| `canDeliver` | 两者同时允许后的实际资格 |

总开关默认关闭，用户开启时才请求系统授权。

App 激活、设置窗口重新获得焦点或显式打开时会重新读取系统状态。系统返回 `denied` 时保留 App 内的通知开关，显示灰色未授权提示和“打开系统设置”按钮。实际查询返回 `notDetermined` 时关闭 App 内开关，用户再次开启后重新申请授权；初始化时的占位值不修改已保存的开关。

授权请求期间不重复发起请求，焦点变化也不会取消正在等待用户回应的请求。只要 App 内开关开启且系统尚未授权，就显示未授权提示。请求结束后若系统仍返回 `notDetermined`，开关恢复关闭，允许用户再次开启重试。

授权请求结束后，权限读取统一走普通刷新流程。查询期间再次收到焦点刷新时，新查询替换旧查询，旧结果不会覆盖最新权限状态。

触觉反馈不依赖 `UNUserNotificationCenter` 授权，但仍服从 App 内总开关。

## 通知开关

通知总开关默认关闭。8 个可配置分类的子开关默认开启，触觉反馈默认关闭。

总开关关闭时不会申请系统通知权限，也不会发送任何分类通知。子开关用于在总开关开启后选择具体类型：

| 分类 | 数据来源 | 控制条件 |
| --- | --- | --- |
| 额度重置 | app-server 额度窗口 | 独立子开关 |
| 低额度 | app-server 剩余额度 | 独立子开关和阈值 |
| Reset Credits 到期 | app-server 重置凭证明细 | 独立子开关 |
| 自动重置 | 已确认消费结果或需要告知用户的失败状态 | 自动重置开关、独立通知子开关和通知总开关 |
| 任务完成 | 实时任务 terminal 转场 | 独立子开关和最短时长 |
| 等待批准 | 实时任务 waiting 转场 | 独立子开关 |
| 异常会话保护 | Activity Protection | 防睡眠主开关和通知总开关 |
| 低电量保护停止 | KeepAlive 恢复结果 | 独立子开关，仅在保护可用时启用 |
| 防睡眠达到上限 | KeepAlive 恢复结果 | 独立子开关，仅在有限时长时启用 |

异常会话保护跟随防睡眠主开关，通知服从总开关和系统授权，没有独立通知子开关。低电量和时长上限的通知偏好会保留，对应保护条件不可用时 UI 显示为关闭并置灰。

## 额度重置

额度重置通知需要先观察到窗口被消费，再观察到新窗口恢复为未消费状态。

判断状态按账户和额度窗口隔离。账户变化时不把前一账户的消费状态延续到新账户。

每个额度窗口还带一个会话内 lifecycle token。窗口从可信快照消失后再出现会得到新 token。如果旧窗口的通知提交失败回调迟到，只有 token 仍相同时才把 `hasObservedConsumption` 恢复为 true。

重置状态不持久化。App 每次启动后重新观察消费和归零，不补发离线期间发生的重置通知。

## 自动重置

自动重置操作和额度窗口重置是两个独立事件，因此保留两条通知：

- “自动重置”说明 CodexBar 的自动操作收到 `reset` 或 `alreadyRedeemed`
- “额度已重置”说明普通额度快照先观察到消耗，随后观察到归零

一次自动重置可能同时满足两者，同一台设备可以先后收到两条通知，分别服从各自的开关。

成功通知正文优先带上消费后新鲜读取的剩余重置次数，包括明确的 `0`。后置读取失败时仍保留已经明确的成功结果，并发送只有标题、没有正文的通知。

`alreadyRedeemed` 表示相同幂等键此前已经成功，不应继续重试。多台设备同时调用时，每台明确收到 `reset` 或 `alreadyRedeemed` 的设备都可以发送本机成功通知。某台设备只在刷新中看到凭证消失时无法区分手动使用、其他设备使用或过期，因此静默停止，不发送成功通知。

失败通知使用“自动重置失败”，当前包括：

- 单次认证刷新后仍未登录，当前凭证暂停到可信快照证明认证恢复
- 参数、协议或方法错误，当前凭证停止重试
- 本机明确观察到目标已经过期，当前凭证停止重试

短暂网络和服务错误只进入退避重试，不在每次失败时打扰用户。同一凭证的同一失败原因最多通知一次；认证、永久错误和本机明确观察到的过期使用不同去重键，因此同一凭证可能先后出现不同失败通知。目标从服务端明细消失时无法判断原因，状态机会静默停止，不补发过期通知。

成功和失败通知共用“自动重置通知”子开关及声音，默认开启并使用系统默认声音。自动重置功能关闭时设置行置灰，但不覆盖已经保存的通知和声音选择；重新开启后恢复原值。

## 低额度

低额度阈值可选 5%, 10% 或 25%，默认 10%。

持久化去重 key 保留 app-server 返回的秒级重置时间。相同账户和额度窗口的重置时间与已记录值相差不超过 60 秒时视为同一周期，只有差值超过 60 秒才视为新的重置周期。

额度恢复到阈值上方后会重新启用穿越判定，但同一重置周期仍只通知一次。进入新的重置周期后，下一次向下跨越可以再次通知。

### 阈值穿越判定

“当前低于 10%”是一个持续状态，“刚刚低于 10%”才是通知事件。服务为每个 `account + limit + window` 保存上一帧剩余比例：

- 上一帧高于阈值且当前不高于阈值时发送
- 会话内第一帧已经不高于阈值时发送一次
- 一直停留在低区间时不发送
- 阈值设置变化时清除当前观察并立即按新阈值重判

设置订阅使用回调给出的新值。Combine 的 `@Published` 在 `willSet` 阶段发送，此时重新读取 settings 属性仍会得到旧值。这项实现细节是为了保证用户把阈值从 5% 改到 25% 时立即按 25% 判断。

stale app-server 快照不会推进上一帧，也不会触发低额度或重置。旧缓存只能用于展示连续性，不能成为一次新副作用的证据。

### 重置周期匹配

app-server 连接重建后，同一窗口的 `resetsAt` 可能出现秒级修正。如果 dedup key 使用绝对相等，同一周期会被当成新周期再次通知。

服务在相同账户、limit 和 window 范围内寻找 60 秒容差内的已发送或正在提交 key，并复用原 key。容差只用于身份归一化，UI 仍展示服务返回的实际时间。

## Reset Credits 到期

当 Reset Credits 数量大于 `0` 且能够读取到期日时，通知服务在到期前 7 天到 1 天按天提醒。

去重 key 包含账户、到期日和剩余天数。同一天多次刷新不会重复发送。

服务只调度最近一个未来检查点，到点后根据当前快照重新计算并安排下一次。

这样做可以处理：

- Reset Credits 数量或到期时间被 app-server 更新
- 通知设置中途关闭
- Mac 睡过 deadline 后通过 wake observer 补检
- 多个相同到期秒的次数合并成一条通知

日期判断基于距到期的剩余秒数，7 天到 1 天分别有独立 dedup key。调度器只负责唤醒检查，最终资格仍由当前快照决定。

## 任务完成

任务通知只响应 monitor 发布的新 terminal 转场，不扫描历史列表推导：

- bootstrap 建立的历史任务不发送通知
- terminal ID 在活动监控层保留 24 小时去重
- 通知服务还维护自己的已发送 key
- 同一 turn 的 `Stop` 和 rollout terminal 对账后只发送一次

匿名任务不会发布给任务通知消费者。通知服务在 transition 入口再次过滤 `isAnonymous`，因此匿名任务不发送完成或等待批准通知，也不触发任务触觉反馈。

任务完成最短持续时间可选 30, 60, 120 或 300 秒，默认 60 秒。持续时间较短的完成任务不会通知，但仍可以在 UI 中短暂展示。

触觉在每个 task transition 到达时启动，新 transition 会取消上一串 10 次脉冲并重新开始。每次脉冲前重新检查设置，用户关闭开关后不会继续完成旧序列。

## 等待批准

只有 `PermissionRequest` 的 reviewer 确认是用户时才发送等待批准通知：

- 自动审批不通知
- 同一等待项只通知一次
- 任务离开等待状态后从相关集合移除
- bootstrap 中已存在的等待状态不补发历史通知

等待状态是否维持防睡眠是独立设置，不影响是否可以发送等待批准通知。

等待通知使用稳定 task ID 作为系统通知 identifier。服务同时观察活动快照：

- 提交前任务已经离开 waiting 时跳过
- `UNUserNotificationCenter.add` 成功后状态又变化时立即撤回
- 后续快照不再包含任务时同时移除 delivered 和 pending notification
- 提交失败时从内存相关集合移除，允许未来真实的新等待再次尝试

前后两次 relevance 检查覆盖了异步提交窗口。只在提交前检查仍可能让一个已经获批的任务在通知中心留下过时提醒。

## 异常会话保护

非匿名运行任务静默达到阈值时，Activity Protection 先更新内存保护记录并安排异步保存，再并行启动通知提交和 3 秒宽限。通知处理返回或宽限到期后，monitor 重新校验候选，仍有效时才隐藏任务。隐藏不等待磁盘写入或通知成功。

通知使用 `taskID + attemptID` 作为 identifier，提交前后校验 progress generation 和静默时长。新进展会使保护尝试失效，并撤回对应通知。

保护通知使用系统默认声音，`retryCount` 为 `0`，避免重试已经失效的候选。

## 防睡眠停止

低电量或最长时长导致防睡眠停止时，`KeepAliveController` 先撤销 CodexBarHelper 租约。只有回复确认来源为 `.codexBar` 且 `SleepDisabled=0` 时，才提交对应通知；其他结果会清除本轮待发通知。

确认后才提交通知。App idle assertion 会保留到通知提交结束，避免合盖机器在通知交给系统前立即睡下。随后 controller 释放 assertion 并按需补发合盖睡眠。

## 声音

[`NotificationSoundOption.swift`](../../CodexBar/Services/Notifications/NotificationSoundOption.swift) 汇总 3 类选择：

- 无声音
- macOS 可用系统声音
- App bundle 内置声音

内置声音位于 [`NotificationSounds`](../../CodexBar/Resources/NotificationSounds)

已保存的声音名称在新系统或新版 App 中不存在时，回退到默认声音，不阻断通知。

不同通知分类可以保存各自的声音设置。

声音选项保存稳定 ID，而不是绝对文件路径：

- 内置声音通过 bundle resource 解析
- 系统声音首次访问时扫描用户、Local 和 System 声音目录
- `/Network/Library/Sounds` 刻意不扫描，自动挂载点探测可能阻塞 UI
- 同名声音按系统查找顺序选择靠前目录
- 内置 ID 预先保留，防止本机同名文件在重启后改变已保存选项的含义
- 已保存 ID 无法解析时回退 system default

系统默认声音和静音不可试听，预览只支持有明确文件的系统音和内置音。

## 触觉反馈

触觉反馈默认关闭。开启后使用 10 次脉冲，每次间隔约 100 ms。

触觉是系统通知之外的独立本地反馈。它响应非匿名任务的完成或等待 transition，服从通知总开关和触觉开关，但不依赖系统通知授权、分类通知开关或完成时长阈值。

这种分离让用户可以关闭 banner 仍保留统一的任务触觉。上游 transition 仍必须真实有效，bootstrap 历史和匿名任务不会触发。

## 提交与去重

通知通过 `UNUserNotificationCenter` 提交：

- 普通通知提交失败最多重试 1 次，异常会话保护通知不重试
- 已发送 dedup key 保存到 UserDefaults
- 最多保留 300 个 key
- key 必须包含足够的账户或任务范围，避免不同对象相互压制
- 过期或不再相关的 waiting key 会被移除

持久化去重避免 App 重启后立即重复发送同一事件，但不能替代上游任务 terminal 去重。

### 提交中与已发送去重

`submittingDedupKeys` 和 `sentDedupKeys` 不能合并：

| 集合 | 生命周期 | 防止的问题 |
| --- | --- | --- |
| `submittingDedupKeys` | 当前异步提交期间 | 两个同步调用在第一个 `await` 前同时通过检查 |
| `sentDedupKeys` | UserDefaults，最多 300 条 | App 重启后重复发送同一业务周期 |

dedup 检查和 `submitting` 插入在创建 Task 前同步完成，因此正确性不依赖 Swift task 调度顺序。

只有 `UNUserNotificationCenter.add` 成功且事件在提交后仍相关时才写入 sent key。如果提前记录，一次系统提交失败会永久吃掉这条提醒。

### 发送入口的统一语义

所有通知内容最终经过同一个 `send` 和 `deliver`

```text
同步检查 dedup
  -> 构造不可延迟的 notification request
  -> 提交前检查 relevance
  -> 调用系统中心
  -> 提交后再次检查 relevance
  -> 成功后持久化 dedup
  -> 失败时按 retryCount 重试并执行分类清理（默认 1 次，异常会话保护为 0 次）
```

日志只记录 `kind` 和失败原因，不记录 title 或 body。通知正文可能包含项目名和任务信息，即使日志位于本机也不应复制这些内容。

## 前台展示与点击

App 是 `LSUIElement`，通知中心 delegate 明确允许 App 在前台时继续展示 banner 和声音。

点击处理不直接创建新窗口，而是调用 `openMenuSurface`。这保证锚点有效时复用 popover，锚点无效时使用 fallback panel，并继续遵守同一套焦点和 dismiss 规则。

## Codex TUI 通知

设置页中的 Codex TUI 通知是 Codex 自身配置，通过 app-server 的 `config/read` 读取，并通过 `config/batchWrite` 写入。

它与 CodexBar 系统通知完全独立：

- 关闭 CodexBar 通知不代表关闭 TUI 通知
- TUI 设置失败不影响 App 通知状态
- UI 必须清楚区分两个开关的作用域

## 手动验证矩阵

- 首次开启总开关时正确请求系统权限
- 系统拒绝权限时设置页展示可理解状态
- 低额度只在向下跨越阈值时通知
- 初次加载 100% 额度不误报重置
- 自动重置明确返回 `reset` 时发送“自动重置”，后续额度归零时仍可独立发送“额度已重置”
- 自动重置明确返回 `alreadyRedeemed` 时按成功通知并停止重试
- 只看到目标凭证消失时不发送自动重置通知
- 网络重试期间不发送失败通知，同一凭证的同一失败原因最多通知一次
- 自动重置关闭时通知子项置灰，重新开启后恢复原来的开关和音效
- 成功和失败通知使用“自动重置通知”所选音效，选择静音时两者都无声
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

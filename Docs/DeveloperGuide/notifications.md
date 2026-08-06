# 通知系统

## 职责

[`CodexNotificationService.swift`](../../CodexBar/Services/Notifications/CodexNotificationService.swift) 是通知副作用的统一入口

它观察两类状态

- app-server 账户, 额度和 Reset Credits 快照
- `CodexActivityMonitor` 任务转场和防睡眠恢复事件

View 和其他服务不直接创建系统通知. 它们发布状态变化, 通知服务负责资格判断, 去重, 声音和点击行为

## 设计原则

通知不是状态本身, 而是状态变化触发的一次外部副作用. 一条可靠通知至少要同时满足 4 个条件

```text
事件真实发生
  + 用户允许这一分类
  + 事件仍然相关
  + 本生命周期或持久化周期尚未发送
```

把这些条件集中到一个服务有两个目的

- 上游只发布事实和转场, 不需要知道系统授权, 声音或去重存储
- 所有提交都经过同一套 relevance 检查, retry 和隐私日志规则

如果 View 直接发通知, SwiftUI 重建, 面板重复打开或快照重新发布都可能重复触发. 因此 View 只能修改设置或展示状态, 不能拥有通知副作用

## 快照与转场不能混用

不同通知需要不同类型的证据

| 通知 | 输入类型 | 原因 |
| --- | --- | --- |
| 低额度 | 连续可信快照 | 需要比较阈值上下两帧 |
| 额度重置 | 连续可信快照 | 需要先观察消费再观察归零 |
| Reset Credits 到期 | 当前快照加时间调度 | 到期提醒由未来 deadline 触发 |
| 任务完成 | monitor 转场 | 历史 terminal 快照不能补发 |
| 等待批准 | monitor 转场加当前快照 | 先通知新等待, 再撤回过时等待 |
| 异常会话保护 | 已提交保护结果 | 必须描述已经隐藏的任务 |
| 防睡眠停止 | 已确认系统恢复结果 | 不能在恢复请求前预告成功 |

从当前快照推导任务完成看起来更简单, 但 App 每次启动都会把历史完成任务当作新事件. 相反, 对低额度只看单次转场又无法识别 App 在阈值穿越后才启动的场景

## 设置和系统授权是两层门槛

`NotificationSettings` 分开保存 App 内意图与 macOS 授权

| 状态 | 含义 |
| --- | --- |
| `isEnabled` | 用户在 CodexBar 内打开总开关 |
| `authorizationStatus` | 系统是否允许通知 |
| `canDeliver` | 两者同时允许后的实际资格 |

总开关默认关闭, 因此 App 首次运行不会无缘由弹出系统权限请求. 用户主动开启后才调用 authorization API

App 激活时会重新读取系统状态, 因为用户可能在 System Settings 中改过权限. 如果 App 开关已开但系统仍为 `notDetermined`, 会补发一次请求, 覆盖用户在首次弹窗完成前退出的情况

触觉反馈不依赖 `UNUserNotificationCenter` 授权, 但仍服从 App 内总开关. 这是能力边界的区别, 不是绕过用户意图

## 通知开关

通知总开关默认关闭. 7 个可配置分类的子开关默认开启, 触觉反馈默认关闭

总开关关闭时不会申请系统通知权限, 也不会发送任何分类通知. 子开关用于在总开关开启后选择具体类型

| 分类 | 数据来源 | 控制条件 |
| --- | --- | --- |
| 额度重置 | app-server 额度窗口 | 独立子开关 |
| 低额度 | app-server 剩余额度 | 独立子开关和阈值 |
| Reset Credits 到期 | Reset Credits endpoint | 独立子开关 |
| 任务完成 | 实时任务 terminal 转场 | 独立子开关和最短时长 |
| 等待批准 | 实时任务 waiting 转场 | 独立子开关 |
| 异常会话保护 | Activity Protection | 防睡眠主开关和通知总开关 |
| 低电量保护停止 | KeepAlive 恢复结果 | 独立子开关, 仅在保护可用时启用 |
| 防睡眠达到上限 | KeepAlive 恢复结果 | 独立子开关, 仅在有限时长时启用 |

异常会话保护没有独立通知子开关. 它本身跟随防睡眠主开关, 保护动作发生后再服从通知总开关. 低电量和时长上限的通知偏好会保留, 但对应保护条件不可用时 UI 显示为关闭并置灰, 不修改持久化偏好

## 额度重置

额度重置通知需要先观察到窗口被消费, 再观察到新窗口恢复为未消费状态

这避免 App 第一次启动时仅因为当前额度是 100% 就发送重置通知

判断状态按账户和额度窗口隔离. 账户变化时不把前一账户的消费状态延续到新账户

每个额度窗口还带一个会话内 lifecycle token. 窗口从可信快照消失后再出现会得到新 token. 如果旧窗口的通知提交失败回调迟到, 只有 token 仍相同时才把 `hasObservedConsumption` 恢复为 true

这避免一个竞态: 旧窗口通知正在提交时 app-server 切换账户或窗口, 随后失败回调把新窗口错误标成"已经消费过"

重置状态不持久化. App 启动时必须重新观察到消费后才通知重置, 这是主动接受漏掉离线期间重置, 以换取绝不在启动时对 0% 用量误报

## 低额度

低额度阈值可选 5%, 10% 或 25%, 默认 10%

通知只在剩余额度从阈值上方跨到阈值或下方时发送. 持续停留在低额度区域不会每次刷新都重复通知

首次可信快照已经低于阈值时也视为一次向下穿越, 用于覆盖 App 在穿越后才启动的情况

持久化去重 key 保留 app-server 返回的秒级重置时间. 相同账户和额度窗口的重置时间与已记录值相差不超过 60 秒时视为同一周期, 只有差值超过 60 秒才视为新的重置周期

额度恢复到阈值上方后会重新启用穿越判定, 但同一重置周期仍只通知一次. 进入新的重置周期后, 下一次向下跨越可以再次通知

### 为什么使用剩余比例的向下穿越

"当前低于 10%"是一个持续状态, "刚刚低于 10%"才是通知事件. 服务为每个 `account + limit + window` 保存上一帧剩余比例

- 上一帧高于阈值且当前不高于阈值时发送
- 会话内第一帧已经不高于阈值时发送一次
- 一直停留在低区间时不发送
- 阈值设置变化时清除当前观察并立即按新阈值重判

设置订阅使用回调给出的新值. Combine 的 `@Published` 在 `willSet` 阶段发送, 此时重新读取 settings 属性仍会得到旧值. 这项实现细节是为了保证用户把阈值从 5% 改到 25% 时立即按 25% 判断

stale app-server 快照不会推进上一帧, 也不会触发低额度或重置. 旧缓存只能用于展示连续性, 不能成为一次新副作用的证据

### 重置时间为何允许 60 秒漂移

app-server 连接重建后, 同一窗口的 `resetsAt` 可能出现秒级修正. 如果 dedup key 使用绝对相等, 同一周期会被当成新周期再次通知

服务在相同账户, limit 和 window 范围内寻找 60 秒容差内的已发送或正在提交 key, 并复用原 key. 容差只用于身份归一化, UI 仍展示服务返回的实际时间

## Reset Credits 到期

当 Reset Credits 数量大于 `0` 且能够读取到期日时, 通知服务在到期前 7 天到 1 天按天提醒

去重 key 包含账户, 到期日和剩余天数. 同一天多次刷新不会重复发送

提醒不是建立 7 个长期系统 pending request. 服务只调度最近一个未来检查点, 到点后根据当前快照重新计算并安排下一次

这样做可以处理

- Reset Credits 数量或到期时间被 app-server 更新
- 通知设置中途关闭
- Mac 睡过 deadline 后通过 wake observer 补检
- 多个相同到期秒的次数合并成一条通知

日期判断基于距到期的剩余秒数, 7 天到 1 天分别有独立 dedup key. 调度器只负责唤醒检查, 最终资格仍由当前快照决定

## 任务完成

任务通知只响应 monitor 发布的新 terminal 转场, 不扫描历史列表推导

- bootstrap 建立的历史任务不发送通知
- terminal ID 在活动监控层保留 24 小时去重
- 通知服务还维护自己的已发送 key
- 同一 turn 的 `Stop` 和 rollout terminal 对账后只发送一次

匿名任务不会发布给任务通知消费者. 通知服务在 transition 入口再次过滤 `isAnonymous`, 因此匿名任务不发送完成或等待批准通知, 也不触发任务触觉反馈

任务完成最短持续时间可选 30, 60, 120 或 300 秒, 默认 60 秒. 持续时间较短的完成任务不会通知, 但仍可以在 UI 中短暂展示

任务通知入口再次过滤匿名任务, 即使 monitor 已保证不发布匿名转场. 这是副作用边界的纵深保护: 上游未来重构或新增 transition 类型时, 缺少 session ID 的任务仍不会意外产生系统通知或触觉

触觉在每个 task transition 到达时启动, 新 transition 会取消上一串 10 次脉冲并重新开始. 每次脉冲前重新检查设置, 用户关闭开关后不会继续完成旧序列

## 等待批准

只有 `PermissionRequest` 的 reviewer 确认是用户时才发送等待批准通知

- 自动审批不通知
- 同一等待项只通知一次
- 任务离开等待状态后从相关集合移除
- bootstrap 中已存在的等待状态不补发历史通知

等待状态是否维持防睡眠是独立设置, 不影响是否可以发送等待批准通知

等待通知使用稳定 task ID 作为系统通知 identifier. 服务同时观察活动快照

- 提交前任务已经离开 waiting 时跳过
- `UNUserNotificationCenter.add` 成功后状态又变化时立即撤回
- 后续快照不再包含任务时同时移除 delivered 和 pending notification
- 提交失败时从内存相关集合移除, 允许未来真实的新等待再次尝试

前后两次 relevance 检查覆盖了异步提交窗口. 只在提交前检查仍可能让一个已经获批的任务在通知中心留下过时提醒

## 异常会话保护

非匿名任务静默达到阈值时, Activity Protection 先保存保护记录并隐藏任务, 然后请求通知. 匿名任务不进入保护候选, 也不会产生保护通知

通知服务在提交前再次检查任务是否仍然被保护. 如果 3 秒宽限内出现新进展, 过时通知会被取消

保护通知使用固定默认声音, 不复用任务完成分类声音. 通知发送失败不撤销已经完成的保护动作

异常会话保护使用 `taskID + attemptID` 作为 identifier, relevance 还比较 progress generation 和静默时长. 任务在 3 秒通知宽限内出现进展时, monitor 让保护尝试失效并请求撤回

这类通知的 `retryCount` 明确为 0. 保护结果对时间高度敏感, 立即提交失败后再重试可能已经不相关. 一般通知可以重试一次, 保护通知宁可漏发也不迟到误报

## 防睡眠停止

低电量或最长时长导致防睡眠停止时, `KeepAliveController` 先撤销 CodexBarHelper 租约并等待 `SleepDisabled=0` 的回读确认

确认后才提交通知. App idle assertion 会保留到通知提交结束, 避免合盖机器在通知交给系统前立即睡下. 随后 controller 释放 assertion 并按需补发合盖睡眠

这保证通知文字描述的是已经完成的系统级恢复, 同时让异步提交有机会收口

## 声音

[`NotificationSoundOption.swift`](../../CodexBar/Services/Notifications/NotificationSoundOption.swift) 汇总 3 类选择

- 无声音
- macOS 可用系统声音
- App bundle 内置声音

内置声音位于 [`NotificationSounds`](../../CodexBar/Resources/NotificationSounds)

已保存的声音名称在新系统或新版 App 中不存在时, 回退到默认声音, 不阻断通知

不同通知分类可以保存各自的声音设置

声音选项保存稳定 ID, 而不是绝对文件路径

- 内置声音通过 bundle resource 解析
- 系统声音首次访问时扫描用户, Local 和 System 声音目录
- `/Network/Library/Sounds` 刻意不扫描, 自动挂载点探测可能阻塞 UI
- 同名声音按系统查找顺序选择靠前目录
- 内置 ID 预先保留, 防止本机同名文件在重启后改变已保存选项的含义
- 已保存 ID 无法解析时回退 system default

system default 和静音不可试听. 用系统 alert sound 冒充通知中心默认音会给用户错误预期, 因此预览只支持有明确文件的系统音和内置音

## 触觉反馈

触觉反馈默认关闭. 开启后使用 10 次脉冲, 每次间隔约 100 ms

触觉是系统通知之外的独立本地反馈. 它响应非匿名任务的完成或等待 transition, 服从通知总开关和触觉开关, 但不依赖系统通知授权, 分类通知开关或完成时长阈值

这种分离让用户可以关闭 banner 仍保留统一的任务触觉. 上游 transition 仍必须真实有效, bootstrap 历史和匿名任务不会触发

## 提交与去重

通知通过 `UNUserNotificationCenter` 提交

- 单次提交失败最多重试 1 次
- 已发送 dedup key 保存到 UserDefaults
- 最多保留 300 个 key
- key 必须包含足够的账户或任务范围, 避免不同对象相互压制
- 过期或不再相关的 waiting key 会被移除

持久化去重避免 App 重启后立即重复发送同一事件, 但不能替代上游任务 terminal 去重

### 两层去重解决不同问题

`submittingDedupKeys` 和 `sentDedupKeys` 不能合并

| 集合 | 生命周期 | 防止的问题 |
| --- | --- | --- |
| `submittingDedupKeys` | 当前异步提交期间 | 两个同步调用在第一个 `await` 前同时通过检查 |
| `sentDedupKeys` | UserDefaults, 最多 300 条 | App 重启后重复发送同一业务周期 |

dedup 检查和 `submitting` 插入在创建 Task 前同步完成, 因此正确性不依赖 Swift task 调度顺序

只有 `UNUserNotificationCenter.add` 成功且事件在提交后仍相关时才写入 sent key. 如果提前记录, 一次系统提交失败会永久吃掉这条提醒

300 条上限防止 UserDefaults 变成无界事件日志. 这里接受很久以前的事件在 key 淘汰后理论上可能重现, 因为上游周期身份和实时 transition 去重仍是第一道边界

### 发送入口的统一语义

所有通知内容最终经过同一个 `send` 和 `deliver`

```text
同步检查 dedup
  -> 构造不可延迟的 notification request
  -> 提交前检查 relevance
  -> 调用系统中心
  -> 提交后再次检查 relevance
  -> 成功后持久化 dedup
  -> 失败时最多重试一次并执行分类清理
```

日志只记录 `kind` 和失败原因, 不记录 title 或 body. 通知正文可能包含项目名和任务信息, 即使日志位于本机也不应复制这些内容

## 前台展示与点击

App 是 `LSUIElement`, 通知中心 delegate 明确允许 App 在前台时继续展示 banner 和声音

用户点击通知后打开主面板. 打开动作通过状态栏控制器执行, 复用现有 popover 或 fallback panel 逻辑

前台展示由 notification center delegate 显式返回 banner, list 和 sound. `LSUIElement` App 经常保持前台或处于特殊 activation 状态, 依赖系统默认前台策略会让用户感觉通知随机消失

点击处理不直接创建新窗口, 而是调用 `openMenuSurface`. 这保证锚点有效时复用 popover, 锚点无效时使用 fallback panel, 并继续遵守同一套焦点和 dismiss 规则

## 新增通知类型的实现清单

1. 明确输入是快照, 转场还是已确认副作用结果
2. 定义账户, 窗口, task 或 attempt 作用域的身份
3. 决定是否需要会话去重, 持久化去重和 relevance 检查
4. 明确 bootstrap, stale 数据和匿名任务是否允许触发
5. 选择声音和失败重试语义
6. 确认正文中的敏感字段不会进入日志
7. 为设置默认值和旧 UserDefaults 缺失值定义行为
8. 验证前台展示, 点击激活和事件失效后的撤回

## Codex TUI 通知

设置页中的 Codex TUI 通知是 Codex 自身配置, 通过 app-server 的 `config/batchWrite` 读写

它与 CodexBar 系统通知完全独立

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

# 防睡眠系统

## 设计目标

防睡眠功能需要同时满足 3 个目标：

- 有符合条件的 Codex 任务时阻止 Mac 空闲睡眠
- App 退出、崩溃或失联后可靠恢复系统设置
- 不覆盖用户或其他应用已经设置的系统级防睡眠状态

普通 App 进程负责策略和用户界面，CodexBarHelper 只执行受限的系统睡眠与唤醒操作：

```text
CodexActivityMonitor
  -> KeepAliveController
      -> App IOKit assertion
      -> XPC lease
          -> CodexBarHelper
              -> /usr/bin/pmset

AutoResetController
  -> AutoResetWakeScheduler
      -> XPC wake date
          -> CodexBarHelper
              -> IOPMSchedulePowerEvent
```

## 为什么这不是一个 assertion 开关

防睡眠表面上像一个布尔设置，实际上同时跨越用户意图、实时任务、电源状态、App 生命周期和 root 系统状态。任何一层都可能先于其他层变化，因此实现不能把 `isEnabled` 直接等同于系统已经禁止睡眠。

系统把状态拆成 4 层：

| 层级 | 代表字段 | 回答的问题 |
| --- | --- | --- |
| 用户意图 | `isEnabled` | 用户是否希望使用功能 |
| 决策条件 | `sleepBlockReason` | 当前是否满足生效条件 |
| 请求状态 | `appliedSleepPreventionRequested` 和 `requestInFlight` | App 最近向 helper 请求了什么 |
| 已确认效果 | `isPreventingSleep` 和 `sleepPreventionSource` | App 是否收到系统状态已经符合预期的证据 |

这种区分解决了两个容易被 UI 掩盖的问题：

- helper 暂时不可用时保留用户开关，修复依赖后可以自动恢复，不需要用户重新开启
- XPC 请求发出但尚未确认时不提前显示成功，避免界面和系统实际状态相反

`sleepBlockReason` 是所有条件的唯一决策出口。UI 派生状态、条件日志和实际切换都读取同一个结果，新增条件时必须在一个有穷的 `switch` 中说明设置入口是否仍应可用。这是一处刻意的防遗漏设计。

## App assertion 与系统设置为什么并存

两套机制的作用域不同：

| 机制 | 生命周期 | 作用 | 失效方式 |
| --- | --- | --- | --- |
| IOKit assertion | App 进程 | 阻止空闲系统睡眠，可选阻止显示器睡眠 | App 退出后由系统自动回收 |
| `pmset disablesleep` | 系统全局 | 覆盖 assertion 无法保证的系统睡眠路径 | 必须显式恢复，因此需要 ownership 和 watchdog |

只使用 assertion 的恢复成本低，但能力不完整。只使用 `pmset` 的能力更强，但 App 崩溃后可能留下全局状态。CodexBar 同时使用两者，并把高风险的全局状态交给最小权限 helper 管理。

App 侧 assertion 会在 XPC 获取流程开始前建立。这样 helper 切换期间不会出现短暂的空闲睡眠窗口。如果 helper 请求失败，统一清理路径会释放 assertion，避免形成只有 App 自己知道的半成功状态。

## 获取与释放是确认式事务

获取流程不是先改 UI 再异步补系统操作，而是一个带验证的事务：

```text
条件求值为允许
  -> 建立 App idle assertion
  -> 标记 helper 可能已经收到租约
  -> 发送带 generation 的 XPC 请求
  -> helper 读取当前 SleepDisabled
  -> 必要时写入并回读验证
  -> App 校验来源和实测值
  -> 发布已生效状态并开始累计时长
```

释放流程按相反方向收口：

```text
条件求值为阻断
  -> 请求 helper 撤销租约
  -> helper 仅在 owned 且无其他租约时恢复系统值
  -> App 收到实测结果
  -> 发布未防睡眠状态并释放 display assertion
  -> 停止时长累计
  -> 提交低电量或时长上限通知
  -> 释放 App idle assertion
  -> 必要时补发合盖睡眠
```

通知放在 helper 确认 `SleepDisabled=0` 之后，是为了保证用户看到的“已停止防睡眠”描述的是事实，而不是尚未完成的意图。

App idle assertion 会多保留到通知提交结束。合盖机器在全局设置恢复后可能立即睡下，如果先释放最后一条 assertion，通知请求可能来不及交给系统。提交完成后立即释放 assertion 并执行合盖边沿补偿，这段短暂顺序不会重新声明系统所有权。

## `mayHaveHelperLease` 为什么不能在超时时清除

XPC 超时只证明 App 没收到回复，不证明 helper 没执行请求。请求可能已经把租约写入 helper，只是回复在连接断开时丢失。

因此 `mayHaveHelperLease` 采用保守语义：

- 请求获取时立即设为 `true`
- 超时或连接失效时保持 `true`
- 只有一次已确认的释放结果才能清为 `false`

这会让退出流程多做一次幂等释放，但能避免 App 误以为没有租约而直接退出。对全局系统状态而言，多释放一次的成本远低于遗留 `SleepDisabled=1`

## generation 解决什么竞态

用户关闭开关、任务结束和重试可能在前一条 XPC 回复返回前连续发生。如果只按回复到达顺序更新状态，旧的“获取成功”可能覆盖新的“释放成功”。

App 和 helper 都使用单调递增 generation：

- App 只接收当前 `requestGeneration` 的回调
- helper 忽略比现有租约 generation 更旧的请求
- 连接作废时 App 推进 generation，让在途回调自然失效

generation 不是用来给请求排序的日志编号，而是异步状态提交的资格证明。

## 生效条件

[`KeepAliveController.swift`](../../CodexBar/Services/KeepAlive/KeepAliveController.swift) 只有在以下条件全部成立时才建立防睡眠：

- 防睡眠主开关已开启
- Hook 已启用且校验通过
- 至少存在一个符合设置的实时任务
- CodexBarHelper 已安装并可连接
- 未触发低电量阈值
- 未达到单次最长防睡眠时长
- App 不在终止流程

等待批准任务默认不计入有效任务，用户可以单独开启。异常会话保护抑制的任务也不再维持防睡眠。

`KeepAliveController` 会先从运行中和等待批准快照中排除 `isAnonymous` 任务。只有非匿名任务能够进入运行任务集合，启动新一轮最长时长计时或维持防睡眠。

控制器会发布明确的阻塞原因：

| 原因 | 含义 |
| --- | --- |
| `notStarted` | 服务尚未启动 |
| `userOff` | 用户关闭主开关 |
| `hookDisabled` | Hook 不可工作 |
| `noTasks` | 没有符合条件的任务 |
| `helperUnavailable` | CodexBarHelper 未安装或不可连接 |
| `helperRefreshing` | CodexBarHelper 状态正在恢复或确认 |
| `terminating` | App 正在退出 |
| `lowBattery` | 电池低于阈值 |
| `limitReached` | 达到单次时长上限 |

## App 侧 assertion

[`SystemSleepService.swift`](../../CodexBar/Services/KeepAlive/SystemSleepService.swift) 使用 IOKit 建立 `PreventUserIdleSystemSleep` assertion。

如果用户开启保持显示器唤醒，还会建立 `NoDisplaySleep` assertion，并每 30 秒调用一次用户活动声明，避免显示器空闲计时提前生效。

App 侧 assertion 只覆盖当前进程生命周期。系统级 `SleepDisabled` 由 CodexBarHelper 管理，用于覆盖 assertion 无法保证的系统睡眠路径。

## CodexBarHelper 安装与通信

CodexBarHelper 通过 `SMAppService` 注册为 LaunchDaemon。App 和 CodexBarHelper 使用 [`CodexBarHelperXPC.swift`](../../Shared/CodexBarHelperXPC.swift) 定义的 XPC 接口。

接口只提供 4 类能力：

- 设置或撤销 App 租约
- 查询 CodexBarHelper 运行和拥有状态
- App 更新后重置 CodexBarHelper 状态
- 设置或取消 CodexBar 固定 owner 的下一次自动重置 `wake` 事件

自动重置与防睡眠共用 helper 注册和系统批准状态，但使用独立 XPC 连接。开启自动重置时，即使防睡眠主开关关闭，也会尝试注册 helper；尚未批准时，自动重置设置行会提供相同的状态和“打开系统设置”入口。

设置页把用户确认、helper 注册和 Helper 授权系统设置跳转分成独立职责：

- `HelperFeatureConfirmation` 为自动重置和防睡眠提供统一确认框，每次从关闭切换为开启时显示
- `.notRegistered` 与 `.notFound` 在确认框提示安装并授权后台运行，`.requiresApproval` 提示已安装但仍需授权，`.enabled` 只显示功能说明
- 用户确认后才调用 `AutoResetSettings.setEnabled(true)` 或 `KeepAliveController.setEnabled(true)`，取消时不写入开关状态
- `ensureHelperRegistration()` 只负责注册、刷新和后续协调，不负责打开 Helper 授权系统设置
- `AppSettingsView` 只在已开启设置行的 `.requiresApproval` 状态显示 `打开系统设置`，按钮调用 `KeepAliveController.openSystemSettings()`
- 自动重置选项入口要求开关已开启且 `helperStatus == .enabled`，条件失效时关闭已展开的自动重置面板
- 防睡眠选项入口读取 `KeepAliveController.canShowOptions`，没有任务、低电量阻断、达到上限或 helper 刷新期间仍允许调整设置
- 自动重置和防睡眠开关关闭时，设置行不显示状态说明

唤醒计划采用系统状态收敛而不是只依赖正常退出清理：

- helper 每次启动都在开放 XPC listener 前清除固定 owner 的遗留事件，App 重连后再按最新目标重新安排
- 设置成功必须回读到恰好一个时间匹配的事件，取消成功必须回读到零个事件
- 对应 XPC 连接断开时立即放弃内存所有者；取消失败会进入待清理状态，并由 helper 短周期重试
- App 退出会等待唤醒计划和防睡眠租约分别确认释放；helper 更新会先冻结唤醒同步，并在当前进程存在唤醒连接或已应用时间时显式取消计划
- `Scripts/cleanup.swift` 注销 helper 前会检查固定 owner；事件无法取消并回读清零时停止注销，避免同时失去最后一个具备清理权限的进程；注销成功后同时关闭防睡眠和自动重置，避免 App 下次启动时重新注册 helper

每个 App 进程生成稳定的 `clientSessionID`，XPC 重连期间保持不变。每次租约变更带单调递增 generation，CodexBarHelper 只接受更新的请求，避免迟到消息覆盖新状态：

- 单次 XPC 请求超时为 10 秒
- 连接丢失后 watchdog 宽限为 15 秒
- CodexBarHelper 每 5 秒检查租约和系统状态
- 异常状态每 60 秒尝试恢复

## CodexBarHelper 权限边界

[`CodexBarHelper/main.swift`](../../CodexBarHelper/main.swift) 以 root 运行，但能力被刻意限制：

- 系统睡眠切换只执行固定路径 `/usr/bin/pmset`
- 只使用固定参数读取或切换 `disablesleep`
- 只使用固定 owner 和固定 `wake` 类型设置或取消一个系统唤醒事件
- 唤醒接口只接受有限时间戳，不接受任意 owner、事件类型或命令
- 不接受任意命令或参数
- 不访问 Hook、rollout、账户或日志数据
- 不进行网络访问
- 不负责判断 Codex 任务状态

CodexBarHelper 从自身签名派生客户端 code-signing requirement，并应用到 XPC listener。未通过签名要求的客户端不能建立控制连接。

## 系统状态所有权

CodexBarHelper 先通过以下命令读取当前值：

```bash
/usr/bin/pmset -g
```

需要系统级防睡眠时只会执行固定操作：

```bash
/usr/bin/pmset -a disablesleep 1
```

释放时执行：

```bash
/usr/bin/pmset -a disablesleep 0
```

所有权规则是防止破坏外部状态的关键：

- 如果 CodexBarHelper 观察到初始值已经是 `1`，它把状态标记为 external
- external 状态不会被 CodexBar 声明为自己拥有
- CodexBar 只在亲自完成 `0 -> 1` 切换后记录 owned
- 只有 owned 状态才允许在租约结束时恢复为 `0`

因此，用户或其他工具预先开启的 `SleepDisabled=1` 不会在 CodexBar 退出时被关闭。

### ownership 文件如何构成恢复事务

helper 的持久化顺序刻意偏向可恢复：

```text
获取: persist owned -> pmset 1 -> read back 1
释放: persist restoring -> pmset 0 -> read back 0 -> persist idle
```

获取时先写 owned。如果进程在写文件后，`pmset 1` 前崩溃，下次启动多执行一次幂等 `pmset 0`，不会留下全局禁止睡眠。如果先写系统值再持久化，两步之间崩溃就会失去恢复责任。

释放时先写 restoring。如果在 `pmset 0` 或最终 idle 提交前崩溃，下次启动仍知道这是一笔未完成恢复。只有回读确认系统值为 `0` 后才允许持久化 idle。

### 外部来源消失后的接管

`external` 不是永久判断。CodexBar 在仍有有效任务时周期性读取 helper 缓存的系统状态：

- 外部来源仍存在时继续借用现有 `SleepDisabled=1`，不写系统设置
- 外部来源消失而任务仍在时重新申请租约，由 helper 完成新的 `0 -> 1`
- helper 已经因为其他有效客户端转为 owned 时更新来源展示，不重复创建计时周期

这项观察避免一个隐蔽空窗：用户先用其他工具开启防睡眠，CodexBar 因此判定为 external，随后其他工具关闭设置。如果 CodexBar 不重新观察，UI 会继续显示防睡眠，系统却已经可以睡眠。

## CodexBarHelper 状态持久化

CodexBarHelper 把系统所有权记录保存在：

```text
/Library/Application Support/CodexBar/helper-state.json
```

安全和可靠性要求如下：

- 当前 schema 为 `1`
- 目录由 root 拥有，权限为 `0755`
- 目录不能被 group 或 world 写入
- 文件由 root 拥有，权限为 `0600`
- 使用临时文件、full sync 和原子 rename 提交
- 启动时无法读取可信 owned 记录会执行恢复到 `disablesleep 0`

该文件记录 CodexBar 对系统睡眠设置的所有权。

自动重置唤醒事件不写入该文件。它由 macOS 电源管理保存，身份固定为当前 Debug 或 Release helper 的 mach service 名加 `.auto-reset`，类型固定为 `wake`。

## 租约与故障恢复

App 持有有效任务时保持带身份的 XPC lease。CodexBarHelper 不把一次请求解释为脱离连接的永久授权：

```text
租约有效 -> 保持 owned 状态
连接短暂断开 -> 等待 15 秒 watchdog
宽限内重连 -> 使用相同 clientSessionID 继续
宽限超时 -> 撤销租约并恢复 owned 状态
```

异常退出后，CodexBarHelper 依靠连接失效、watchdog 和持久化所有权共同恢复系统设置。

App 正常退出时先取消自动重置唤醒计划，再撤销租约和 IOKit assertion。如果 CodexBarHelper 尚未确认两类 root 状态都已清理，App 终止流程会等待，避免在不确定状态下直接离开。

### 正常退出为什么可以被取消

`applicationShouldTerminate` 不能在未确认释放时直接返回允许。`prepareForTermination()` 会先停止新重试，取消可能存在的自动重置唤醒计划，再请求释放可能存在的租约，然后等待 helper 回读结果：

- 释放成功时继续终止
- 释放失败时取消本次终止，恢复正常条件求值和重试

取消退出看似比直接关闭更强硬，但这是可恢复性的一部分。正常退出是 App 唯一能主动确认 root 全局状态的机会，不应主动放弃这次确认。强制退出仍由 helper 的 15 秒 watchdog 兜底。

### helper 自检不是只看进程存活

helper 会分别检查 lease、ownership 记录和实测 `SleepDisabled`

- owned 且仍有租约时，若系统值被外部改回 `0`，helper 会重新建立 `1`
- owned 且已无租约时恢复 `0`
- external 时只观察，不把外部状态写成自己的 ownership
- 持久化记录不可信时采取 fail-safe 恢复，不把损坏记录当成继续持有权限的依据
- 自动重置唤醒事件取消失败且已经没有连接所有者时，每 5 秒继续回读并清理固定 owner

这里的周期检查不是替代事件驱动 XPC，而是修复系统设置被其他进程改写、回调丢失或进程重启造成的事实漂移。

## 时长和电池策略

单次时长只统计实际处于防睡眠的时间：

- 没有任务时暂停或重置周期
- 新一轮任务可以开始新的周期
- 默认上限为 12 小时
- 可选 1, 2, 4, 8, 12, 24 小时或无限制

低电量停止只在使用电池供电时生效：

- 可选阈值为 5%, 10%, 15%, 20%, 25%
- 默认关闭
- 恢复使用 5 个百分点滞回，避免电量在阈值附近反复切换

防睡眠因低电量或时长上限结束时，通知必须在睡眠状态已经恢复后发送。

### 时长周期如何定义

“单次最长时长”不是从任务出现到任务消失的墙钟时间，而是系统实际被 CodexBar 挡住睡眠的累计时间。

`KeepAliveDurationLimiter` 使用 `SuspendingClock`

- 系统睡眠期间时钟暂停，醒来后不会把睡眠时间误算为防睡眠时间
- helper 不可用、低电量或其他条件阻断期间暂停累计
- 新运行任务出现时开始新周期
- 等待任务恢复运行时开始新周期
- 同一批任务只是在运行和观察之间刷新快照时不重复清零

`hasReached` 是当前周期内的粘滞状态。达到上限后不能因为一次普通快照刷新立即恢复，只有明确的新任务周期或设置变化才能重新求值。

任务集合使用稳定 task ID 判断“新任务”和“等待后恢复”，而不是只比较数量。如果一个任务结束同时另一个任务开始，数量仍为 1，但新的任务应得到完整时长预算。

### 电池读取为何是三态

电池读取使用 `unavailable`, `unreadable` 和 `present` 三态，不能压成一个可选值：

| 状态 | 含义 | 策略 |
| --- | --- | --- |
| `unavailable` | 已确认没有内置电池 | 隐藏低电量设置并清除阻断 |
| `unreadable` | 本轮 IOKit 读取失败 | 保留上一次结论 |
| `present` | 有可信电量和供电来源 | 正常执行阈值判断 |

读取失败时维持上一次状态，是为了避免一次 IOKit 枚举缺口让设置行闪烁，也避免正在生效的低电量保护被瞬时解除。一台机器只要曾经读到电池，后续空列表就按 `unreadable` 处理，因为硬件不会在运行中消失。

是否使用电池通过 power source state 判断，不能通过 `isCharging` 推断。接通电源但停止充电时 `isCharging` 也是 false，此时电量并没有被任务持续消耗。

### 低电量锁存与滞回

阈值为 `T` 时，进入条件是电池供电且电量不高于 `T`，退出条件是电量至少达到 `T + 5`

这 5 个百分点不是展示层修饰，而是状态机滞回。没有它时，电量在阈值附近的测量抖动会反复执行 root 写入、assertion 切换和通知判断。

低电量通知还保留单轮锁存：

- 只有此前确实由 CodexBar 防止睡眠时才排队通知
- 只在恢复成功后记录已经通知
- 接上电源会解除当前阻断，但只有电量越过恢复门槛才结束这一轮锁存
- 修改阈值会开启新一轮，避免旧阈值的通知状态污染新设置

## 显示器常亮是附加效果

保持显示器唤醒只依赖“防睡眠已确认生效”和用户选项，不独立维持系统睡眠。

`NoDisplaySleep` 只能阻止显示器休眠，不能阻止屏保和闲置锁屏。因此实现还每 30 秒声明一次用户活动。声明会复用同一个 assertion ID，否则 `pmset -g assertions` 中会持续堆积同名记录。

显示断言失败只记独立错误，不覆盖主防睡眠结果。这是有意区分核心效果和附加效果，避免设置页把“屏幕没有保持常亮”误报成“系统防睡眠完全失败”。

assertion 名称使用 ASCII。某些系统版本中带中文的名称会在 `pmset -g assertions` 中显示为空，使诊断信息失去标识。

## 合盖恢复的边沿补偿

合盖睡眠是一个边沿事件。如果合盖时 `SleepDisabled=1`，系统错过该边沿后不会仅因为稍后恢复为 `0` 就再次自动评估。

CodexBar 在确认自己拥有的系统设置已恢复后读取 clamshell 状态。当盖子仍闭合且该硬件模式应因合盖睡眠时，主动请求一次系统睡眠。

补偿只用于 `.codexBar` 来源：

- external 状态不是 CodexBar 改写的，不能替外部所有者决定何时睡眠
- `SleepDisabled` 仍为 `1` 时不能请求
- 无法读取合盖状态时不猜测

这是典型的边沿事件修复，不能用“最终值已经正确”替代。

## 失败与重试策略

防睡眠采用有界重试，因为每次重试都会重新建立特权连接并可能启动 root 进程：

- 10 秒请求超时早于 15 秒 helper watchdog，App 先放弃不可信连接，helper 随后有机会清理租约
- 每次重试前重新比较期望状态，用户已经关闭功能时不会继续重试获取
- 重试耗尽后保留明确错误，不无限循环消耗系统资源
- 连接失效会立即释放 App assertion，避免 UI 已降级但进程仍永久阻止空闲睡眠
- 旧请求通过 generation 失效，不依赖每条取消路径都成功撤回底层消息

诊断时应区分 registration error 和 operation error。前者表示 helper 未安装、待批准或更新失败，后者表示已安装 helper 的某次切换没有得到可信结果。

自动重置唤醒计划使用独立的有界同步策略：

- 设置或替换失败后按 `2s, 4s, 8s, 16s, 32s, 64s` 重试，耗尽后在自动重置设置行保留错误
- 正常退出或 helper 更新前按立即、`250ms`、`1s` 三次尝试取消并回读
- 目标时间距现在不超过 5 秒时不再登记系统事件，App 内任务直接进入到点执行路径
- XPC 连接丢失后清除 App 侧已应用状态并重新协调；helper 同时取消该连接拥有的固定事件

## CodexBarHelper 更新

App 更新可能改变内嵌 CodexBarHelper 的签名或内容。App 会记录 CodexBarHelper fingerprint，检测变化后通过 `SMAppService` 和重置接口刷新安装状态。

验证更新时需要同时检查：

- CodexBarHelper 位于 App 包的正确位置
- LaunchDaemon plist 与 Debug 或 Release bundle ID 匹配
- App 和 CodexBarHelper 签名匹配预期
- 首次系统授权流程可完成
- 更新后旧 owned 状态能够安全恢复
- 更新前自动重置唤醒计划已取消，新 helper 就绪后按当前目标重新登记

## 手动验证矩阵

- 运行任务开始和结束时，App assertion 与 CodexBarHelper 租约同步切换
- 等待批准设置关闭和开启时，有效任务判断正确
- 外部先设置 `disablesleep 1` 时，CodexBar 不声明所有权也不恢复为 `0`
- App 正常退出时恢复 owned 状态
- App 强制退出或 XPC 断开后，watchdog 恢复 owned 状态
- 自动重置和防睡眠每次开启都显示确认，取消后保持关闭
- 未注册、等待批准和已批准三种 helper 状态的确认文案与功能说明正确
- 开启操作只触发 helper 注册，Helper 授权系统设置仅由设置行的 `打开系统设置` 按钮打开
- 自动重置选项入口只在开关开启且 helper 已批准时显示，条件失效后已展开面板关闭
- 自动重置开启且防睡眠关闭时仍能完成 helper 注册与批准
- 未来阈值和重试只保留一个固定 owner 的 `wake` 事件，替换时不影响其他 owner
- 自动重置关闭、目标变化和正常退出时回读确认计划清零
- 自动重置 XPC 连接断开或 helper 重启时清理遗留计划
- `Scripts/cleanup.swift` 只在固定 owner 的计划确认清零后注销 helper
- 达到时长上限后先恢复睡眠再通知
- 低电量触发和 5% 滞回恢复正确
- 异常会话保护隐藏任务后释放防睡眠
- Debug 与 Release 版本的 CodexBarHelper 不混用

## 关键源码

- [`KeepAliveController.swift`](../../CodexBar/Services/KeepAlive/KeepAliveController.swift)
- [`SystemSleepService.swift`](../../CodexBar/Services/KeepAlive/SystemSleepService.swift)
- [`HelperRuntimeStatusMonitor.swift`](../../CodexBar/Services/KeepAlive/HelperRuntimeStatusMonitor.swift)
- [`AutoResetWakeScheduler.swift`](../../CodexBar/Services/KeepAlive/AutoResetWakeScheduler.swift)
- [`KeepAliveDurationLimiter.swift`](../../CodexBar/Services/KeepAlive/KeepAliveDurationLimiter.swift)
- [`PowerSourceMonitor.swift`](../../CodexBar/Services/KeepAlive/PowerSourceMonitor.swift)
- [`CodexBarHelperXPC.swift`](../../Shared/CodexBarHelperXPC.swift)
- [`CodexBarHelper/main.swift`](../../CodexBarHelper/main.swift)

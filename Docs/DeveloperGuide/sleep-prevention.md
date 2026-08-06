# 防睡眠系统

## 设计目标

防睡眠功能需要同时满足 3 个目标：

- 有符合条件的 Codex 任务时阻止 Mac 空闲睡眠
- App 退出，崩溃或失联后可靠恢复系统设置
- 不覆盖用户或其他应用已经设置的系统级防睡眠状态

普通 App 进程负责策略和用户界面，CodexBarHelper 只执行受限的系统睡眠操作：

```text
CodexActivityMonitor
  -> KeepAliveController
      -> App IOKit assertion
      -> XPC lease
          -> CodexBarHelper
              -> /usr/bin/pmset
```

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

接口只提供 3 类能力：

- 设置或撤销 App 租约
- 查询 CodexBarHelper 运行和拥有状态
- App 更新后重置 CodexBarHelper 状态

每个 App 进程生成稳定的 `clientSessionID`，XPC 重连期间保持不变。每次租约变更带单调递增 generation，CodexBarHelper 只接受更新的请求，避免迟到消息覆盖新状态：

- 单次 XPC 请求超时为 10 秒
- 连接丢失后 watchdog 宽限为 15 秒
- CodexBarHelper 每 5 秒检查租约和系统状态
- 异常状态每 60 秒尝试恢复

## CodexBarHelper 权限边界

[`CodexBarHelper/main.swift`](../../CodexBarHelper/main.swift) 以 root 运行，但能力被刻意限制：

- 只执行固定路径 `/usr/bin/pmset`
- 只使用固定参数读取或切换 `disablesleep`
- 不接受任意命令或参数
- 不访问 Hook，rollout，账户或日志数据
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
- 使用临时文件，full sync 和原子 rename 提交
- 启动时无法读取可信 owned 记录会执行恢复到 `disablesleep 0`

该文件记录 CodexBar 对系统睡眠设置的所有权。

## 租约与故障恢复

App 持有有效任务时定期续租。CodexBarHelper 不把一次 XPC 请求解释为永久授权：

```text
租约有效 -> 保持 owned 状态
连接短暂断开 -> 等待 15 秒 watchdog
宽限内重连 -> 使用相同 clientSessionID 继续
宽限超时 -> 撤销租约并恢复 owned 状态
```

异常退出后，CodexBarHelper 依靠连接失效，watchdog 和持久化所有权共同恢复系统设置。

App 正常退出时先撤销租约和 IOKit assertion。如果 CodexBarHelper 尚未确认恢复，App 终止流程会等待，避免在不确定状态下直接离开。

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

## CodexBarHelper 更新

App 更新可能改变内嵌 CodexBarHelper 的签名或内容。App 会记录 CodexBarHelper fingerprint，检测变化后通过 `SMAppService` 和重置接口刷新安装状态。

验证更新时需要同时检查：

- CodexBarHelper 位于 App 包的正确位置
- LaunchDaemon plist 与 Debug 或 Release bundle ID 匹配
- App 和 CodexBarHelper 签名匹配预期
- 首次系统授权流程可完成
- 更新后旧 owned 状态能够安全恢复

## 手动验证矩阵

- 运行任务开始和结束时，App assertion 与 CodexBarHelper 租约同步切换
- 等待批准设置关闭和开启时，有效任务判断正确
- 外部先设置 `disablesleep 1` 时，CodexBar 不声明所有权也不恢复为 `0`
- App 正常退出时恢复 owned 状态
- App 强制退出或 XPC 断开后，watchdog 恢复 owned 状态
- 达到时长上限后先恢复睡眠再通知
- 低电量触发和 5% 滞回恢复正确
- 异常会话保护隐藏任务后释放防睡眠
- Debug 与 Release 版本的 CodexBarHelper 不混用

## 关键源码

- [`KeepAliveController.swift`](../../CodexBar/Services/KeepAlive/KeepAliveController.swift)
- [`SystemSleepService.swift`](../../CodexBar/Services/KeepAlive/SystemSleepService.swift)
- [`HelperRuntimeStatusMonitor.swift`](../../CodexBar/Services/KeepAlive/HelperRuntimeStatusMonitor.swift)
- [`KeepAliveDurationLimiter.swift`](../../CodexBar/Services/KeepAlive/KeepAliveDurationLimiter.swift)
- [`PowerSourceMonitor.swift`](../../CodexBar/Services/KeepAlive/PowerSourceMonitor.swift)
- [`CodexBarHelperXPC.swift`](../../Shared/CodexBarHelperXPC.swift)
- [`CodexBarHelper/main.swift`](../../CodexBarHelper/main.swift)

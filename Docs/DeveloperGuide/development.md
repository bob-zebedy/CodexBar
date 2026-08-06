# 开发与验证

## 环境要求

- macOS 15 或更高版本
- Xcode 和 macOS SDK
- Swift 6 toolchain
- `swiftformat`
- `swiftlint`
- 本机可用的 Codex CLI 或包含内置 Codex 的 App

工程使用 `CodexBar` scheme，日常构建不需要 Developer ID 或公证凭据。

## 工程结构

| 目录 | 职责 |
| --- | --- |
| `CodexBar/App` | App 启动入口 |
| `CodexBar/Controllers` | AppKit 生命周期、菜单栏和窗口控制 |
| `CodexBar/Models` | 业务 DTO、快照和展示模型 |
| `CodexBar/Services` | app-server、Hook、任务、同步、通知和系统服务 |
| `CodexBar/Views` | SwiftUI 界面 |
| `CodexBar/Resources` | plist、entitlement、本地化和资源 |
| `CodexBarHelper` | root LaunchDaemon |
| `Shared` | XPC 共享接口 |
| `Config` | 版本配置 |
| `Scripts` | 发布和维护脚本 |

## 第一次阅读代码的建议顺序

不要从 View 反向猜业务状态。推荐沿事实流阅读：

1. 从 [`CodexBarApp.swift`](../../CodexBar/App/CodexBarApp.swift) 确认 Hook 子进程分流
2. 从 [`StatusItemController.swift`](../../CodexBar/Controllers/StatusItemController.swift) 查看普通模式 composition root
3. 选择一条数据链路阅读 source, service, snapshot 和 ViewModel
4. 再看通知或防睡眠如何订阅上游结果
5. 最后查看 SwiftUI 如何展示状态和发出用户意图

以实时任务为例：

```text
WorkflowHookEventRecorder
  -> HookEventTailReader
  -> CodexActivityMonitor
  -> CodexActivitySnapshot / CodexActivityTransition
  -> StatusItemController 组装
      -> UI
      -> CodexNotificationService
      -> KeepAliveController
```

先找到 authoritative state 能避免把 UI 缓存、通知去重集合或 controller 中间态误认为业务事实。

## 修改前先写清楚 5 件事

实现一个非纯视觉变化前，至少在设计或开发笔记中回答：

| 问题 | 示例 |
| --- | --- |
| 目标事实 | “任务已经等待用户批准”，而不是“显示橙点” |
| 权威来源 | reviewer 确认后的 Hook event |
| 派生消费者 | 活动卡片、通知、防睡眠 |
| 失败语义 | reader 不可用时暂停判定 |
| 验收证据 | 转场一次、不补发 bootstrap、恢复后对账 |

这一步的价值不是增加流程，而是提前发现一个字段被 3 个副作用消费者赋予了不同含义。

## 常见改动应该落在哪一层

| 改动 | 首选位置 | 避免放置 |
| --- | --- | --- |
| app-server 协议 method | `CodexStatus/` service 和 DTO | SwiftUI View |
| Hook 原始字段 | recorder model 和 aggregation projection | CloudKit record 直接读取 stdin |
| 实时任务转场 | `CodexActivityMonitor` | 通知服务从历史列表推断 |
| 日统计展示 | `WorkflowViewModel` 投影 | View 重新合并 raw event |
| 系统通知 | `CodexNotificationService` | 按钮 action 或 View lifecycle |
| 防睡眠条件 | `KeepAliveController.sleepBlockReason` | 多个 UI computed property |
| 窗口行为 | AppKit Controller | service 或 model |
| 用户默认值 | 对应 Settings 类型 | 分散的 `UserDefaults.standard` 调用 |

小改动优先延伸现有类型职责。只有当新能力拥有独立生命周期、状态所有权或故障边界时才值得新建 service。

## 日常检查

### 构建

```bash
xcodebuild \
  -project CodexBar.xcodeproj \
  -scheme CodexBar \
  -destination 'generic/platform=macOS' \
  build
```

### 格式化

```bash
swiftformat .
```

工程使用 Swift 6 和 4 空格缩进，配置位于 `.swiftformat`

### 静态检查

```bash
swiftlint
```

规则位于 `.swiftlint.yml`

仓库当前没有 XCTest target 或覆盖率门槛。构建、格式化和 lint 不能替代受影响流程的手动验证。

### 推荐检查顺序

```text
检查工作树范围
  -> 完成最小实现
  -> swiftformat
  -> 审查格式化 diff
  -> swiftlint
  -> xcodebuild
  -> 针对性手动验证
  -> git diff --check
```

先格式化再构建可以让最终验证覆盖真正准备提交的代码。但仓库已有用户未提交改动时，不应无差别格式化整个仓库造成无关修改。先用 `git status --short` 和 `git diff --name-only` 确认范围，必要时只格式化本次触及的 Swift 文件。

`xcodebuild` 验证 Swift 6 并发检查、target membership、entitlement 和资源引用。`swiftlint` 验证风格与部分静态规则。两者不能验证 AppKit focus、XPC crash recovery 或通知 relevance。

纯文档变更仍按仓库约定运行格式化、lint 和构建。这些检查不验证文档内容，因此还要额外检查 Markdown 相对链接、`git diff --check` 和仓库中文标点规则。

### 如何读构建失败

优先找第一条实际 `error:` 而不是最后的 `BUILD FAILED`

- actor isolation error 通常说明状态所有权不清，不应先加 `nonisolated(unsafe)` 压掉
- missing file 或 resource error 先检查 target membership 和 Xcode project 引用
- helper protocol error 需要同时检查 App target、Helper target 和 `Shared` 接口
- entitlement 或 signing error 要先确认当前是 Debug 还是 Release identity

修复第一处根因后重新构建，后续大量泛型或 module error 往往只是级联结果。

## 日志

查看 Release 系统日志：

```bash
/usr/bin/log stream \
  --predicate 'subsystem == "app.zabrian.codexbar"' \
  --style compact
```

Debug subsystem 带 `.debug` 后缀。

App 内日志窗口展示当前进程最近 500 条 app-server 交互日志，适合排查 CLI 定位、handshake、method unsupported 和重试。

### 日志应回答什么

一条有用状态机日志应至少能回答：

- 谁触发了本轮操作
- 当前想达到什么状态
- 哪个阶段失败
- 采取了什么降级或重试动作
- 操作耗时和处理规模

仓库使用 `LogTrigger`, `LogDuration` 和 `LogFields.joined` 统一这些字段。高频轮询只在状态翻转或结果变化时记录，避免真正异常被空转日志覆盖。

推荐用稳定英文 key 加受控值，例如：

```text
trigger=wake want=0 reason=lowBattery elapsed=0.183s
```

不要记录通知正文、完整路径、identity 或 token。如果错误的 `localizedDescription` 可能包含敏感请求信息，应先做错误分类再记录。

### 按 subsystem 和阶段排查

| 症状 | 优先日志和状态 |
| --- | --- |
| 额度不刷新 | app-server handshake, method, retry, stale |
| Hook 没有统计 | hooks 配置、recorder timeout、maintenance counts |
| 实时任务卡住 | tail reader generation, rollout reconcile, data source availability |
| 同步缺数据 | sync stage、local 和 confirmed 数量、replacement dates |
| 通知不出现 | authorization, kind, duplicate 或 obsolete |
| 防睡眠不生效 | block reason, helper registration, XPC generation, source |

## Debug 与 Release

两种配置使用不同身份：

| 配置 | App bundle ID | CodexBarHelper bundle ID |
| --- | --- | --- |
| Release | `app.zabrian.codexbar` | `app.zabrian.codexbar.helper` |
| Debug | `app.zabrian.codexbar.debug` | `app.zabrian.codexbar.debug.helper` |

排查 CodexBarHelper 安装、LaunchDaemon 或系统授权时不要混用两个配置。

Hook handler 绑定当前 App 可执行文件路径。在 Debug 和 Release 之间切换时，先确认实际安装的 handler 指向目标版本。

### 为什么两个构建仍会共享部分状态

Debug 和 Release bundle ID 分离是为了让 App、helper 注册和系统授权互不覆盖。但 Hook 原始数据与 Activity Protection 需要观察同一个 Codex 工作事实，因而按设计共享文件。

共享意味着：

- 文件写入必须使用 `flock`，actor 只保护单进程
- schema 必须在两个版本共存时可解释
- identity hash 算法变化会同时影响两个构建
- 排查时要记录哪个 App 正在写，哪个 helper 正在控制系统

不要用修改目录名的方式临时隔离 Debug，这会改变产品定义的数据来源并掩盖真实共存问题。

## 架构规则

### 启动入口

`WorkflowHookEventRecorder.handleIfRequested()` 必须是 App 初始化的第一项工作。

`--hook-event` 模式只读取 stdin，加锁写入 JSONL 并立即退出。不初始化 UI、通知、CloudKit 或其他长期服务。

### MainActor

UI, Controller, ViewModel 和 Settings 依赖默认隔离。阻塞文件、子进程和网络 I/O 放入 actor 或异步服务。

共享可变状态放入 actor。DTO 和跨 actor 值类型按需要补充并发声明，不通过关闭检查绕过 Swift 6 诊断。

#### MainActor 不是 I/O 队列

工程默认隔离让 UI 状态修改更清晰，但不意味着文件和子进程工作可以同步执行在主线程。

合适的模式是：

```text
MainActor 捕获不可变输入
  -> actor 或 async API 执行 I/O
  -> 返回 Sendable 结果
  -> MainActor 校验 generation
  -> 提交快照
```

不要把可变 controller 或 non-Sendable AppKit 对象传入后台 closure。需要跨 actor 的 DTO 应尽量是小型 value type，并让 `nonisolated` 表达类型本身不依赖 actor，而不是绕开某个具体访问错误。

#### actor 与 `flock` 解决的问题不同

- actor 串行化同一进程中的 task
- `flock` 协调 App、Hook 子进程、Debug 和 Release 等多个进程

一个 actor 内安全的 read-modify-write 仍可能被另一个进程打断。反过来，只有 `flock` 也不能自动保护 actor reentrancy 中 await 前后的内存状态。

#### `@Published` 的 `willSet` 语义

Combine sink 收到新值时，发布对象的属性可能仍是旧值。需要基于变化后组合状态决策时：

- 使用 sink 参数作为正在变化的值
- 其余未变化依赖可以从对象读取
- 或把完整新状态封装成一个快照再发布

仓库中的同步 activation 和低额度阈值重判都依赖这一规则。将回调参数改成现场读取会产生一帧反向决策。

### 数据链路

保持以下链路独立：

- app-server 账户、额度与用量
- Hook 历史聚合
- `CodexActivityMonitor` 实时任务

新增 UI 可以组合 3 条链路的快照，但不能让一条链路成为另一条链路的隐式前置条件。

组合只能发生在展示或显式业务策略层。例如菜单栏可以同时展示额度条和活动点，但 app-server 失败不能阻止 activity monitor 更新，Hook maintenance 也不能等待 CloudKit 才发布本机统计。

新增跨链路行为时应写出 truth table。防睡眠就是一个合法例子：它明确声明需要 Hook 可用和非匿名实时任务，而不是因为两个对象恰好在同一 controller 中就形成依赖。

### Hook

- handler 修改保留现有用户和第三方配置
- 启用与校验检查实际 app-server 版本不低于 `0.145.0`
- Hook 子进程失败不能阻断 Codex
- `SessionEnd` 超时为 3 秒，其他事件为 5 秒
- `drainNow()` 必须维持读取屏障语义
- 数据源不可用时不能使用旧快照继续判定

新增 Hook event 时要同时审查：

1. Codex 配置中的 handler group 和 timeout
2. recorder 白名单字段与 fail-open 路径
3. raw JSONL 解码的前后兼容
4. aggregation 的计数和 missing 语义
5. realtime monitor 是否消费该事件
6. CloudKit 投影是否需要新字段
7. 隐私文档和日志字段

不是每个 event 都需要进入全部层。明确写“不消费”比让下游依赖默认 decoder 行为更容易维护。

### 聚合

原始事件到聚合结果的算法、字段、含义或去重规则变化时：

1. 递增 `WorkflowMaintenanceState.currentAggregationSchema`
2. 从保留期内原始 JSONL 完整重建
3. 不增加字段级历史迁移
4. 保留 missing 与 `0` 的区别
5. 标记 CloudKit 当前设备 replacement 日期

schema 递增的判断标准是语义输出是否会因同一份 raw event 得到不同结果，而不是 Codable 是否还能解码。即使只修正去重规则，也必须重建，因为旧 daily 文件已经固化了错误结果。

完整重建优于字段级迁移，因为 raw JSONL 才是事实来源。字段级迁移必须猜测旧算法中丢失的信息，长期会堆积不可组合的历史分支。

### 防睡眠

- CodexBarHelper 只控制睡眠
- CodexBarHelper 不增加网络或任意命令能力
- 外部 `SleepDisabled=1` 不能被 CodexBar 声明或恢复
- 租约、watchdog 和 owned 持久化必须共同成立
- App 退出前确认系统状态恢复

修改防睡眠时先写出 acquire, release, timeout, crash 和 external-owner 5 条时序。只验证正常开关无法证明全局系统状态可恢复。

任何新增 helper 方法都要先证明必须由 root 执行。能在普通 App 完成的读取、网络或文件操作不得因为“方便复用”放进 helper。

### 兼容性

以下变化属于兼容性问题：

- 持久化 key 改名或结构变化
- 本地 schema 变化
- CloudKit record 或字段变化
- CodexBarHelper ownership 格式变化
- Debug 与 Release 共享身份计算变化
- 最低系统版本或 API 可用性变化

这些变化会影响旧数据、旧 App 或 Debug 与 Release 共存，需要配套的迁移和降级设计。

根据仓库约定，任何兼容性问题都不能由实现者默默选择。在修改前向用户说明：

- 受影响版本和数据范围
- 保留旧格式、一次迁移、完整重建或明确丢弃的可选方案
- 每种方案的失败模式和未来维护成本
- 是否支持旧 App 与新 App 同时运行
- 如何验证升级和必要时降级

得到选择后再实现。文档中记录最终不变量，不只记录迁移步骤。

## 常见改动配方

### 新增设置项

1. 在对应 Settings 或 controller 中定义唯一 key 和缺失时默认值
2. 明确旧用户升级后的值，不依赖 Swift 属性默认值碰巧一致
3. 把设置变化接入唯一 reconcile 入口
4. 避免 View 自己写 `UserDefaults`
5. 验证首次安装、已有安装和切换后立即生效

### 新增状态字段

1. 确认字段是事实、派生状态还是展示格式
2. 放入最靠近权威来源的 model
3. 定义 `nil`, empty, zero 和 stale
4. 检查 Equatable snapshot 是否应因它变化
5. 检查通知、防睡眠和 UI 是否需要消费
6. 如需持久化或同步，先走兼容性与隐私审查

### 新增异步刷新

1. 确定触发来源和 freshness 规则
2. 使用 single-flight 或 coordinator 合并同类请求
3. 为连接或 source replacement 增加 generation
4. 在 await 后重新验证当前资格
5. 定义取消、超时和最后可用快照策略
6. 只在状态变化或最终结果记录日志

### 新增窗口或侧边面板

1. 决定它属于菜单交互表面还是独立辅助窗口
2. 复用 `HostingWindowController` 或 `MenuSideDetailPanel`
3. 加入互斥名册和 extra hit region
4. 处理多屏 visible frame 和 Space
5. 验证 key focus、activation 和关闭动画中间态

## 按改动类型验证

### 菜单和窗口

- 左键、右键和 Control 点击行为
- popover 外部点击关闭
- 侧边面板 hit region 和互斥
- 设置与日志窗口焦点
- 全局快捷键和 fallback panel
- 多显示器与不同菜单栏位置

### Hook 和聚合

- 保留已有 handler
- 版本不满足时拒绝启用
- 所有事件能在超时内落盘
- 文件替换、截断和跨日读取
- schema 升级完整重建
- missing 字段不会显示为 `0`

### 实时任务

- 运行、等待批准、完成和中断转场
- auto review 不进入等待状态
- subagent 归属父任务
- bootstrap 不发送通知
- 系统唤醒完成新读取后再对账
- reader 更换时丢弃旧结果

### 同步

- 首次 backfill
- 多设备合并不重复本机贡献
- 重建只替换当前设备日期
- iCloud 离线、账户切换和恢复
- 保留期清理

### 通知

- 系统权限允许和拒绝
- 阈值 crossing 和持久化去重
- 前台展示与点击激活
- 自定义声音缺失回退
- TUI 通知与 App 通知互不影响

### 防睡眠

- App 包内 CodexBarHelper 和 plist 位置
- App 与 CodexBarHelper 签名
- 首次系统授权
- 运行与等待批准切换
- 低电量和最长时长停止
- 外部 `SleepDisabled` 共存
- 正常退出和异常退出恢复
- Debug 与 Release 分离

## 手动验证如何留下可复查证据

每个受影响流程至少记录：

- 使用的 Debug 或 Release 构建
- 前置设置和数据状态
- 操作序列
- 预期 UI 与实际 UI
- 对应日志关键字段
- 是否检查重启、失败和恢复路径

例如 Hook 唤醒恢复可以记录：

```text
前置: 1 个非匿名 running task, 防睡眠开启
操作: 让 Mac 睡眠后唤醒, rollout 在睡眠期间写入 terminal
预期: drainNow 新一轮成功后任务结束, 不发 bootstrap 通知, helper lease 释放
日志: trigger=wake, reader generation 更新, rollout reconcile 完成
```

这种记录比“手测通过”更容易在未来回归时重现。

## 完成定义

一项改动只有同时满足以下条件才算完成：

- 代码放在正确状态所有者中，没有复制第二份规则
- 正常、缺失、stale、失败和恢复语义明确
- 并发请求有取消或 generation 边界
- 兼容性和隐私影响已确认
- 格式化、lint 和构建按变更范围通过
- 受影响流程完成手动验证
- DeveloperGuide 与实际常量、schema 和行为一致
- `git diff` 中没有无关用户改动或意外格式化

## 发布脚本

以下脚本需要 Developer ID、签名、公证或 appcast 凭据，不用于日常验证：

- `Scripts/build.sh`
- `Scripts/dmg.sh`
- `Scripts/appcast.sh`

版本号从 [`Version.xcconfig`](../../Config/Version.xcconfig) 读取。

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 写作风格

本仓库的中文文本 (提交信息, 代码注释, 文档) 统一遵守

- 禁止使用中文标点, 一律使用半角标点
- 句中停顿和并列项使用空格或者逗号, 顿号的位置也用空格或者逗号
- 分号只用来断开完整句子, 相当于句号; 拿不准就把它换成句号读一遍, 两边都能独立成句才保留
- 行末禁止使用标点
- 行内标点后如果还有文字, 间隔一个英文空格
- 行内代码后尽量不要紧跟标点, 需要断句时补一个词或者使用空格再断
- 一条 bullet 只讲一件事, 需要两个以上完整句子时拆成多条

## 项目概述

CodexBar 是一个 macOS 菜单栏应用, 以 `LSUIElement` 方式运行, 没有 Dock 图标, 展示本机 Codex 的账号状态, 额度, Token 用量, 实时任务和工作流统计; 技术栈 Swift 6 + SwiftUI + AppKit + MVVM, 唯一外部依赖是 Sparkle 2.9.3+ (SwiftPM); 最低系统版本 macOS 15.0

Xcode 工程有两个 target: 主 App `CodexBar` 和随 App 嵌入的 root helper `CodexBarHelper` (command-line tool + LaunchDaemon); **没有测试 target**, 验证靠构建通过 + 实际运行

App Sandbox 未开启, entitlements 只声明 iCloud/CloudKit, 因为需要启动本机 `codex` 进程, 读取用户 Codex 登录状态, 写入用户级 Hook 配置

## 常用命令

```bash
# 日常编译验证 (唯一 scheme 是 CodexBar)
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build

# 格式化: 配置在 .swiftformat, 覆盖整个仓库 (Swift 6 语言模式, 4 空格缩进)
swiftformat .

# Lint: 配置在 .swiftlint.yml, included 只有 CodexBar/
# 即 Shared/ CodexBarHelper/ Scripts/ 不在 lint 范围内
swiftlint

# 查看系统日志; zsh 里 log 会和 shell 冲突, 必须写完整路径
# Debug 版把 subsystem 换成 app.zabrian.codexbar.debug, helper 进程另带 .helper 后缀
# BEGINSWITH 会同时命中 Debug 与 Release, 要分版本得用 == 或 IN
/usr/bin/log stream --predicate 'subsystem == "app.zabrian.codexbar"' --style compact
/usr/bin/log show --predicate 'subsystem == "app.zabrian.codexbar"' --last 30m --style compact

# 发布流程 (需要 Developer ID 凭据, 不要当普通本地验证跑)
Scripts/build.sh    # Release archive + Developer ID 导出 + notarize + staple + Gatekeeper 校验
Scripts/dmg.sh      # 打包 DMG
Scripts/appcast.sh  # sign_update 签名并写入 appcast.xml

# 注销 KeepAlive LaunchDaemon; 清理前需先退出所有 CodexBar 实例
# 不带参数时同时处理 Release 与 Debug 两套
# 常用: --release / --debug 限定范围, --check 只验证目标不真的注销
# 签名身份取环境变量 CODEXBAR_CLEANUP_SIGN_IDENTITY, 默认 Apple Development
Scripts/cleanup.swift --help
```

日常调试直接 `open CodexBar.xcodeproj` 用 Xcode 跑 Debug scheme; 注意 Debug 产物用的是 `app.zabrian.codexbar.debug` 这个 bundle ID, 与 Release 安装版可以共存, 排查防睡眠问题时要确认自己看的是哪一套 helper

`Scripts/build.sh` 会先清空 `Build/` 目录, 成功后只留最终产物 `.app` 文件; 凭据推荐用 keychain profile, 先跑一次 `xcrun notarytool store-credentials "codexbar-notary" --apple-id "<Apple ID>" --team-id "<Team ID>"` 存好, 之后构建加上 `--notary-profile codexbar-notary`

Debug 与 Release 使用不同 bundle ID, 分别是 `app.zabrian.codexbar.debug` 与 `app.zabrian.codexbar` 两个, helper 相应带 `.debug.helper` 与 `.helper` 后缀, 所以 `CodexBarHelper/` 下有两份 LaunchDaemon plist, `cleanup.swift` 也需要同时处理两套

## Git 规则

- 不要主动 push, 除非用户明确要求
- 不要回滚, 覆盖或丢弃不是你产生的未提交改动, 工作树可能是脏的
- 被要求提交时, **禁止**顺带修改任何文件内容: 不格式化, 不清理, 不补文档, 只把当前已有改动原样提交

Commit message: Conventional Commits 前缀 + 中文标题, 需要 body 时空一行后写 4 空格缩进 bullet

- 标题写成 `<type>: <中文描述>` 的形式, 不加句号; 常用 type 有 `feat` `fix` `chore` `refactor` `docs`
- message 里不要出现版本号或发布字样, 只描述改动本身, 版本信息由 tag 承载
- 功能 修复 发布类提交必须写 body; 简单文档或杂项可只写标题行
- body 中多条 bullet 连续排列, bullet 之间不空行
- 命令行提交时把完整 body 放进同一个 `-m` 参数或改用 `git commit -F` 传文件, 不要为每条 bullet 单独 `-m`
- message 中禁止使用中文标点, 行末禁止使用标点, 行内标点后如果有文字则间隔一个英文空格

```text
fix: 修复 Codex 状态刷新

    - 合并设置页 onAppear 和 didBecomeActive 的重复版本检测
    - 保留当前运行版本与磁盘安装版本不一致时的更新提示
```

Tag 名 `v{MARKETING_VERSION}` 里的版本号从 `Config/Version.xcconfig` 读取, 使用附注 tag `git tag -a v3.x.y -m "Release v3.x.y"`

## 架构

### 启动分流 (关键设计)

`CodexBar/App/CodexBarApp.swift` 的 `init()` 最先调用 `WorkflowHookEventRecorder.handleIfRequested()`

- 带 `--hook-event` 启动 -> **Hook 子进程模式**: 从 stdin 读 JSON payload, 在 `flock` 锁内追加一行 JSONL 后立即 `exit(EXIT_SUCCESS)` 退出, 绝不初始化菜单栏 UI; 写入失败静默吞掉, 不阻断 Codex
- Hook handler 超时统一由 `WorkflowHookEventRecorder.hookTimeoutSeconds(for:)` 提供, `SessionEnd` 是 3 秒, 其他事件是 5 秒; 等锁预算固定比对应事件超时少 2 秒, 当前分别是 1 秒和 3 秒
- 普通启动 -> `CodexBarAppDelegate` 创建全部长期对象, 它在 `Controllers/StatusItemController.swift` 内, 再由 `StatusItemController.install()` 装配菜单栏; AppDelegate 是唯一的装配点, 新增服务在这里注入

### 三条数据链路

**链路一: app-server (额度/用量)**

`CodexStatusService` (actor) -> `CodexCLIResolver` 解析 `codex` 可执行文件, PATH 全局优先, 回退 `/Applications/ChatGPT.app` 或 `Codex.app` 内置 -> 启动 `codex app-server --listen stdio://` -> `AppServerSession` 做 stdio JSON-RPC -> 合成 `CodexQuotaSnapshot` -> `CodexStatusViewModel` 发布给 UI

- 刷新间隔 60 秒, 请求超时 20 秒, 连接最长复用 1 小时, 让后台升级的 codex 二进制有机会生效
- 主要方法有 `initialize` `account/read` `account/rateLimits/read` `account/usage/read` `config/read` `config/batchWrite` `hooks/list`
- `SIGPIPE` 被忽略, app-server 退出后写管道由 write 抛错走重建路径
- stdout 可能混有无关日志行, `AppServerSession` 先用轻量 `RPCIDEnvelope` 匹配 id 再完整解码

**链路二: Hook 统计 (历史聚合)**

Hook 子进程按天写入 `~/Library/Application Support/CodexBar/HookEvents/events/YYYY-MM-DD.jsonl` 这类文件, 主 App 的 `WorkflowService` (actor) 增量聚合出 `daily.jsonl` 与 `WorkflowSnapshot` 供热力图详情面板展示; 可选跨设备同步由 `WorkflowSyncScheduler` (唯一调度者) 与 `WorkflowSyncService` 负责, 走 `iCloud.app.zabrian.codexbar` 容器的 CloudKit private database, 只上传脱敏 daily 聚合

- `WorkflowStorage` 管理的存储目录含 `events/` `daily.jsonl` `stats.lock` `maintenance.json` `Sync/` 五项
- 原始事件文件与 daily 聚合统一保留 210 天, 聚合里的会话与轮次标识只保留 3 天, 到期后只留下去重计数
- `WorkflowDailyAccumulator` 的全量与增量路径始终在内存收集完整 ID, 只有 `finalized(identifierStorage:)` 才决定保留或压缩; 已压缩的日期收到新事件时不能安全去重, 必须降级为从原始 JSONL 完整重建
- `WorkflowMaintenanceState.currentAggregationSchema` 是原始事件到 daily 聚合的算法版本; 缺少版本按 0 处理, 版本不一致时把仍有原始事件的日期全部标脏并走通用完整重建, 不写字段级历史迁移
- 需要从原始事件重新计算的聚合算法, 输出字段, 字段含义或去重规则变化时必须递增 `currentAggregationSchema`, 统一走相同的完整重建入口
- daily 与 CloudKit 中的 Hook 计数字段都是可选值; `nil` 表示来源版本没有提供或无法确认, 明确的 `0` 才表示已知没有对应事件, 解码和重建都不能把两者混为一谈

**链路三: 实时任务, 由 `CodexActivityMonitor` 驱动**

`CodexActivityMonitor` 是菜单栏图标, 活动卡片, 通知, 触觉反馈和防睡眠的**唯一任务状态来源**, 由两个 reader 供料

- `HookEventTailReader` (actor) 的 bootstrap 覆盖滚动 24 小时并作为单次事务发送, 之后按当日文件 offset 增量 tail, 同时向下游报告数据源健康状态
- `CodexSessionLifecycleReader` (actor) 增量读取 `~/.codex/sessions` 与 `archived_sessions` 下的 rollout JSONL, 只提取 turn 生命周期与最近进展时间, 不解码会话或工具内容
- 任务监控只在 `codexHookSettings.isOperable` 为 true 时运行, 即本地已安装且最近一次明确校验没有失败; 链路失效时立即停 reader 并清空实时状态
- `SessionEnd` 没有 `turn_id`, 收到后按 session 把对应任务立即移出活跃列表并放进 5 秒终态确认窗口; rollout 在窗口内补回准确的完成或终止分类, 超时后按终止处理
- `HookEventTailReader.drainNow()` 是读取屏障, 每个调用方等待一轮在本次请求之后开始的读取, 返回 `completed` `sourceUnavailable` 或 `cancelled`

系统唤醒时 `NSWorkspace.didWakeNotification` 先暂停异常会话保护. 读取屏障成功时重置生命周期解析回退并完成 rollout 对账后恢复判定; 数据源不可用时继续由 source health 门槛暂停, reader generation 变化时旧结果直接丢弃

#### 异常会话保护

- `CodexActivityProtection.swift` 管理异常会话保护状态机, `ActivityProtectionSettings` 只保存静默阈值; 保护开关跟随用户保存的 KeepAlive 主开关, 不依赖 helper 是否已获系统授权
- 静默阈值可选 30 分钟, 1, 2 或 4 小时, 默认 1 小时, UserDefaults key 固定为 `KeepAlive.abnormalTaskInactivitySeconds`
- 候选只包含 `.running` 任务, `.waitingApproval` 不参与异常判定; `lastProgressAt` 同时吸收 Hook 顶层事件, 子 Agent 事件与 rollout 行时间
- 达到阈值后先持久化候选记录并尝试提交本地通知, 通知使用系统默认声音且不重试; 最多等待 3 秒后无论通知是否提交成功都隐藏任务
- 通知以 task ID 与 attempt ID 共同标识, 候选失效或任务恢复, 终止, 完成, 过期时会撤回仍可识别的待处理和已送达通知; 迟到的提交结果不得影响新的 attempt
- 隐藏任务不进入 `CodexActivitySnapshot` 的运行中与等待批准列表, 因而不参与 UI 和 KeepAlive 的活跃任务计算; 后续进展会恢复任务并清除保护记录
- KeepAlive 关闭时恢复当前进程内所有隐藏任务并撤回通知, 已经隐藏任务的持久化记录保留; 再次开启后按当前阈值和最近进展时间无通知对账
- 判定要求监控已启动, KeepAlive 已开启, reader 存在, bootstrap 已结束, 不在睡眠或唤醒恢复阶段且 Hook 数据源健康; 进入不满足条件的阶段时会取消计时器和在途通知 attempt
- 静默定时器使用 `SuspendingClock`, 系统时间变化由 `NSSystemClockDidChange` 触发无通知重算; 系统睡眠期间暂停判定, 唤醒完成 Hook 读取和 rollout 对账后再恢复
- `ActivityProtectionStateStore` 把记录写入 `~/Library/Application Support/CodexBar/ActivityProtection/state.json`, 字段只有 SHA-256 任务标识与 `lastProgressAt` `markedAt` `expiresAt`, 最长保留到最后进展后的 24 小时
- Debug 与 Release 共用状态文件, actor 串行化进程内访问, `flock` 保护跨进程读写, 文件权限固定为 `0600`, 当前 schema 为 1; 状态在 task reader 启动前完成加载
- 持久化操作按 `activityProtectionPersistenceTask` 串行排队, 条件删除用 `markedAt` 防止旧 attempt 删除新记录, 终态与保留期清理执行无条件删除

### 防睡眠 (KeepAlive) 与 root helper

两套机制叠加, 职责不同

- `SystemSleepService` 用进程内 `IOPMAssertion` 建立 `PreventUserIdleSystemSleep` 断言, 只挡空闲睡眠, 不需要提权; 断言名必须是 ASCII, 否则 `pmset -g assertions` 显示不出标识
- `CodexBarHelper` 是 root LaunchDaemon, 通过 XPC 接受 `setSleepPreventionRequested` 请求, 执行 `/usr/bin/pmset -a disablesleep` 覆盖合盖睡眠

链路: `KeepAliveController` (MainActor) 订阅 `activityMonitor.$snapshot` 以及合成 `codexHookSettings.isOperable` 的两个发布值 -> `SMAppService.daemon(plistName:)` 注册 -> `NSXPCConnection` -> helper

关键约束

- `shouldDisableSleep` 是用户意图与依赖可用性的唯一汇合点, 要求 `isStarted && !isPreparingForTermination && isEnabled && isHookEnabled && hasRunningTasks && helperStatus == .enabled && !isRefreshingHelper && !isLowBatteryActive && !hasReachedMaximumDuration` 同时成立; **依赖不满足只让效果失效, 绝不回写用户保存的 `isEnabled`**
- `hasRunningTasks` 只消费 `CodexActivitySnapshot` 中仍可见的运行中任务与按设置纳入的等待批准任务, 被异常会话保护隐藏的任务不参与防睡眠
- Hook 状态在类内只认 `isHookEnabled` 这份镜像, 它跟的是 `codexHookSettings.isOperable`; 不要回读那个属性, 订阅回调跑在 `willSet`, 那一刻它的两个输入里正在变的那一项还是旧值, 只能认 `CombineLatest` 给的闭包参数
- 新增拦截条件一律加进 `sleepBlockReason` 的顺序判断里, 它和 `shouldDisableSleep` 同源, 顺带保证日志的 `reason=` 不会漏项
- UI 用的 `isLowBatteryBlocking` 与 `canShowOptions` 由 `reconcileSleepState` 从 `sleepBlockReason` 单点派生, 新增拦截条件时 `allowsOptions` 那个穷举 `switch` 会强制表态, 于是不会出现入口亮着却点不动
- `hasRunningTasks` 与 `isRefreshingHelper` 都不带 `@Published` 标注, 它们变得比结论频繁, 各自发信号会把整个设置页拖着一起重算
- helper 只做一件事; 不要给 root helper 增加网络, 任意命令执行或其他文件访问能力
- 调用方校验由 XPC 层强制; helper 启动时用 `SecCodeCopySelf` 读自身签名, 拼出形如 `anchor apple generic and certificate leaf[subject.OU] = "<team>" and identifier "<主 App identifier>"` 的 requirement 字符串, 交给 `NSXPCListener.setConnectionCodeSigningRequirement` 生效; 没有逐次连接的 audit token 检查, 改签名或改 bundle ID 会直接连不上
- 所有权记录固定放在 `/Library/Application Support/CodexBar/sleep-ownership.json`, 由 root 在同目录写临时文件, 完成 `F_FULLFSYNC` 后原子替换并同步目录, 权限固定为 `0600`; 只持久化 `idle` `owned` `restoring` 三态, `external` 只是任务期间的运行态, 不落盘也不承担恢复责任
- 当前值为 0 时必须先写 `owned` 再写 `pmset 1`; 释放时必须先写 `restoring` 再写 `pmset 0`; 两次 pmset 都要重新读取 `pmset -g` 确认实际值, 只有确认为 0 才能记回 `idle`
- 任务开始时实际值已为 1 就返回 `external`, 不写 pmset; helper 每 5 秒观察一次, 如果其他来源在任务期间改回 0, helper 立即按上一条顺序取得所有权
- helper 取得所有权后每 5 秒检查一次实际值与磁盘 transaction, 值被改成 0 时重新写回 1, 记录缺失, 损坏或 transaction 不一致时先修复记录; 修复失败也必须继续尝试恢复为 0
- 没有活跃租约时停止短轮询, 只保留 60 秒异常恢复检查; 所有短轮询使用 1 秒 leeway
- 每个 App 进程持有一个跨 XPC 重连不变的 client session ID, 请求再带单调递增的 generation; helper 只释放对应进程的租约并拒绝延迟到达的旧 generation, 不允许旧连接覆盖新状态
- 异常断连后租约宽限 15 秒; 同一 App 在宽限内重连会续上原租约, watchdog 只会释放仍处于断连状态的那一个 client session
- helper 以 `owned` 或 `restoring` 启动时先恢复为 0 再接受新接管; 以 `idle` 启动时不修改当前值, 因为那个值可能属于其他来源
- 更新 helper 前 App 先释放自己的租约, helper 原子确认全局没有活跃客户端且所有权为 `idle`, 再用短期更新准备锁拒绝新的接管; 注册新 helper 后必须收到状态查询回复才记录新指纹, 系统仍在等待首次批准时除外
- 切换失败按 2/4/8...256 秒重试, 列表耗尽即放弃 (延时累计约 8.5 分钟, 每轮再等一次超时约 10 分钟), 瞬时抖动能自愈, 权限类故障不该无限重试
- XPC 请求带超时并汇进同一条重试路径; launchd 拉不起 helper 时 XPC 方法既不回复也不触发 errorHandler, 没有它界面会显示防睡眠开着而实际没生效, 日志里只剩没有配对回复的 `Helper XPC 请求已发送`
- 超时取值放在 `CodexBarHelperIPC.requestTimeoutSeconds` 而不是控制器里, 它与 `watchdogGraceSeconds` 是一对: 必须更小, App 先放手 helper 才能靠 watchdog 兜底, 分处两个 module 会让人改了一边不知道另一边
- 开发期间用 `xcodebuild` 覆盖正在运行的 App bundle 会让 launchd 记的 daemon 与磁盘上的 helper 对不上, helper 从此拉不起来; 重启 App 会由 `helperRegistrationNeedsRefresh` 的指纹比对自愈, 排查时先看这一条
- helper 回传 `none` `external` `codexBar` 来源与操作后的实测值; App 只能在 `codexBar` 且实测为 0 时宣称系统睡眠已恢复或补发 `IOPMSleepSystem`, `external` 和 `none` 都只释放进程内断言
- App 退出由 `applicationShouldTerminate` 返回 `terminateLater`, 先冻结新接管并等 helper 释放回复再继续退出; helper 刷新同样先释放, 旧 helper 无响应时由新 helper 的启动恢复兜底
- `pmset` 是没有来源和引用计数的全局布尔值; CodexBar 取得所有权后如果另一个 App 也开始依赖这个 1, 释放时仍会恢复为 0, 系统层没有无歧义的方法判断另一个 App 的意图
- 低电量保护由 `PowerSourceMonitor` 供数, 它只报事实 (有没有内置电池, 电量, 是否靠电池供电), 不知道阈值; 读数保持 `unavailable` `unreadable` `present` 三态, 把读取失败折叠成"没有电池"会让设置项凭空消失且保护静默失效
- 见过一次内置电池就记住 `hasSeenBattery`, 之后读到空列表只能返回 `unreadable`; 硬件不会中途消失, 空列表只是 IOKit 重新枚举时的缺口, 当成台式机会当场撤掉保护
- `hasSeenBattery` 只活在进程内不持久化, 每次启动重新判定; 笔记本启动时撞上枚举缺口会短暂显示成没有电池, 由下一次电源通知自愈, 而持久化会让从笔记本备份恢复的台式机永远多出低电量设置项
- `IOPSNotificationCreateRunLoopSource` 注册失败时降级成 60 秒轮询并记 `action=poll`; 只靠 `didWakeNotification` 补读不够, 防睡眠生效的机器按定义就不会睡, 那条通知永远不来
- 首次读取在 `start()` 里单独判一次并记 `stage=start` 这条, 不能改走 `refresh()` 那条路: 后者按变化过滤, 而读数初始值就是 `unreadable` 本身, 首读失败会被静默吞掉, 之后只留下一条没有配对失败行的恢复日志
- 防睡眠上限累计的是**真正挡住睡眠**的那段时间, `begin` 起表 `pause` 收表, 收表之后机器睡着或被低电量拦下都不占用户的上限
- 上限计时用 `SuspendingClock` 而不是 `Date`, 后者受系统时间调整影响且系统睡眠期间照走; 排计时器的 `Task.sleep` 同样要传 `SuspendingClock`, 否则睡一夜醒来会当场判定到期
- 低电量是**纯条件**判定, 不设"低过电"的粘滞标志: 电量会回升, 充上电就该自动恢复防睡眠; `hasReachedMaximumDuration` 之所以是粘滞标志只因为累计只增不减, 两者不要照抄
- 低电量必须同时满足在用电池与电量低于阈值, 只看百分比会让"剩 5% 插上电再跑任务"当场被判低电量; 判定用 `Power Source State`, 不能用 `Is Charging` (接电停充时它也是 false)
- 电量读不到时维持上一次的判定, 从没读到过就是不触发: 误触发会当场断掉用户任务, 漏触发最坏也有系统强制睡眠兜底
- 已经在低电量保护中时读数失败不清零, 否则一次瞬时失败会绕过滞回, 让防睡眠反复开关并重发通知
- 低电量通知只在 `isActivelyPreventingSleep` 为真且来源是 `codexBar` 时排队, 外部来源不说"已恢复系统睡眠"; 日志无条件记并用 `action=release|none` 区分, 百分比只有那一条能看到
- 排队的通知要等 helper 恢复睡眠的 XPC 回复确认成功才发得出去, 恢复失败走重试直至放弃, 提前说"已恢复系统睡眠"会把用户骗去合盖然后把电耗干
- 补发 `IOPMSleepSystem` 之前还要 `await` 到通知真的提交完成, 只把提交排进下一个 MainActor job 的话同一个 job 里的补发会抢在它前面
- 那次 `await` 之后要重认一次 `generation` 再走 `finishSleepRestore` 这一步, 挂起期间可能已有新的禁用请求接管, 否则会释放掉刚建立的空闲断言
- 设置页那句低电量说明看 `isLowBatteryBlocking` 而不是 `isLowBatteryActive`, 后者在没有任务时也成立, 那时无话可说
- 触发与解除用 `阈值` 与 `阈值 + 5%` 两道门槛, 否则电量在阈值附近抖动会反复切 pmset, 合盖时还会反复补发 `IOPMSleepSystem`
- 一轮低电量通知的终点是电量回到 `阈值 + 5%` 或者用户改了阈值, 由 `hasNotifiedLowBattery` 记住; 只看是否接电会让适配器接触不良时每翻一次供电状态就重发一条
- `hasNotifiedLowBattery` 只在通知真的提交成功之后才置位, 打在入队处或提交前都会让没送达的那一条吃掉整轮配额, 使这一轮之后真正触发的低电量再也提醒不了
- `hasNotifiedLowBattery` 只管通知不管判定, 与上面"纯条件"不冲突: 电量回到解除门槛以下再跌破仍算同一轮, 不会重复提醒
- `SleepConditions` 里只放 `battery` 布尔, 放电量百分比会让每掉 1% 刷一条变化日志; 真实电量只在触发那一条单独记
- 状态只呈现在主面板活动卡片右侧的咖啡杯标记 (带 tooltip), 由 `KeepAliveController.isActivelyPreventingSleep` 驱动, `sleepPreventionSource` 区分外部来源与 CodexBar 所有权, 卡片折叠成"暂无数据"时标记要跟着一起收
- 设置页那一行说明只在异常, 外部来源, 低电量生效或达到上限时出现, CodexBar 自己正常持有所有权时整行收起, `keepAliveCaption` 返回 nil 即代表收起
- 最长防睡眠时间, 异常会话保护阈值与低电量阈值都在防睡眠子面板里, 台式机读不到电池时低电量那一行整行隐藏而不是置灰
- 保持屏幕常亮跟 `isActivelyPreventingSleep` 走, 由 `reconcileDisplayAwake` 单点切换, 于是低电量拦下, 达到上限, 任务结束时屏幕都跟着放开
- 显示断言只保证屏幕不睡, 屏保与闲置锁屏跟的是系统 idle 计时, 要靠 30 秒一次的 `IOPMAssertionDeclareUserActivity` 压住, 两者缺一不可
- 声明用户活动复用同一个 assertion ID, 每次传 null 会新建一条, `pmset -g assertions` 里会堆成一串同名断言
- 逐次声明不记日志, 建立与释放各一条就够还原状态; 两条断言都是进程级的, App 退出或崩溃时系统自动收回, 不经过 helper
- **菜单栏图标不承载防睡眠状态**, 它要保持模板渲染让系统按菜单栏外观着色, 自行着色在深浅和带染色的菜单栏下都会失控

### 通知

- `CodexNotificationService` 是集中式的 MainActor 服务, 订阅额度快照与实时活动, 负责阈值穿越判定, 去重, 额度重置识别, 触觉反馈和本地通知; dedup key 落 UserDefaults
- `send` 是唯一的提交入口, 返回一个 `Task<Bool, Never>?` 值, 需要等通知真的发出去再做下一步的调用方 `await` 它的 `value` 即可; 不要另开一条 async 通道, 那会悄悄少掉去重 时效判定与提交失败回调三项能力
- 去重判定留在 `send` 的同步段而不是挪进 `Task` 内部, 这样连续两次调用的第二次一定被挡下, 不依赖任务调度顺序
- 异常会话保护通知只依赖通知总开关与系统授权, 使用系统默认声音, `retryCount` 为 0; 提交前后都调用 monitor 的 relevance 检查, 过期通知立即撤回
- `NotificationSettings` 管 CodexBar 自身通知; `CodexCLINotificationSettings` 是另一回事, 它通过 app-server `config/read` 与 `config/batchWrite` 读写 Codex 自己的用户级 `config.toml`
- 通知面板里带依赖的行一律显示为关闭并置灰而不是隐藏, 任务类看 `codexHookSettings.isOperable`, 低电量保护通知看 `KeepAliveController.isLowBatteryProtectionEnabled` (防睡眠可用, 阈值开着, 且这台机器确实有电池), 防睡眠上限通知看 `KeepAliveController.isMaximumDurationEnabled` (防睡眠可用且不是无限制); 都不回写用户保存的开关
- 两条防睡眠通知的依赖里都含"防睡眠可用"这一层, 即防睡眠开关与 Hook 都开着, 判定收在 `publishNotificationDependencies` 一处; 只判各自的子设置会让防睡眠关着时这两行还亮着
- 带依赖的行由 `KeepAliveController` 判定并派生成一个值, 视图只读结论, 不在各视图各写一遍 `!= .unlimited` 这类规则
- 防睡眠上限通知与低电量通知共用同一个发送时机; 达到上限是粘滞状态, 一个计时周期只发一次, 不需要低电量那种本轮已通知的锁存

### 并发与隔离

工程开启 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 设置, 所有类型默认 MainActor 隔离

- UI, 控制器, ViewModel, Settings, 更新类直接依赖默认隔离, 不需要额外标注
- 服务共享状态用 actor 管理, 包括 `CodexStatusService` `WorkflowService` `WorkflowSyncService` `CodexCLIVersionService` `HookEventTailReader` `CodexSessionLifecycleReader` `ActivityProtectionStateStore`
- DTO, 纯模型, 静态工具, 跨 actor 传递的类型必须显式标注 `nonisolated`
- 跨进程写统计文件用 `stats.lock` 加 `flock` 保护, Hook 子进程有等待上限, 主 App 无限等待; `RequestLogStorage` 用 `OSAllocatedUnfairLock`
- 非 Sendable 的管道 IO 集中在 `PipeReadBuffer` 里, `JSONLineReader` 与 `PipeDrain` 复用它
- 保留既有防重入与过期结果丢弃逻辑, 例如 `RefreshTaskCoordinator` 只让最新 generation 提交结果
- 不要用阻塞 I/O 或长耗时操作卡住 MainActor

### 错误处理原则

- 菜单面板的 `CodexFetchOutcome` 只暴露有数据, 未登录, 初始化失败三种结果, 而启动失败, 超时, 断连, 解析失败等细节全部只进日志窗口, 由 `RequestLogStorage` 保存, 上限 500 条
- app-server 之外的模块走 `Services/Support/AppLog.swift` 写系统日志, 用户可见文案只留步骤名, 错误码与 `localizedDescription` 这类细节进 os_log; 现有 category 为 `app` `keepalive` `activity` `workflow` `sync` `hooks` `codexcli` `settings` `notification`, helper 进程另用 `helper`
- 日志的目标是出问题时能从中重建当时的状态, 所以不只记失败, 状态转换, 关键操作与决策依据同样要记; 启动时由 `logLaunchState` 记一条含全部开关的基线, 后续变更日志都是相对它的增量
- 进程终止靠 `AppProcessDiagnostics` 补线索, 它和 `logLaunchState` 一样挂在 `app` category 下, ObjC 异常当场留痕, 其余终止方式靠下次启动补记一条 `App 上次非正常退出`
- 那条补记只能用 `.notice` 级别, 因为 kill 与强制退出和真崩溃无法区分, 用 `.error` 会让按级别筛的排查开局就追一个不存在的故障
- **级别只用 `.notice` 与 `.error`**, 状态转换和降级决策用 `.notice`, 失败用 `.error`; `.info` 与 `.debug` 只落在内存环形缓冲里, 事后 `log show` 捞不全, 一律不用
- 详细度靠**结果字段化**而不是多记几条: 一次操作只留开始与收尾两条, 每一步的成功结果压成收尾那条里的一个字段, 只有失败才单独发一条 `.error` 带 `stage=` 与 `detail=`; 逐事件与逐快照这类高频路径仍然一律不记, 例如两个 Reader 的 `try?` 文件 IO 失败是预期常态, 记了会刷屏
- 文案骨架是 `<主体><动作>: 字段=值; 字段=值`, 标题只说发生了什么, 理由进 `reason=`, 处置进 `action=`; 起止用 `开始` `完成` `失败`, 中间状态用 `已<动作>`
- 字段顺序固定为 标识 (`trigger` `generation` `date`) 输入 结果 `elapsed` `reason`/`detail`; 公共字段有 `trigger` `result` `reason` `action` `detail` `code` (系统返回码) `exit` (进程退出码) `elapsed`, 其中 `code` 与 `exit` 必须分开, 不要用一个 `error=` 同时装 OSStatus IOReturn 和退出码
- 文案只描述事实, 不写"用户做了什么"这类主语, 也不写推论; 字段值要可 grep, 用枚举 rawValue 而不是中文句子, App 与 helper 两侧保持同一套格式
- 词根固定, 一个词能 grep 出整条链路: 额度, 统计刷新 (调度层), 事件汇总 (计算层), 同步, KeepAlive (防睡眠决策层), 空闲断言 (进程内 `IOPMAssertion`), 显示断言 (屏幕常亮那条 `IOPMAssertion`), Helper 注册 (`SMAppService`), Helper XPC (`NSXPCConnection`), 系统睡眠 (helper 的 pmset 效果), 电源监听 (`PowerSourceMonitor`), 任务, Hook, codex, 通知
- 防睡眠日志按两套机制分组: `KeepAlive` 是两套共用的决策层, `空闲断言` 与 `显示断言` 是机制一, `Helper 注册` `Helper XPC` `系统睡眠` 是机制二的授权 传输 效果三层, 故障定位就是在这几层里找
- `trigger=` 由 `LogTrigger` 提供, 从 UI 入口透传到服务层, 用来区分同一条链路是被用户动作 定时轮询还是系统事件踢起来的; 统计维护挂在额度刷新完成事件上, 它的 trigger 继承那一次刷新
- 变化检测类日志只在值真的变了才记, 例如 `KeepAlive 条件已变化` 与 `Hook 配置已变化` 各自存一份上次的值, 否则每次开面板都会刷一条
- 设置项的变更日志照抄设置页那一行的标题, 例如 `菜单栏额度指示变更` `开机自动启动变更`, 用户说"我改了那个开关"时能直接对上; 只有本身带完整链路的才用链路词根, 例如 Hook 同步 通知 KeepAlive 快捷键
- 成对的操作要留成对的日志, 例如 XPC 的发送与回复各记一条并带同一个 `generation`, 缺一条就说明请求丢在途中
- 耗时用 `LogDuration` 取, 只加在收尾那一条上
- `Logger` 的插值是 autoclosure, 里面直接访问属性会被要求显式 `self`, 而 `.swiftformat` 配了 `--self remove`, 两边会打架; 把属性先取到局部常量再插值即可, 不需要 lint 豁免
- 账号有效时 rate limits 和 usage 允许单独失败, 复用同账号旧缓存并标记 stale, UI 显示为半透明, 无缓存则该区域不显示; 账号变化时整体丢弃缓存避免串号
- 各 Settings 类把读取类错误与操作类错误分开存储, 定时 refresh 不能抹掉用户操作或校验的结论, 参见 `CodexHookSettings` 与 `KeepAliveController`
- Hook 子进程任何失败都静默退出, 优先保证不拖慢 Codex

## UI 与窗口约定

- 菜单栏按钮左键切换主面板; 右键或 Control+点击打开上下文菜单; `⌘,` 打开自定义设置窗口, 菜单面板打开时 `⌘L` 打开日志窗口; 默认全局快捷键 `⌘⇧W` 由 `GlobalHotKeySettings` 与 `GlobalHotKeyController` 管理
- 主面板是锚定 status item 的 `NSPopover` 弹窗, 锚点不可信时回退到 `FallbackPanelController` 提供的屏幕顶部居中 `NSPanel` 面板, 处理快捷键, 屏幕选择和焦点时要保留这两个分支
- 关闭逻辑统一由 `MenuSurfaceDismissMonitor` 管理, 淡出由 `MenuSurfaceFadeCoordinator` 负责
- 侧边面板都是 borderless nonactivating child panel, 热力图详情, 重置次数和任务中心挂在主面板上, 通知选项和防睡眠选项挂在设置窗口上
- 设置窗口的子面板占同一位置, 展开一个必须先 `hide(immediate: true)` 收掉其余的; 动作走 `SettingsOptionsPanelAction` 并带上目标 `SettingsOptionsPanel`, 互斥与 `closeAll` 都只写在 `SettingsWindowController.handleOptionsAction` 一处, 加第三个面板不会漏配对
- 面板控制器只在首次展开时构造, 收起动作走 `existingOptionsPanelController` 而不触发构造: 它一建就挂上内容变化订阅并常驻到 App 结束, 而用户可能一次子面板都没开过
- 两个子面板的顶边对齐各自主开关行, anchor 由设置页的 `ScreenFrameProvider` 随展开动作传出, 定位走 `SidePanelSupport.anchoredPosition` 而不是宿主底边
- 设置窗口的子面板要传 `clampsToSurfaceBottom: false` 让底边可以探出窗口, 否则放不下时会把整个面板上推而错开主开关行; 主面板那三个面板走默认的 true
- 两个子面板的高度都会变, 通知面板随音效行增删, 防睡眠面板随 `hasBattery` 增删低电量那一行; resize 时要固定顶边向下生长, 直接改 size 会保持底边不动而把顶边顶离主开关行
- 高度重算只订阅真正会改变行数的那几项, 通知面板订 `notificationSettings` 与 `codexHookSettings` 的 `objectWillChange` 再加 `KeepAliveController.$isLowBatteryProtectionEnabled` 与 `$isMaximumDurationEnabled` 两条, 防睡眠面板只订 `$hasBattery` 一条; 订整个防睡眠控制器会让任务每起停一次都白排一轮 resize
- 置灰也会改高度: 带音效的行置灰时音效子行跟着收起, 所以每个置灰依赖都要有一个对应的订阅源
- 增删行或改行的显示条件时要同步补上对应的订阅源, 漏一项会让面板裁掉底部或留下空白
- resize 的竖向夹紧走 `SidePanelSupport.clampedVertically`, 与初次展开的 `position` 同一条规则, 否则放不下时两边会把面板推向相反的边
- 子面板入口只在开关开着且依赖就绪时出现, 通知看 `NotificationSettings.canShowOptions` 那个值, 防睡眠看 `KeepAliveController.canShowOptions` 这个值; 两者都只控制入口显隐, 不回写用户保存的开关
- 两个子面板都只由滑杆按钮展开, 动作只有 toggle 与 close 两种, 开启主开关不自动弹出
- 侧边面板公共能力集中在 `Controllers/SidePanelSupport.swift` 里, 含 `SidePanelDrawerPresenter` `SidePanelContentHost` `SidePanelDrawerAnimator` panel 工厂和定位夹紧; 挂在主面板上的那三个面板优先复用 `SidePanelDrawerPresenter` 这一层, 不要另起一套
- 设置窗口的子面板直接复用 `Controllers/SettingsOptionsPanelController.swift`, 它在 presenter 之上补齐了装配, 两套关闭观察者, 顶边对齐定位和高度重算; 新增设置子面板只要给它内容工厂与内容变化来源, 不要再写一层壳
- 两个设置子面板的行高与间距从 `SettingsOptionsPanelMetrics` 取, 下拉控件共用 `SettingsOptionsPicker` 这一个, 只有面板宽度和 picker 宽度各自定义, 这样两个面板看起来才是同一套控件
- 设置子面板的内容工厂必须走 `SettingsOptionsPanelController.makeContentController(_:rebuiltBy:)`, 否则首次展开时原生 Switch 只剩一条空轨道; 重建信号由它接在内容外面, 内容视图不必知道 `SidePanelEntryCue`
- 原因是 thumb 由 `WindowPortal` 投射而不是画在开关上, 面板首次布局那一轮 portal 建不起来, 而且不会自愈, 只有一次内容重建才补得上; 第二次展开正常是因为 hosting controller 常驻, 复用了已经建好的那份
- 不要再用 `@_optimize(none)` 规避这个漏绘: 它当年在通知子面板管用只是因为逼着 body 重算时判定那些行变过, 与优化等级无关, 换个写法就失效; `SidePanelSupport` 里剩下那一处标注规避的是编译器崩溃, 与此无关
- 主面板任务中心的显隐由 `MainPanelSettings.showsTaskCenter` 与 `codexHookSettings.isEnabled` 共同决定, Hook 未开启时设置页那一行显示为关闭并置灰, 不回写用户保存的开关值
- 设置窗口 (通用/高级/关于三页) 和日志窗口复用 `HostingWindowController` 的行为, 可以成为 key window, 但不应成为 main window
- 视觉风格统一走 `Views/Shared/LiquidGlassStyle.swift` 这一套, 避免引入与系统菜单栏工具不一致的重装饰 UI

## Hook 配置改写约束

`~/.codex/hooks.json` 的读写全部在 `CodexHookSettings` 里完成, Codex 目录优先取 `CODEX_HOME` 环境变量, 找不到时回退真实用户 HOME 下的 `.codex` 目录

- 只识别并移除 command 同时包含当前 CodexBar 可执行路径与 `--hook-event` 的 handler, 必须保留用户已有 Hook 以及其他 App 的 Hook 和同事件下的其他 handler
- 每个 `CodexHookEvent.allCases` 事件追加一个独立 group, handler 超时从 `WorkflowHookEventRecorder.hookTimeoutSeconds(for:)` 取得; 新增事件时不得复制一份超时常量
- 启用和校验 Hook 前要求当前 app-server 握手版本至少为 `0.145.0`; 必须检查 `readyConnectionInfo()` 返回的实际连接版本, 不能用磁盘版本代替, 否则升级后尚未重连的旧进程会被误判为可用
- 写入前通过 app-server `config/read` 确认全局未禁用 Hook, 写入后用 `hooks/list` 验证; 两处读取共用 `readGlobalHookDisabled`, 开关流程与校验流程对"全局禁用"的判断不会分叉
- 读取失败 (I/O 或 JSON 格式错误) 不提供 Hook 装没装的信息, 必须保留上次已知值, 不能当成用户关闭了 Hook
- `isEnabled` 只表示 `hooks.json` 里至少装着一个当前 CodexBar handler, `isVerified` 是最近一次校验的明确结论, 两者合成的 `isOperable` 才表示事件链路可用
- 实时任务, 防睡眠和任务类通知必须看 `isOperable`; 历史聚合与同步仍可消费已落盘数据, 其调度只看 `isEnabled`, 不要把两类依赖混在一起
- `isVerified` 乐观默认为 true 且只由明确结论写入两个方向: 校验只在设置窗口打开与 App 激活时跑, 而 RPC 失败属于"验不了"不是"确认不通", 那时置灰会把好用的功能关掉
- 全局禁用要排在 `hooks/list` 之前判: 它一关列表里必然找不到我们的 handler, 那时报"已不完整"会把用户引去翻本来就完好的 `hooks.json`
- `refresh()` 只判断是否存在任一当前 CodexBar handler, `hooks/list` 校验才要求所有事件完整; 新增事件后旧配置不会自动补齐, 当前恢复方式是让用户关闭再开启 Hook
- 校验不通过时防睡眠那一行的说明写"CodexBar Hook 未生效"而不是"需要启用 CodexBar Hook", 后者会让用户去开一个已经开着的开关; 具体病因由 Hook 那一行自己的说明给出

## 隐私与数据边界

改动涉及网络, 日志或同步时必须遵守

- App 只有四类出网行为, 分别是本机 app-server stdio 通信 (不算网络), 重置机会过期时间只读查询, Sparkle 更新, 用户显式开启后的 CloudKit 同步, 新增网络请求需要非常明确的理由
- 只读查询打到 `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` 这一个地址, 也是全仓库唯一的 `URLSession` 调用点, 位于 `CodexResetCreditsService` 内; Sparkle 更新走 `https://codexbar.zabrian.app/appcast.xml` 这个 feed
- 不展示 app-server stderr; 不展示或记录 Codex OAuth token 与 `auth.json` 内容; 不把原始敏感 RPC 响应写进文档
- CloudKit 只同步去掉 `sessionIds` 与 `turnIds` 的 daily 聚合, 不同步原始 Hook events, 账号, 额度或 Token 用量
- 异常会话保护状态只保存在本机, 不同步 CloudKit; 记录不含原始 session ID, turn ID, 项目名或任务内容
- CloudKit 的 `sessionEndCount` `userPromptSubmitCount` 与其他 Hook 计数字段保持可选, 远端缺失表示历史来源没有提供, 不能在读取时补成 0; 改变远端格式时同时评估并更新 `syncSchemaVersion`
- 系统日志不写用户数据: 额度与 Token 用量只记 `state=` 这类结果分类, 任务内容, 项目名, 会话与轮次标识一律不记; 可执行文件路径含用户名, 用 `source=global|bundled` 之类的标识代替
- 事件数, 任务数, 日期这类聚合数字可以记, 它们是判断重建是否正确和定位哪天出问题的依据, 不含任何内容

## 代码修改原则

- 优先贴合现有文件结构和类型职责, 不为小改动新建抽象
- 改 shared controller, shared service, 模型解析或持久化 key 时, 要考虑旧数据和降级路径; 用户设置要保持默认值; 持久化 key 和旧版本迁移兼容
- **任何兼容性问题都必须主动询问用户, 不要自行决定**; 只要改动会影响新旧共存就适用, 不限于旧数据迁移或丢弃, 持久化 key 改名或改结构, 老版本升上来的降级路径, 最低系统版本与 API 可用性取舍, 云端记录格式变更; 先说清影响面和几种做法的代价, 等用户选定再动手
- 处理窗口, 菜单, 快捷键, App 激活或事件监听时, 特别注意 `LSUIElement` 应用特有的焦点行为
- 注释保持克制, 只解释非显然的生命周期, 焦点, actor 或系统 API 约束; 现有注释多为解释为什么的类型, 沿用同样风格
- 改动涉及菜单面板, 窗口焦点, Hook, 同步, 通知或防睡眠时, 构建通过之外还要说明应手动覆盖的交互场景; 防睡眠额外要验证 App 包内 helper 与 plist 位置, 签名, 首次系统授权, 运行/等待切换和异常退出后的恢复
- 不要把发布产物, DerivedData, 临时 DMG, 签名文件或个人凭据提交进仓库

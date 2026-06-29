# AGENTS.md

本文件是 Codex 在本仓库工作的持久指令。根目录范围内均适用；如果子目录未来出现更近的 `AGENTS.md`, 以更近文件为准。

本文件按 OpenAI GPT-5.5 prompt guidance 的思路组织: 结果优先、约束明确、上下文可追溯、验证轻量但必须执行。不要把它当成逐步脚本机械执行；遇到更直接、安全、可验证的路径时, 选择更高效的做法。

## 目标

CodexBar 是一个 macOS 菜单栏应用, 通过本机 Codex app-server 展示当前 Codex 账号、额度、token 用量、Codex CLI/APP 版本和交互日志, 并可通过 Codex Hook 统计本机工作流数据。你的目标是交付可验证、范围清晰、贴合现有 SwiftUI/AppKit/MVVM 架构的修改, 并保护本地认证、隐私、菜单栏体验、Hook 配置、Sparkle 更新和发布流程。

## 成功标准

- 先明确用户要的结果: 代码修改、文档、诊断结论、review、构建验证或发布操作。
- 修改范围只覆盖完成目标所需文件; 不顺手重构无关模块, 不回滚他人未提交改动。
- 行为改变必须能用代码事实、工具输出或用户确认支撑。
- 涉及 Swift/Xcode 工程、资源、build setting、Info.plist、SwiftPM、脚本行为或 UI 行为的改动后运行构建命令。
- 纯文档改动可以不构建, 但最终说明实际做过的检查。
- 最终回复简洁说明改了什么、如何验证、剩余风险或未执行项。

## 工作方式

- 默认中文回复, 除非用户要求英文。
- 先读局部上下文再行动。优先用 `rg` / `rg --files`、当前文件和相邻模块定位事实。
- 简单、低风险、可逆的请求直接执行。删除、发布、推送、生产写入、覆盖用户选择或行为不确定时先取得明确同意。
- 独立读取可以并行; 有依赖、会改变文件、或动作不可逆时顺序执行。
- 工具调用前用一句话说明意图。长任务中持续同步进度, 不把中间状态当最终结果。
- 需要外部事实时使用可检索来源; 不猜测当前版本、API、文档或政策。若上下文缺失且无法检索, 问最小问题。
- 修改 prompt、文档或 agent 指令时, 保留仍然准确的项目事实和边界; 删除会改变执行行为的规则前确认它确实过期或冲突。

## 行动安全

执行高影响动作前做轻量 pre-flight:

- 说明将要做的动作和关键参数。
- 通过工具执行。
- post-flight 确认结果和验证。

高影响动作包括: `git push`、tag、release、DMG/appcast 更新、删除文件、改 Xcode build settings、改 Sparkle 配置、改 sandbox/signing、改认证/隐私相关逻辑。

## 验证

Swift/Xcode 相关改动后运行:

```bash
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination generic/platform=macOS -derivedDataPath /tmp/CodexBarDerivedData build
```

要求无 error。当前 Xcode 可能输出 `Metadata extraction skipped. No AppIntents.framework dependency found.` 的 metadata warning, 不作为项目代码 warning 处理。SourceKit 对跨文件类型偶尔误报时, 以 `xcodebuild` 为准。

文档-only 修改至少运行:

```bash
git diff --check
```

提交或发布前再检查:

```bash
git status --short
```

## 项目事实

- 平台: SwiftUI + AppKit + MVVM, 最低 macOS 15.0。
- 应用形态: `LSUIElement` 菜单栏应用, 无 Dock 图标、无主窗口。
- 外部依赖: Sparkle(SwiftPM)。
- 当前 build settings: `MACOSX_DEPLOYMENT_TARGET = 15.0`, `MARKETING_VERSION = 3.2.0`, `CURRENT_PROJECT_VERSION = 28`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_VERSION = 6.0`。
- App Sandbox 必须保持关闭(`ENABLE_APP_SANDBOX = NO`), 因为应用要启动本机 Codex CLI/APP 内置 CLI, 并读取真实 macOS 用户的 Codex 登录状态。
- 工程使用 `PBXFileSystemSynchronizedRootGroup`; 新增或删除 `CodexBar/` 下 Swift 文件通常无需改 `project.pbxproj`。只有依赖、target/build settings 或资源归属变更才改 Xcode 工程文件。
- Swift 源码按目录组织: `App/`、`Controllers/`、`Models/`、`Services/`、`Views/`。不要把新 Swift 文件直接放回 `CodexBar/` 根层。
- 不要为 macOS 15 以下添加 SF Symbols 或 SwiftUI API fallback。

## 架构地图

主要数据流:

```text
CodexStatusService(JSON-RPC app-server)
  -> CodexStatusViewModel(@MainActor 状态发布)
  -> StatusItemController(菜单栏图标、菜单面板、窗口入口)
  -> CodexStatusMenuView / AppSettingsView / LogView

Codex Hook
  -> WorkflowHookEventRecorder(--hook-event stdin hook_event_name)
  -> WorkflowStorage(events/YYYY-MM-DD.jsonl / daily.jsonl)
  -> WorkflowService
  -> WorkflowSyncService(可选 CloudKit private database 同步)
  -> WorkflowViewModel
  -> UsageSummaryView / UsageHeatmap
```

目录职责:

- `App/`: 入口和全局启动分支。
- `Controllers/`: 菜单栏、菜单面板、设置窗口和日志窗口控制。
- `Models/`: account、quota、usage、workflow、共享日期网格和错误模型。
- `Services/`: app-server、Codex CLI、设置、Hook 统计、更新和日志服务。
- `Views/`: 菜单面板、设置、日志和共享 Liquid Glass 样式。

Hook 统计的配置、存储、保留策略和统计口径见 [Docs/CodexHook.md](Docs/CodexHook.md), 跨设备同步见 [Docs/CrossDeviceSync.md](Docs/CrossDeviceSync.md)。

## app-server 合约

- 详细合约见 [Docs/AppServer.md](Docs/AppServer.md)。
- 必须通过 `CodexCLIResolver.resolveAppServerCommand()` 解析, 不要绕过 resolver 直接启动。
- app-server 环境必须使用真实用户 `HOME`、`USER`、`LOGNAME`; 不要改回 Xcode sandbox/container 的 `HOME`。
- 保留认证失败 refresh token、unsupported method、业务错误重试、stale cache 和连接重建语义。
- 不要把子进程 stderr、认证文件或原始敏感 RPC 响应展示给用户。

## Codex Hook 合约

- 详细设计见 [Docs/CodexHook.md](Docs/CodexHook.md)。
- 设置开关只能追加或移除 command 同时包含当前 CodexBar 可执行路径和 `--hook-event` 参数的 Hook 处理器, 不能破坏其他用户 Hook。
- Hook 命令写入当前 CodexBar 可执行文件路径和 `--hook-event` 参数; Hook 事件名来自 Codex 传入的 stdin payload 顶层 `hook_event_name`。
- Hook 原始事件和本机 daily 聚合保存在 `~/Library/Application Support/CodexBar/HookEvents/`; 用户开启「跨设备同步」后, 仅脱敏 daily 聚合副本会同步到当前 iCloud 账号的 CloudKit private database。
- Hook 写入可能并发触发, 追加 `events/YYYY-MM-DD.jsonl` 并更新 `maintenance.json` 时必须通过 `stats.lock` 加锁。

## UI 状态与日志

- app-server 状态和请求日志规则见 [Docs/AppServer.md](Docs/AppServer.md)。
- UI 只展示「未登录」和「初始化失败」两类特殊状态; 具体请求错误、启动错误、超时、断连、解析失败都进入日志。
- 日志窗口状态标签为「进行」「完成」「错误」「请求」。

## 数据模型

`CodexQuotaSnapshot`:

- 必须有 `AccountReadResponse.account`, 否则视为未登录。
- `rateLimitsResponse` 和 `usageResponse` 都可以为空; 账户有效时仍生成快照, UI 展示「暂无数据」。
- `isRateLimitsStale` / `isUsageStale` 标记额度或 token 区域是否来自同账号旧缓存; 本轮对应接口成功后重新生成 snapshot 并恢复为 `false`。
- 优先读取 `rateLimitsByLimitId`; 为空时回退顶层 `rateLimits`。
- 顶层 `rateLimits.limitId` 指向的主 limit 置顶, 缺省 `"codex"`。
- `codexLimit` 返回 `limitId` 大小写不敏感等于 `"codex"` 的第一个 limit, 供菜单栏额度指示选择窗口使用。
- 其余 limit 按 `limitName ?? limitId` 做 localized standard 排序, 再按 `limitId` 稳定排序。
- `rateLimitResetCredits.availableCount` 读入 `resetCreditsAvailableCount`; 缺失时为 `nil`。
- `resetCreditsAvailableCount > 0` 时, 主 App 可使用本机 Codex OAuth token 请求 `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`; 401/403 时复用本轮认证刷新预算重试; 只保留可用且未过期的 `credits[].expires_at` 到 `resetCreditExpirationDates`, 请求失败时为 `nil` 且 UI 不展示过期时间 help text。
- `primary` / `secondary` 合成 `[QuotaWindow]`; 没有窗口的 limit 被过滤。
- `QuotaWindow.remainingPercent = clamp(100 - usedPercent, 0...100)`; 无 `usedPercent` 视为无数据。
- `windowDurationMins` 标签: 整天 `ND`, 整小时 `NH`, 否则 `NM`, 缺失或非正数为「额度」。

`CodexUsageSnapshot`:

- `recentWeekGrid(columnCount:endingDaysAgo:today:)` 基于本地当天零点生成按周排列的日期网格, 每列从周日开始。
- UI 使用 30 列、7 行; Hook 开启或 app-server 已返回当天 token bucket 时包含今天, 否则不包含今天。
- `nil` 表示未来日期或不可生成日期; 热力图不绘制方块也不参与峰值计算。

工作流统计:

- 统计口径、字段兼容和保留策略见 [Docs/CodexHook.md](Docs/CodexHook.md)。
- UI 展示字段为「会话总数」、「对话轮次」、「子智能体」、「工具调用」、「权限请求」、「上下文压缩」。

## 并发与隔离

工程开启 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; 未显式标注的类型会推断为 MainActor 隔离。

- UI 层保持 `@MainActor`: app delegate、status item controller、window controllers、view models、settings/updater。
- 服务层对外暴露 async API, 共享可变状态优先由 actor 隔离。
- 非 UI 类型、DTO、模型、服务辅助类型和静态工具需要显式 `nonisolated`, 避免 main actor 隔离泄漏到同步服务代码。
- `CodexStatusService` 是 actor, 负责 app-server 连接、缓存和重建。
- `CodexCLIVersionService` 是 actor, 全局和内置版本探测用 `async let` 并发启动; 子进程输出通过 `PipeReadBuffer` 收集。
- `WorkflowService` 是 actor, 串行维护和读取 workflow 快照。
- `WorkflowSyncScheduler` 是维护/同步任务的唯一调度者, 合并自动维护、同步开关、Hook 重新开启和同步可用性恢复触发的请求; `WorkflowViewModel.refreshMaintenance(synchronize:)` 只执行一次明确的维护刷新并发布快照。
- `RequestLogStorage` 可从后台同步写入, 用 `OSAllocatedUnfairLock` 保护; `@MainActor RequestLogStore` 只负责发布 SwiftUI 快照。
- `PipeReadBuffer` 是底层 `FileHandle`、`DispatchSourceRead` 和 semaphore 的唯一 `@unchecked Sendable` 边界, 读队列 `CodexBar.pipe-read` 使用 `.userInitiated` QoS。
- Hook 写入可能由多个 Codex 进程并发触发, 必须通过 `stats.lock` 和 `flock` 保护 `events/YYYY-MM-DD.jsonl` 和 `maintenance.json` 的一致性; `daily.jsonl` 由主 App 刷新维护流程写回。

## UI 约束

菜单栏:

- 正常图标是 `person.fill.checkmark`, 错误图标是 `person.fill.xmark`。
- 菜单栏不展示额度数字; 详情只在菜单面板中展示。
- 设置页「菜单栏额度指示」使用独立开关控制启用状态; 开启后同一行显示额度窗口菜单, 选项来自当前账号 Codex limit 返回的窗口, 当前保留选择不在返回窗口中时用 fallback 标题追加到菜单。关闭开关时设置页保留最后一个非关闭窗口值参与菜单淡出, 避免过渡期间回退到默认窗口。关闭时菜单栏只展示原图标, 开启时将所选 Codex 窗口剩余额度进度条绘制在 `person.fill.checkmark` / `person.fill.xmark` 图标左侧, 以竖条形式作为单个菜单栏图像自动随状态刷新; 合成图尺寸为 `27 x 17`, 图标本体保持原始 `24 x 17`, 左侧竖条轨道为 `2 x 15`; 开启或关闭时竖条透明度做 0.18 秒过渡, 过渡期间合成图宽度和图标绘制坐标保持固定。
- 左键或全局快捷键切换菜单面板; 右键或 Control 点击显示「设置 / 日志 / 退出」。
- 上下文菜单由 `NSStatusBarButton.performClick(nil)` 触发; 设置和日志菜单项 action 需要等 `NSMenuDelegate.menuDidClose(_:)` 确认菜单结束并清空 `statusItem.menu` 后再打开窗口, 避免键盘等效键在 `NSMenu` tracking 期间打开窗口导致无法激活到最前。
- 全局快捷键打开菜单面板前必须短暂禁止设置窗口和日志窗口成为 key window, 避免已有设置/日志窗口被 App 激活一起带到前台; 随后校验当前 status item 锚点可信。锚点无 window、无有效 screen、按钮隐藏、bounds 为空、屏幕矩形异常, 或屏幕矩形没有落在目标屏幕范围内时, 使用无箭头 fallback `NSPanel` 在目标屏幕顶部居中打开。目标屏幕优先取鼠标所在屏幕, 找不到时取主屏幕。快捷键关闭已打开的菜单面板不受此校验影响。

菜单面板:

- `CodexStatusMenuView.menuWidth` 由热力图宽度和 padding 推导; 改热力图尺寸时同步检查弹窗宽度。
- 外层和分区使用 `.liquidGlassSurface(...)`; 分隔线使用 `LiquidGlassDivider`; 小徽章可用 `.liquidGlassCapsule(...)`。
- `LiquidGlassStyle.swift` 是自绘玻璃效果, 不是 macOS 原生 `.glassEffect`; 没有明确设计要求时不要切换。
- 账号图标双击触发刷新。邮箱文本双击切换模糊。
- 计划名是右侧加粗纯文字; `planBadgeTint(for:)` 优先级: enterprise -> team/business -> pro -> plus -> edu -> free -> 默认 cyan。
- `resetCreditsAvailableCount` 有值时, 只在置顶主 limit 标题右侧显示 `重置次数: N`; `resetCreditExpirationDates` 非空时, 鼠标悬停在该文本上通过 help text 按升序逐行展示 `过期: yyyy-MM-dd HH:mm:ss • 可用: N`, 相同展示时间合并数量, 单个显示 `可用: 1`。
- 额度条展示剩余百分比, 固定为 50 个胶囊, 每个胶囊宽 `3.5`, 间距 `2`, 高 `12`; 颜色按 20% 一档: 红、橙、黄、薄荷、绿。
- 额度行标签列宽 `34`, 居中显示, 标签允许最小缩放到 `0.75`, 标签到额度条间距 `12`, 额度条到百分比间距 `8`, 百分比列宽 `37`, 百分比到重置时间最小间距 `6`, 重置时间列宽 `75`; 不通过加宽菜单面板解决额度行溢出。
- 无 quota 数据时显示 `--` / `暂无数据`, 并使用占位色。
- `rateLimits` 或 `usage` 使用旧缓存时, 对应区域通过 `.markStale(true)` 降低透明度到 0.55, 不降低饱和度; 下一轮对应接口成功后恢复正常透明度。
- 重置时间格式是 `MM-dd HH:mm`, 使用等宽数字, 在额度行最右侧对齐。
- 更新时间行显示倒计时圆环、「数据更新时间」和 `HH:mm:ss`。
- 更新时间行最右侧显示同步状态图标: 只有 Codex Hook 开启、跨设备同步偏好开启且同步账号可用时才进入 active 同步态; 非 active 同步统一为 `icloud.slash`, tooltip 为「同步未开启」; active 空闲为 `icloud`, tooltip 显示 `最近同步: yyyy-MM-dd HH:mm:ss`, 时间来源和设置页「最近同步」一致, 没有成功上传记录时显示「暂无同步记录」; active 同步中为 `arrow.trianglehead.clockwise.icloud`; active 同步失败为 `exclamationmark.icloud`, tooltip 展示归类后的同步错误文案。
- 倒计时只在菜单面板可见时用 `TimelineView` 每秒 tick; 普通 tick 不做连续动画, 仅刷新起点变化时播放恢复动画。
- token 区域显示「单日峰值」和「全时累计」; `TokenCountText` 对 1K 以下显示完整整数, 1K 起显示 K/M/B。
- token 区域还显示「当前连胜」、「最长连胜」和「最长任务」。
- 热力图是近 30 周、30 列 x 7 行、周日到周六排列; Codex Hook 开启时包含今天, Hook 关闭时仅在 app-server 已返回当天 token bucket 时包含今天。
- 热力图 hover 使用 `HeatmapDetailPanelController` 展示侧边详情面板, 不是菜单面板内 tooltip; 面板作为菜单面板 child window, 不接收鼠标事件, 左右贴边展示并在屏幕可见区域内夹紧。
- 详情面板内容更新时保留 `NSPanel` / `NSHostingController`, 但每次替换 `hostingController.rootView` 并同步 `setContentSize`; 不用常驻 `ObservableObject` model 推送 hover context, 避免 Hook 开关切换 token-only / workflow 布局后触发 AppKit 递归布局。
- Hook 关闭时详情面板显示日期、token 数和「用量强度」分段条, 尺寸 `212 x 84`。
- Hook 开启时详情面板首行左侧显示日期、右侧显示 token 数, 当天 token 数显示 `--`; 后续显示「用量强度」、「会话总数」、「对话轮次」、「子智能体」、「工具调用」、「权限请求」、「上下文压缩」, 尺寸 `212 x 189`。
- 「用量强度」前置圆点固定为蓝色, 不随用量强度变化。
- 工作流统计只展示在用量热力图详情面板中, 不再有单独的工作流统计区。

设置窗口:

- 通过右键菜单「设置」打开独立 `AppSettingsView` 窗口。
- 不要恢复为 Option 点击或菜单面板内设置区。
- 设置页包含「菜单栏额度指示」、「使用快捷键」行、「CodexBar 版本」和「Codex 版本」区域。
- 设置窗口按 SwiftUI 内容自适应高度时必须校验 `fittingSize` 有限并夹紧到安全上限; 设置页 `onAppear` / `didBecomeActive` 中触发的设置刷新不得同步发布 `@Published` 变化。
- `Codex CLI` 行图标用 `terminal`; `Codex APP` 行图标用 `app.badge`。
- 当前运行来源显示「当前使用」。
- 当前行优先展示 app-server 握手自报版本; 非当前行展示磁盘安装版本。
- 当前运行版本与磁盘安装版本不同时, 显示「已更新至 <version>」。
- 路径点击复制到剪贴板, 对应来源显示「已复制」1.5 秒; 保留路径文本布局宽度避免跳动。
- 默认全局快捷键是 `⌘⇧W`; 快捷键录制至少需要两个修饰键, 不允许 Command-Space 或 Command-Tab; 注册冲突、无法识别和校验错误显示在快捷键行内。
- 设置页包含「启用 Codex Hook」开关; 开启后会写入全局 Codex Hook 配置, 用于近 30 周数据展示更多本机统计数据。
- 开启 Codex Hook 前必须通过当前 `CodexStatusService` app-server 会话调用 `config/read`, 如果 Codex 全局配置禁用了 Hook, 则不写入 `hooks.json`, 开启失败并在 Hook 选项下方提示。
- 开启 Codex Hook 写入 `hooks.json` 后必须通过当前 app-server 会话调用 `hooks/list` 验证 `command`、`eventName`、`enabled`、`sourcePath`、`trustStatus`、`warnings` 和 `errors`; 未信任或已修改时, 只对来源为全局 `hooks.json` 且 command 属于当前 CodexBar 的 Hook 通过 `config/batchWrite` 自动写入 `hooks.state` 的 `trusted_hash`, 再重新验证。
- Codex Hook 开关下方只在必要时显示 Hook 相关错误; 不展示固定说明文案、启用状态或关闭状态文案。
- 设置页包含「跨设备同步」开关; 仅在 Codex Hook 开启且 CloudKit account status 为 available 时可操作。同步账号不可用时开关禁用, 并在开关下方显示「同步不可用」。
- 「跨设备同步」开启后, 主 App 在工作流统计维护刷新中把脱敏 daily 聚合按日期稳定排序、每批最多 25 天、每轮最多 20 秒上传到 CloudKit; 已成功上传的日期立即写入本地 `state.json`, 剩余日期留给后续刷新继续。
- 开机启动错误显示在设置组与底部按钮组之间的独立错误组; 无错误时不展示该组, 退出和检查更新按钮之间不展示错误文案。

日志窗口:

- 通过右键菜单「日志」打开。
- 日志窗口应持续显示全局 `RequestLogStorage.shared` 中的记录, 通过 `@MainActor RequestLogStore.shared` 发布到 SwiftUI, 不因窗口关闭丢失。
- `RequestLogEntry` 保存完整 request/detail; 列表摘要和行内展开只显示单行短预览, 非空请求/响应标题行提供预览和复制完整内容; 预览视图对 JSON 做格式化和高亮。

## Sparkle 更新

- `AppUpdater` 是 `@MainActor ObservableObject`。
- 初始化时先校验 `SUFeedURL`(http/https) 和 `SUPublicEDKey`(非空)。
- 任一缺失时不创建 `SPUStandardUpdaterController`, 更新操作显示「未配置更新资源」。
- `canConfigureAutomaticChecks` 是 `updaterController != nil`。
- `settingsStatusMessage` 用于设置窗版本行, 默认 3 秒后清空。
- `panelUpdateMessage` 用于菜单面板底栏被动提示, 双击触发 `startUpdate()`。
- `availableUpdateMessage` 驱动设置窗版本行和「立即更新」按钮。
- 手动检查结果进 `settingsStatusMessage`; 自动发现新版进 `panelUpdateMessage`。
- 当前 `SUFeedURL = https://codexbar.zabrian.app/appcast.xml`, `SUScheduledCheckInterval = 3600`。

## 认证、隐私与沙盒

- CodexBar 主要通过本机 Codex app-server 读取账号、额度和 token 使用量; 为展示手动重置机会过期时间, 可使用本机 Codex OAuth token 向 `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` 发起只读请求, 只保留可展示的过期时间数组。
- Codex Hook 工作流统计默认只写入本机 `~/Library/Application Support/CodexBar/HookEvents/`; 用户开启「跨设备同步」后, CloudKit 只保存去掉 `sessionIds` / `turnIds` 的 daily 聚合副本, 不保存原始 Hook events。
- 除手动重置机会过期时间查询、Sparkle appcast/DMG 下载, 以及用户显式开启「跨设备同步」后的 CloudKit private database 请求外, 应用自身不做网络请求。
- App Sandbox 必须保持关闭。
- app-server 和版本探测必须使用真实用户 home。
- 不要把 Codex auth 文件、stderr、原始敏感 RPC 响应或用户路径之外的敏感信息写入 UI、文档或测试夹具。

## 发布脚本

- `Scripts/dmg.sh [App.app] [Output.dmg]` 创建带 `/Applications` Finder alias 的 DMG, 会尝试写 Finder 布局。
- `Scripts/appcast.sh [CodexBar-vX.Y.Z.dmg]` 更新 `appcast.xml`, 需要 Sparkle `sign_update`。
- 改发布脚本后至少运行 `bash -n Scripts/dmg.sh` 和 `bash -n Scripts/appcast.sh`。
- 更新 appcast、tag、push、上传 DMG 都必须先得到用户明确同意。

## Git 规则

- 不要主动 push。
- 不要回滚或覆盖你没做的未提交改动。
- 提交 Git 时候**禁止**任何改动任何内容，仅对目前代码进行提交即可。
- 提交 message 使用 Conventional Commits 前缀 + 中文标题 + 空行 + 4 空格缩进 bullet body。
- 提交 body 中多条 bullet 必须连续排列, bullet 之间不要空行; 使用命令提交时, 将完整 body 放在同一个 `-m` 参数或 `git commit -F` 文件中, 不要为每条 bullet 单独使用 `-m`。
- 标题格式: `<type>: <中文描述>`, 不加句号。
- 常用 type: `feat`、`fix`、`chore`、`refactor`、`docs`。
- 功能、修复、发布类提交必须写 body; 简单文档或杂项可只写标题行。

示例:

```text
fix: 修复 Codex 状态刷新

    - 合并设置页 onAppear 和 didBecomeActive 的重复版本探测
    - 保留当前运行版本与磁盘安装版本不一致时的更新提示
```

Tag:

- tag 名格式 `v{MARKETING_VERSION}`
- 使用附注 tag: `git tag -a v{MARKETING_VERSION} -m "Release v{MARKETING_VERSION}"`

## 最终检查

返回最终答复或执行不可逆动作前, 快速确认:

- 是否满足用户的所有明确要求。
- 是否基于当前代码和工具输出, 没有使用过期文件名或旧架构名。
- 是否运行了与改动匹配的验证命令。
- 是否说明了未验证项和原因。
- 是否避免泄露本机认证、路径之外的敏感信息或原始错误噪音。

# CLAUDE.md

此文件为 Claude Code 在本仓库工作时提供上下文和约定。请优先遵循这里的项目事实、构建命令和实现边界。

## 目标

CodexBar 是一个 macOS 菜单栏应用, 用本机 Codex app-server 展示当前 Codex 账号的额度和 token 用量。你在本仓库中的目标是交付可验证、贴合现有 SwiftUI/MVVM 架构的修改, 并保护本地认证、隐私、菜单栏体验、Sparkle 更新和发布流程不被无意破坏。

## 成功标准

- 用户请求已转成明确的结果: 代码、文档、脚本、诊断结论或发布操作。
- 修改范围只覆盖完成目标所需的文件; 不顺手重构无关模块, 不回滚他人未提交改动。
- Swift/Xcode 工程修改后运行本文件的构建命令, 结果无 error 和项目代码 warning。
- 文档、图片或发布元数据的纯修改可以不构建, 但最终回复必须说明未运行构建的原因。
- 最终回复说明改了什么、如何验证、还剩什么风险或未执行项。

## 工作方式

- 先读局部上下文, 再行动。优先用 `rg` / `rg --files`、当前文件和相邻模块定位事实; 只有依赖缺失时再扩大范围。
- 多步骤或跨文件任务先给简短计划。计划写清关键文件/系统、验证命令、失败处理和真正会影响实现的开放问题。
- 简单、低风险、可逆的请求直接执行。删除、发布、推送、生产写入、覆盖用户选择或会明显改变行为但缺少关键决策时, 先取得用户明确同意。
- 独立的读取和检索可以并行; 有先后依赖、歧义会影响实现、或动作不可逆时必须顺序执行。
- 工具调用前给一句短说明。长任务中持续同步进度, 但不要把中间状态当最终答复。
- 遇到失败先做最小可行诊断和一次合理重试。仍无法完成时, 说明阻塞点、已验证事实和下一个最小检查。
- 回复保持紧凑, 路径、命令、函数、类型和文件名用反引号。中文说明优先, 除非用户要求英文。
- 修改 prompt、文档或 agent 指令时, 优先保留有效事实和行为边界; 删除或改写会改变执行行为的规则前, 确认它确实与当前目标冲突。

## 验证命令

涉及 Swift/Xcode 工程、资源归属、build setting、Info.plist、SwiftPM 依赖或发布脚本行为的改动后运行:

```bash
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build
```

要求无 error 和 warning。当前 Xcode 可能输出 `Metadata extraction skipped. No AppIntents.framework dependency found.` 的 metadata 阶段 warning, 不作为项目代码 warning 处理。SourceKit 对跨文件类型偶尔误报 `Cannot find type ... in scope`, 以 `xcodebuild` 为准。

工程使用 `PBXFileSystemSynchronizedRootGroup`; 新增或删除 `CodexBar/` 下源码通常无需修改 `project.pbxproj`。只有依赖、target/build settings 或资源归属变更才改 Xcode 工程文件。

## 项目事实

- 平台: SwiftUI + AppKit + MVVM, 最低 macOS 15.0。
- 应用形态: `LSUIElement` 纯菜单栏应用, 无 Dock 图标、无应用菜单。
- 入口: `CodexBarApp` 只声明占位 `Settings { EmptyView() }`; 真实 UI 由 `CodexBarAppDelegate` 和 `StatusItemController` 驱动。
- 外部依赖: Sparkle(SwiftPM)。
- App Sandbox 必须关闭(`ENABLE_APP_SANDBOX = NO`), 因为应用要启动本机 Codex CLI/App 内置 CLI, 并读取真实 macOS 用户的 Codex 登录状态。
- 当前 build settings: `MACOSX_DEPLOYMENT_TARGET = 15.0`, `MARKETING_VERSION = 1.3.6`, `CURRENT_PROJECT_VERSION = 9`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。
- 不要为 macOS 15 以下添加 SF Symbols 或 SwiftUI API fallback。

## 架构地图

数据流:

```text
CodexRateLimitService(JSON-RPC app-server)
  -> RateLimitsViewModel(@MainActor 状态发布)
  -> StatusItemController(菜单栏图标/Popover 生命周期)
  -> RateLimitsMenuView / AppSettingsView(SwiftUI 展示)
```

关键文件职责:

- `CodexBarApp.swift`: `@main` 入口和 `Bundle.displayVersionLabel`(`v1.2.3`, 缺失回退 `--`)。
- `StatusItemController.swift`: 创建 `NSStatusItem`、`NSPopover`、右键菜单、外部点击监控、淡入淡出状态机和自动刷新启动。左键切换 popover, 右键或 Control 点击显示「设置 / 退出」。
- `SettingsWindowController.swift`: 复用单个设置窗口。首次显示或关闭后重开时按 status item 所在屏幕居中; 已可见时只 `deminiaturize`、激活并置顶, 不重新居中或新建窗口。
- `RateLimitsViewModel.swift`: `@MainActor ObservableObject`, 发布 `snapshot`、`isRefreshing`、`lastError`、`codexConnectionInfo`、`autoRefreshCountdownStartedAt`。错误单一来源是 `lastError: CodexRateLimitError?`; `errorMessage`、`requiresLogin`、`hasError` 都从它派生。
- `CodexRateLimitService.swift`: 非 UI 服务, 管理 app-server 进程、JSON-RPC、连接复用、认证重试、usage 降级和当前运行中的 Codex 来源/路径/版本。
- `CodexCLIResolver.swift`: 解析全局 `codex` 与 `/Applications/Codex.app/Contents/Resources/codex`, 并构造 app-server 和版本探测共用的真实用户环境。
- `CodexCLIVersionService.swift`: 并发探测全局 CLI 与 Codex App 内置 CLI 的 `--version`, 合成磁盘版本、当前运行版本和「已更新至」提示。
- `RateLimitModels.swift`: wire DTO 保持纯 `Decodable`; 展示排序、兜底和派生文案放在业务快照转换里。
- `RateLimitsMenuView.swift`: popover 主 UI, 包含登录提示、账号卡片、limit 分节、usage 卡片、更新时间倒计时和错误行。
- `QuotaRow.swift`: 单个 quota window 行和 `SegmentedQuotaBar`, 条形图展示剩余额度。
- `UsageHeatmap.swift` / `TokenCountText.swift`: token 汇总、近 30 周热力图、hover tooltip 和 K/M/B 紧凑数字格式。
- `AppSettingsView.swift` / `LoginItemSettings.swift`: 设置窗口、开机自启、CodexBar 版本、Codex CLI/Codex APP 版本与路径复制。
- `AppUpdater.swift`: Sparkle 封装, 更新状态文案按设置窗、popover 和可用更新三个表面拆分。
- `LiquidGlassStyle.swift`: 自绘 Liquid Glass 视觉入口, 提供 `.liquidGlassSurface(...)`、`.liquidGlassCapsule(...)`、`LiquidGlassDivider`、`Animation.codexStatus` 和 `Color.codexLabel` / `Color.codexSecondaryLabel`。

## Codex app-server 合约

启动命令统一是:

```bash
codex app-server --listen stdio://
```

必须通过 `CodexCLIResolver.resolveAppServerCommand()` 解析:

- 优先 PATH 中的全局 `codex`。
- 如果 PATH 中解析到的路径等价于 `/Applications/Codex.app/Contents/Resources/codex`, 当作内置 Codex APP CLI, 不当作全局 CLI。
- 全局 CLI 不存在时回退 Codex APP 内置 CLI。
- 两者都不存在时展示「找不到 Codex CLI 或 Codex APP」。

启动环境由 `CodexCLIResolver.environment` 构造:

- 保留当前环境, 但 `HOME` 必须用 `getpwuid(getuid())` 得到真实用户 home。
- 同步设置 `USER`、`LOGNAME`。
- 合并 Homebrew、npm global、`.local`、Volta 和系统路径。
- 确保 `TERM` 有值。
- 不要改回 Xcode sandbox/container 的 `HOME`, 否则会读不到 `~/.codex/auth.json`。

首次连接必须先握手再读额度:

```json
{"method":"initialize","id":1,"params":{"clientInfo":{"name":"codex_bar","title":"Codex Bar","version":"<Bundle MARKETING_VERSION 或 1.0.0>"}}}
{"method":"initialized"}
{"method":"account/read","id":2,"params":{"refreshToken":false}}
```

同一会话后续读取:

- `account/rateLimits/read`: 额度数据。认证失败时同会话先调用 `account/read`(`refreshToken: true`) 再重试一次; 仍失败抛 `authenticationRequired`。
- `account/usage/read`: token 统计。读取 `summary.lifetimeTokens`、`summary.peakDailyTokens`、`dailyUsageBuckets`。如果返回 method not found / unknown / unsupported / not supported, 将当前连接的 `isUsageReadAvailable` 置为 false, 本连接后续不再请求 usage。其他 usage 错误只隐藏 token 区域, 额度仍正常展示。

连接细节:

- `requestTimeout` 是 20 秒。
- `initialize` 响应的 `userAgent` 首个 token 形如 `codex_bar/0.139.0 (...)`; `serverVersion(fromUserAgent:)` 取 `/` 后版本号作为当前运行版本。
- 每条连接保存 `CodexCLIConnectionInfo(source, executablePath, version, openedAt)`, 设置页用它标记「当前使用」。
- `JSONLineReader` 按行读取 stdout, 只消费匹配请求 id 的响应; stdout EOF 时标记关闭并唤醒等待中的请求。
- `PipeDrain` 持续排空 stderr, stderr 不进入用户可见文案; stderr EOF 时停止 readability handler。

## 自动刷新与连接重建

- `RateLimitsViewModel.refreshInterval` 是 60 秒。
- `startAutoRefresh()` 启动一个 `Task`, 每轮按 `autoRefreshDelay`(距下次刷新的剩余秒数, 下限 1 秒; `autoRefreshCountdownStartedAt` 为空时取 `refreshInterval`)休眠后调用 `refreshIfNeeded()`, 不再每秒空转唤醒。
- `refreshIfNeeded()` 只看 `autoRefreshCountdownStartedAt` 距当前是否超过 60 秒, 作为动态休眠的兜底判断。
- `refresh()` 用 `isRefreshing` 合并并发触发; 开始时不要清空 `lastError`。
- `refresh()` 成功后更新 `snapshot` 并清空 `lastError`; 失败时保留旧 `snapshot`, 写入 `lastError`。
- 无论成功失败, 刷新结束都更新 `codexConnectionInfo`、重置 `autoRefreshCountdownStartedAt`, 并关闭 `isRefreshing`。
- popover 显示后延迟调用 `refreshIfNeeded()`; 账号图标双击触发手动 `refresh()`。

`CodexRateLimitService` 是 `nonisolated final class` + `@unchecked Sendable`, 连接状态只在 `DispatchQueue(label: "CodexBar.app-server")` 上读写:

- 进程已退出 -> 重建。
- 连接存活超过 `connectionMaxAge`(1 小时) -> 关闭后重建, 覆盖 Codex 升级或服务端状态漂移。
- 复用连接上的非登录类请求失败 -> 丢弃连接, 重建一次再试。
- 全新连接上的失败 -> 直接抛出, 避免故障时重复完整握手。
- 登录类错误(`requiresLogin`) -> 丢弃连接但不立即重试; 下次轮询重新启动进程读取最新登录状态。

## 数据模型规则

`CodexQuotaSnapshot`:

- 必须有 `AccountReadResponse.account`, 否则抛 `notLoggedIn`。
- 优先读取 `rateLimitsByLimitId` 支持多 limit; 为空则回退顶层 `rateLimits`。
- 顶层 `rateLimits.limitId` 指向的主 limit 置顶, 缺省 `"codex"`。
- 其余 limit 按 `limitName ?? limitId` 做 localized standard 排序, 再按 `limitId` 稳定排序。
- 每个 limit 的 `primary` / `secondary` 合成 `[QuotaWindow]`; 没有窗口的 limit 被过滤, 全部为空才抛 `missingRateLimitWindow`。
- `QuotaWindow.remainingPercent = clamp(100 - usedPercent, 0...100)`; 无 `usedPercent` 视为无数据。
- `windowDurationMins` 标签: 整天为「N 天」, 整小时为「N 小时」, 否则「N 分钟」, 缺失或非正数为「额度」。

`CodexUsageSnapshot`:

- `recentWeekGrid(columnCount:endingDaysAgo:today:)` 基于本地当天零点生成按周对齐的日期网格。
- UI 使用 `UsageHeatmap.Metrics.columnCount = 30` 且 `endingDaysAgo = 1`, 默认不包含今天。
- 最右列锚定最后一个可见日期所在的周日开头周, 避免今天是周日时出现整列空白。
- 返回值中的 `nil` 表示今天、未来日期或不可生成日期; 热力图不绘制方块也不参与峰值计算。
- 颜色按当前可见日期区间内峰值缩放。

## 并发与隔离

工程开启 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; 未显式标注的类型会推断为 MainActor 隔离。

- UI 层保持 `@MainActor` 或主线程使用: `CodexBarAppDelegate`、`StatusItemController`、`SettingsWindowController`、`RateLimitsViewModel`、`AppUpdater`、`LoginItemSettings`、`CodexCLIVersionViewModel`。
- 服务层对外暴露 async API, 内部用串行 queue 管理 `Process`、`Pipe` 和连接状态。
- 非 UI 类型、DTO、模型、服务辅助类型和部分静态工具需要显式 `nonisolated`, 避免 `Call to main actor-isolated initializer in a synchronous nonisolated context`。
- `CodexRateLimitService` 使用 `CodexBar.app-server` 队列。
- `CodexCLIVersionService` 使用 `CodexBar.codex-version` 队列, 全局和内置版本探测先并发启动再收集。

## UI 约束

菜单栏:

- 正常图标是 `person.fill.checkmark`, 错误图标是 `person.fill.xmark`。
- `StatusItemController.updateStatusImage(hasError:)` 只随 `lastError` 的有无变化设置图标。
- 菜单栏不展示额度数字; 详情只在 popover 中展示。
- App 图标保持白底黑色 `timelapse`。

Popover:

- `RateLimitsMenuView.menuWidth` 由热力图总宽度和 padding 推导; 修改热力图尺寸时同步检查弹窗宽度。
- 外层和分区使用 `.liquidGlassSurface(...)`; 分隔线使用 `LiquidGlassDivider`; 小徽章可用 `.liquidGlassCapsule(...)`。
- `LiquidGlassStyle.swift` 是自绘玻璃效果, 不是 macOS 26 原生 `.glassEffect`。没有明确设计要求时不要切换。
- 账号行 plan 是右侧加粗纯文字, 不加胶囊底色或额外 padding。`planBadgeTint(for:)` 优先级: enterprise -> team/business -> pro -> plus -> edu -> free -> 默认 cyan。
- 邮箱双击可模糊/取消模糊; 账号图标双击手动刷新。
- limit 分节标题取 `limitName` 回退 `limitId`, 首字母大写; 节之间使用 `LiquidGlassDivider`。
- 额度条展示剩余百分比, 颜色按 20% 一档: 0-19 红色, 20-39 橙色, 40-59 黄色, 60-79 薄荷色, 80-100 绿色。
- 无 quota 数据时显示 `--` / `暂无数据`, 并用占位色。
- 重置时间格式 `MM-dd HH:mm`。
- 更新时间行显示顺时针自动刷新倒计时圆环、「数据更新时间」和 `HH:mm:ss`; 时间文本使用 `.contentTransition(.numericText())` 和 `Color.codexSecondaryLabel`, 不展示应用版本号。
- 倒计时圆环(`AutoRefreshCountdownCircle`)用 `Circle().trim` 按秒离散跳格, 不做连续动画: `Shape.trim` 的长连续动画是逐帧 CPU 重绘, 比每秒采样更耗 CPU, 不要改成连续动画。每秒采样由 `AutoRefreshCountdownTimeline` 的 `TimelineView` 驱动, 且只在 popover 可见(`PopoverVisibilityState.isVisible`, 由 `StatusItemController` 在 popover show/close 时维护)时启用; 隐藏时静态渲染一次。仅 `startedAt` 变化(刷新重置)且可见时播放 0.2 秒恢复动画, 普通 tick 直接跳变。
- token 区域显示「单日峰值」和「全时累计」; `TokenCountText` 对 1K 以下显示完整整数, 1K 起显示 K/M/B。
- 热力图是近 30 周、30 列 x 7 行、周日到周六排列、默认不包含今天; hover tooltip 显示日期和单日 token。

错误展示:

- 登录类错误(`requiresLogin`)时, popover 顶部显示橙色「Codex 未登录」。
- 登录类错误会让旧快照 `opacity(0.4)` 置灰保留, 并抑制红色错误行。
- 其他错误显示红色小字 `errorDescription`, 旧快照保持全亮度。
- 旧额度快照永远不因失败而清空。
- app-server 相关用户可见错误通过 `CodexRateLimitError.errorDescription` 生成; 不要把子进程 stderr 或原始日志拼进 UI。

设置窗口:

- 通过菜单栏图标右键或 Control 点击菜单的「设置」打开独立 `AppSettingsView` 窗口。
- 不要恢复为 Option 点击或 popover 内设置区。
- 设置页包含「CodexBar 版本」和「Codex 版本」两个版本区域。
- `Codex CLI` 行图标用 `terminal`; `Codex APP` 行图标用 `app.badge`。
- Codex CLI/Codex APP 子行相对标题缩进, 当前运行来源显示「当前使用」徽章。
- 当前行优先展示 app-server 握手自报运行版本; 非当前行展示磁盘安装版本。
- 如果当前运行版本与磁盘安装版本不同, 显示「已更新至 <version>」。
- 路径点击复制到剪贴板, 对应来源显示「已复制」1.5 秒; 保留路径文本布局宽度避免跳动。
- 设置页版本状态、Codex 版本值、复制提示、popover 更新提示和错误提示使用 `Animation.codexStatus` 做淡入淡出。

## Sparkle 更新

`AppUpdater` 是 `@MainActor ObservableObject`。

- 初始化时先校验 `Info.plist` 的 `SUFeedURL`(http/https) 和 `SUPublicEDKey`(非空)。
- 任一缺失时不创建 `SPUStandardUpdaterController`, 更新操作显示「未配置更新资源」。
- `canConfigureAutomaticChecks` 是 `updaterController != nil` 的计算属性; 设置窗「自动检查更新」开关据此禁用。
- `settingsStatusMessage`: 设置窗版本行状态, 默认 3 秒后由可取消 `Task` 清空; `autoDismissDelay: nil` 时常驻。
- `panelUpdateMessage`: popover 底栏被动提示, 双击可触发 `startUpdate()`。
- `availableUpdateMessage`: 发现新版的语义状态, 驱动设置窗版本行和「立即更新」按钮。
- `checkForUpdates()` 是设置窗手动检查, 设置 `isManualCheckInProgress`。
- 如果已经有 `availableUpdateMessage`, 手动检查只把该消息常驻显示到设置窗。
- `startUpdate()` 激活应用并调用 Sparkle 安装面板。
- 委托回调按 `isManualCheckInProgress` 路由: 手动结果进 `settingsStatusMessage`, 自动发现新版进 `panelUpdateMessage`。
- `Info.plist` 当前 `SUFeedURL = https://codexbar.zabrian.app/appcast.xml`, `SUScheduledCheckInterval = 3600`。

## 认证、隐私与沙盒

- CodexBar 只与本机 Codex app-server 进程通信; 账号、额度和 token 使用量不发往第三方服务。
- 除 Sparkle appcast/DMG 下载外, 应用自身不做网络请求。
- App Sandbox 必须保持关闭。开启沙盒会破坏 CLI 启动或真实用户登录状态读取。
- app-server 和版本探测必须使用真实用户 home, 避免 Xcode 运行时 `HOME` 指向 app container 导致 `codex account authentication required`。
- 不要把 Codex auth 文件、stderr、原始 RPC 响应或用户路径之外的敏感信息写入 UI、日志、文档或测试夹具。

## Git 规则

- 不要主动 push; 必须等用户明确同意。
- 不要回滚或覆盖你没做的未提交改动。
- 提交 message 使用 Conventional Commits 前缀 + 中文标题 + 空行 + 4 空格缩进 bullet body。
- 标题格式: `<type>: <中文描述>`, 不加句号。
- 常用 type: `feat`、`fix`、`chore`、`refactor`、`docs`。
- 功能、修复、发布类提交必须写 body; 简单文档或杂项可只写标题行。

示例:

```text
fix: 修复 Codex 版本状态刷新

    - 合并设置页 onAppear 和 didBecomeActive 的重复版本探测
    - 保留当前运行版本与磁盘安装版本不一致时的更新提示
```

Tag:

- tag 名格式 `v{MARKETING_VERSION}`, 例如 `v1.3.6`。
- 使用附注 tag: `git tag -a v1.3.6 -m "Release v1.3.6"`。
- tag 不主动 push。

## 发布流程

1. 用 `Developer ID Application` 证书签名并 notarization, Xcode 导出 `CodexBar.app` 到项目根目录。
2. 运行 `Scripts/create-dmg.sh [App.app] [Output.dmg]`。未传 app 时自动查找项目根目录唯一 `.app`; 默认输出 `CodexBar-v{MARKETING_VERSION}.dmg`; DMG 包含 Applications 快捷方式和 Finder 布局。依赖 `hdiutil`、`osascript`、`ditto`。
3. 运行 `Scripts/update-appcast.sh [CodexBar-vX.Y.Z.dmg]`。未传 DMG 时自动找项目根目录唯一 `.dmg`; 使用 Sparkle `sign_update` 签名; 从 Release build settings 读取 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`; 将同 build version 的旧 `<item>` 去重后写入 `Updates/appcast.xml`; 有 `xmllint` 时校验。
4. 常用环境变量: `APPCAST_PATH`、`DOWNLOAD_BASE_URL`、`RELEASE_NOTES_BASE_URL`、`INCLUDE_RELEASE_NOTES`、`MINIMUM_SYSTEM_VERSION`、`SIGN_UPDATE`、`XCODE_PROJECT`、`XCODE_SCHEME`。
5. 上传 DMG 和更新后的 `appcast.xml` 到 `SUFeedURL` 对应站点。

## 停止规则

- 构建或验证失败时, 不要声称完成; 先定位可操作错误。若无法修复, 交代失败命令、关键输出和下一步。
- 官方文档或外部事实会影响实现时, 先查官方来源; 不确定就说明不确定。
- 用户要求的文件名与仓库事实冲突时, 采用仓库中的真实文件并在最终回复说明。例如本仓库使用 `AGENTS.md`, 不是 `AGENT.md`。
- 发布、推送、删除、重置历史、覆盖未提交用户改动、写入仓库外路径或触发真实更新分发前, 必须得到明确同意。

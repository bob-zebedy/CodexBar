# AGENTS.md

此文件为 Codex 在本仓库工作时提供上下文和约定。请优先遵循这里的项目事实、构建命令和实现边界。

## 项目概览

CodexBar 是一个 macOS 菜单栏应用(SwiftUI + MVVM,最低 macOS 15.0),通过本机 Codex app-server 展示当前 Codex 账号的额度和 token 用量。`LSUIElement` 纯菜单栏应用(无 Dock 图标、无应用菜单),入口经 `NSApplicationDelegateAdaptor`(`CodexBarAppDelegate`)启动,再由 `StatusItemController` 手动管理 `NSStatusItem`、`NSPopover` 和右键菜单。唯一外部依赖是 Sparkle(SwiftPM)。

Xcode target 关闭了 App Sandbox,因为应用需要启动本机 Codex CLI/App 内置 CLI,并读取当前 macOS 用户的 Codex 登录状态。最低系统版本已是 macOS 15.0,不要给 SF Symbols 或 SwiftUI API 增加低版本 fallback。

## 构建验证

涉及 Swift/Xcode 工程的修改后运行:

```bash
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build
```

要求无 error 和 warning

SourceKit 经常对跨文件类型误报「Cannot find type ... in scope」(索引滞后),以 `xcodebuild` 实际编译结果为准。当前 Xcode 可能输出 `Metadata extraction skipped. No AppIntents.framework dependency found.` 的 metadata 阶段 warning,不作为项目代码 warning 处理。文档、图片或发布元数据的纯修改可以不跑构建,但最终回复要说明未运行。

工程使用文件系统同步组(`PBXFileSystemSynchronizedRootGroup`):新增/删除 `CodexBar/` 下源码通常无需修改 `project.pbxproj`,只有依赖、target/build settings 或资源归属变更才需要改它。

## 架构与文件分工

数据流:`CodexRateLimitService`(JSON-RPC 常驻连接)→ `RateLimitsViewModel`(状态发布)→ `StatusItemController`(菜单栏图标刷新)/`RateLimitsMenuView`(popover 弹窗)。

- `CodexBarApp.swift`:`@main`,仅声明占位 `Settings { EmptyView() }` Scene;真实 UI 由 `CodexBarAppDelegate` 驱动。同文件有 `nonisolated extension Bundle` 提供 `shortVersionString` 和 `displayVersionLabel`(`v1.2.3`,缺失回退 `--`)。
- `StatusItemController.swift`:`CodexBarAppDelegate` 持有 `RateLimitsViewModel` 和 `AppUpdater`。私有 `StatusItemController` 配置菜单栏按钮、popover、Combine 订阅和自动刷新;左键切换 popover,右键或 Control 点击弹出「设置 / 退出」菜单。popover 使用手写淡入淡出、`PopoverState` 状态机、本地/全局 mouse monitor 外部点击关闭,并在显示后延迟调用 `refreshIfNeeded()`;设置窗口注入同一个 `RateLimitsViewModel` 和 `AppUpdater`。
- `SettingsWindowController.swift`:独立管理设置窗口生命周期,复用同一个 `NSWindow`,内容为注入 `RateLimitsViewModel` 和 `AppUpdater` 的 `AppSettingsView`。首次显示或关闭后重开时通过 status item 所在屏幕居中;窗口已可见时再次打开只负责 `deminiaturize`、激活应用并置顶,不要重新居中或创建第二个窗口。
- `RateLimitsViewModel.swift`:主线程 `ObservableObject`,发布 `snapshot`、`isRefreshing`、`lastError`、`codexConnectionInfo` 和 `autoRefreshCountdownStartedAt`。错误状态单一来源是 `lastError: CodexRateLimitError?`,`errorMessage`、`requiresLogin`、`hasError` 都是派生计算属性,不要增加并列错误布尔或重复错误字符串状态。`codexConnectionInfo` 来自 `CodexRateLimitService.currentConnectionInfo()`;`autoRefreshInterval` 暴露 60 秒自动刷新间隔给 UI 倒计时。
- `CodexRateLimitService.swift`:非 UI 服务,负责 app-server 进程、JSON-RPC 请求/响应、连接复用、认证重试、usage 能力降级,并记录当前连接实际启动的 Codex 来源、路径和运行版本。
- `CodexCLIResolver.swift`:Codex 可执行文件解析和 app-server 环境构造入口。负责区分 PATH 中的全局 `codex` 与 `/Applications/Codex.app/Contents/Resources/codex`,并给 app-server 和版本探测共用同一份真实用户环境。
- `CodexCLIVersionService.swift`:设置页 Codex 版本探测服务和展示模型。并发读取全局 CLI 与 Codex App 内置 CLI 的 `--version`,合成磁盘安装版本、当前运行版本和「已更新至」提示。
- `RateLimitModels.swift`:wire DTO 保持纯 `Decodable`,展示排序/兜底只放在业务快照转换里。核心模型是 `CodexQuotaSnapshot` → `CodexQuotaLimitSnapshot` → `QuotaWindow`,以及 `CodexUsageSnapshot`。
- `RateLimitsMenuView.swift`:popover 主 UI,负责登录提示、账号卡片、limit 分节、使用量卡片、更新时间倒计时和错误行。邮箱双击可模糊/取消模糊,账号图标双击触发手动刷新;更新时间行使用 `TimelineView` 绘制自动刷新倒计时圆环。
- `QuotaRow.swift`:单个 quota window 行和 `SegmentedQuotaBar`;条形图展示剩余额度而不是已用额度。
- `UsageHeatmap.swift` / `TokenCountText.swift`:token 汇总、30 列 × 7 行热力图、hover tooltip 和 token 数字格式。`TokenCountText` 对 1K 以下直接显示完整整数,1K 起使用 K/M/B 紧凑格式。
- `AppSettingsView.swift` / `LoginItemSettings.swift`:设置窗口 UI、`SMAppService.mainApp` 开机自启和 Codex 版本区。开机自启状态读取是同步 XPC,在设置窗口 `onAppear` 刷新;Codex 版本区展示 CodexBar 版本、Codex CLI/Codex APP 版本与路径,路径点击复制并淡入显示「已复制」1.5 秒,同时保留路径文本布局宽度避免跳动。
- `AppUpdater.swift`:Sparkle 封装和更新状态文案路由。
- `LiquidGlassStyle.swift`:Liquid Glass 视觉入口,包括 `.liquidGlassSurface(...)`、`.liquidGlassCapsule(...)` 和 `LiquidGlassDivider`;同时提供 `Animation.codexStatus` 统一状态文案过渡动画,以及 `Color.codexLabel` / `Color.codexSecondaryLabel` 给需要具体 `Color` 的转场和 tooltip 使用。

## Codex app-server 连接

启动命令为 `codex app-server --listen stdio://`。解析命令统一走 `CodexCLIResolver.resolveAppServerCommand()`:优先找 PATH 中的全局 `codex`,但如果找到的路径等同于 `/Applications/Codex.app/Contents/Resources/codex`,则按内置 Codex.app CLI 处理;全局 CLI 不存在时回退 Codex.app 内置 CLI;两者都没有时展示「找不到 Codex CLI 或 Codex APP」。

启动环境由 `CodexCLIResolver.environment` 构造:保留当前环境,但 `HOME` 使用 `getpwuid(getuid())` 得到的真实用户 home,同步设置 `USER`、`LOGNAME`,合并 Homebrew、npm global、`.local`、Volta 和系统路径,并确保 `TERM` 有值。不要改回 Xcode sandbox/container 的 `HOME`,否则会读不到 `~/.codex/auth.json`。

应用维持一条常驻连接。首次握手必须在请求额度前完成:

```json
{"method":"initialize","id":1,"params":{"clientInfo":{"name":"codex_bar","title":"Codex Bar","version":"<Bundle MARKETING_VERSION 或 1.0.0>"}}}
{"method":"initialized"}
{"method":"account/read","id":2,"params":{"refreshToken":false}}
```

之后同一会话上读取:

- `account/rateLimits/read`:额度数据,认证失败时先同会话调用 `account/read`(`refreshToken: true`)再重试一次;仍失败抛 `authenticationRequired`。
- `account/usage/read`:token 统计,读取 `summary.lifetimeTokens`、`summary.peakDailyTokens`、`dailyUsageBuckets`。如果 app-server 返回 method not found/unknown/unsupported/not supported,当前连接的 `isUsageReadAvailable` 置为 false,本连接后续不再请求 usage;其他 usage 错误也只隐藏 token 区域,额度信息仍正常显示。

`initialize` 响应解析为 `InitializeResult`,其中 `userAgent` 的首个 token 形如 `codex_bar/0.139.0 (...)`;`CodexRateLimitService.serverVersion(fromUserAgent:)` 取 `/` 后版本号作为当前运行版本。每条连接保存 `CodexCLIConnectionInfo(source, executablePath, version, openedAt)`,设置页用它标记「当前使用」。

`requestTimeout` 是 20 秒。`JSONLineReader` 按行读取 stdout,只消费匹配请求 id 的响应;`PipeDrain` 持续排空 stderr 且不进入用户可见文案。

## Codex 版本展示

设置页的「Codex 版本」分区同时展示两个来源:

- `Codex CLI`:PATH 中解析到的全局 CLI,图标使用 `terminal`。
- `Codex APP`:`/Applications/Codex.app/Contents/Resources/codex` 或等价路径,图标使用 `app.badge`。

`CodexCLIVersionService` 通过 `codex --version` 探测磁盘安装版本,全局和内置两个探测先并发启动再分别收集,单个探测超时 5 秒。探测错误只展示固定文案(`启动失败`/`读取超时`/`读取失败`/`版本未知`),不要把 stderr 原文透传给用户。

`CodexCLIVersionViewModel.refresh()` 会合并并发触发,并对 60 秒内的重复触发节流。设置页在 `onAppear` 和 `NSApplication.didBecomeActiveNotification` 时调用刷新;当前没有用户可见的手动刷新按钮。路径行点击后复制到剪贴板,对应来源显示「已复制」1.5 秒。

当前使用来源由 `RateLimitsViewModel.codexConnectionInfo` 决定。当前行优先展示 app-server 握手自报的运行版本;非当前行展示磁盘安装版本。如果当前运行版本与磁盘安装版本不同,说明后台升级后当前连接尚未重建,UI 显示「已更新至 <version>」。app-server 每小时连接回收后会重新握手并更新当前运行版本。

## 额度与使用量模型

`CodexQuotaSnapshot` 转换规则:

- 必须有 `AccountReadResponse.account`,否则抛 `notLoggedIn`。
- 优先读取 `rateLimitsByLimitId` 以支持多 limit;为空则回退顶层 `rateLimits`。
- 顶层 `rateLimits.limitId` 指向的主 limit 置顶,缺省 `"codex"`;其余按 `limitName ?? limitId` 做 localized standard 排序,再按 `limitId` 稳定排序。
- 每个 limit 的 `primary`/`secondary` 窗口合成 `[QuotaWindow]`;没有窗口的 limit 被过滤,全部为空才抛 `missingRateLimitWindow`。
- `QuotaWindow.remainingPercent = clamp(100 - usedPercent, 0...100)`,无 `usedPercent` 时视为无数据。
- `windowDurationMins` 动态生成标签:整天显示「N 天」,整小时显示「N 小时」,否则显示「N 分钟」,缺失或非正数显示「额度」。

`CodexUsageSnapshot.recentDays(count:endingDaysAgo:)` 基于本地当天零点生成连续日期,按 `yyyy-MM-dd` 汇总 `dailyUsageBuckets`。UI 当前展示 `UsageHeatmap.Metrics.dayCount`(210 天)且 `endingDaysAgo: 1`,也就是默认不包含今天。热力图颜色按当前展示区间内的峰值缩放。

## 自动刷新节奏

`RateLimitsViewModel.refreshInterval` 是 60 秒。`startAutoRefresh()` 启动一个每秒唤醒的 `Task`,每次调用 `refreshIfNeeded()`;`refreshIfNeeded()` 只根据 `autoRefreshCountdownStartedAt` 距当前时间是否超过 60 秒判断是否刷新。`refresh()` 用 `isRefreshing` 合并并发触发,避免手动/自动重复刷新。

`refresh()` 完成后会更新 `codexConnectionInfo`、`autoRefreshCountdownStartedAt` 并关闭 `isRefreshing`,无论本次刷新成功还是失败都会重置下一次自动刷新倒计时。popover 更新时间前的圆环以 `autoRefreshCountdownStartedAt` 为满圈起点,每秒顺时针减少,空圈后下一次自动检查会触发刷新;账号图标双击手动刷新完成后同样让圆环回到满圈。

## 连接重建规则

`CodexRateLimitService` 是 `nonisolated final class` + `@unchecked Sendable`,连接状态只在私有串行 `DispatchQueue(label: "CodexBar.app-server")` 上读写。

- 进程已退出 → 重建。
- 连接存活超过 `connectionMaxAge`(1 小时)→ 关闭后重建,覆盖 Codex 升级或服务端状态漂移,并刷新 `CodexCLIConnectionInfo` 的运行版本。
- 复用连接上的非登录类请求失败 → 丢弃连接,重建一次再试。
- 全新连接上的失败 → 直接抛出,避免故障时重复完整握手。
- 登录类错误(`requiresLogin`)→ 丢弃连接但不立即重试;下次轮询重新启动进程读取最新登录状态,用户重新登录后最多一分钟自动恢复。

## 并发约定

工程开启 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`:未显式标注的类型会推断为 MainActor 隔离。因此非 UI 类型、DTO、模型、服务辅助类型和部分静态工具必须显式 `nonisolated`,否则容易出现「Call to main actor-isolated initializer in a synchronous nonisolated context」。

UI 层(`CodexBarAppDelegate`、`StatusItemController`、`SettingsWindowController`、`RateLimitsViewModel`、`AppUpdater`、`LoginItemSettings`、`CodexCLIVersionViewModel`)保持 `@MainActor` 或主线程使用。服务层对外暴露 async API,内部用 queue 串行化 Process/Pipe 状态。`CodexRateLimitService` 使用 `CodexBar.app-server` 串行队列,`CodexCLIVersionService` 使用 `CodexBar.codex-version` 串行队列。

## UI 与错误展示约定

- 菜单栏正常图标是 `person.fill.checkmark`,错误图标是 `person.fill.xmark`;由 `StatusItemController.updateStatusImage()` 直接设置 `NSStatusItem.button.image`。菜单栏不展示额度数字,详情只在 popover 中展示。
- App 图标保持白底黑色 `timelapse`。
- popover 宽度由 `RateLimitsMenuView.menuWidth` 绑定到热力图总宽度和 padding;修改热力图尺寸时同步检查弹窗宽度。
- 弹窗整体采用 Liquid Glass 风格:外层和分区使用 `.liquidGlassSurface(...)`,分隔线用 `LiquidGlassDivider`;「当前使用」等小徽章可使用 `.liquidGlassCapsule(...)`。不要把设置、额度、usage 区块改回普通卡片样式。
- `LiquidGlassStyle.swift` 当前是自绘 SwiftUI 玻璃效果(渐变、描边、高光和阴影),不是 macOS 26 原生 `.glassEffect`。不要在没有明确设计要求时切换到系统 `.glassEffect`,当前视觉以自绘方案为准。
- 账号行 plan 展示为右侧加粗纯文字,不加胶囊底色或额外 padding;颜色由 `planBadgeTint(for:)` 按子串匹配,优先级:enterprise → team/business → pro → plus → edu → free → 默认 cyan。
- 弹窗按 limit 分节展示,标题取 `limitName` 回退 `limitId` 并首字母大写;节之间用 `LiquidGlassDivider`。
- 额度条展示剩余百分比(`100 - usedPercent`),颜色按 20% 一档递进:0-19 红色,20-39 橙色,40-59 黄色,60-79 薄荷色,80-100 绿色;无数据使用占位色并显示 `--` / `暂无数据`。
- 重置时间格式 `MM-dd HH:mm`;更新时间行显示顺时针自动刷新倒计时圆环、「数据更新时间」和 `HH:mm:ss`,时间文本使用 `.contentTransition(.numericText())` 和 `Color.codexSecondaryLabel`,不展示应用版本号。
- token 区域显示「单日峰值」和「全时累计」,数字通过 `TokenCountText` 格式化;1K 以下直接显示整数,1K 起显示 K/M/B。下方是 30 × 7 蓝色热力图;hover tooltip 显示日期和单日 token。
- 设置走菜单栏图标右键或 Control 点击菜单的「设置」项,打开独立 `AppSettingsView` 窗口;不要恢复为 Option 点击或 popover 内设置区。设置页包含「CodexBar 版本」和「Codex 版本」两个版本区域;Codex CLI/Codex APP 子行相对标题缩进,并用「当前使用」徽章标记实际运行来源。
- 设置页版本状态、Codex 版本值、复制提示、popover 更新提示和错误提示使用 `Animation.codexStatus` 做淡入淡出;路径复制提示应保持路径文本布局宽度,避免「已复制」出现时行宽跳动。
- 登录类错误(`requiresLogin`)时,popover 顶部显示橙色「Codex 未登录」,旧快照 opacity 0.4 置灰保留,红色错误行被抑制。
- 其他错误显示红色小字 `errorDescription`,旧快照保持全亮度。
- `refresh()` 开始时不要清空 `lastError`;错误文案保持到某次刷新成功才消失。旧额度快照永远不因失败而清空。
- app-server 相关用户可见错误通过 `CodexRateLimitError.errorDescription` 生成;不要把子进程 stderr 或原始日志拼进 UI 文案。

## 自动更新(Sparkle)

`AppUpdater` 是 `@MainActor ObservableObject`。初始化时先校验 Info.plist 的 `SUFeedURL`(http/https)和 `SUPublicEDKey`(非空);任一缺失则不创建 `SPUStandardUpdaterController`,所有更新操作文案显示「未配置更新资源」,Debug/未签名构建静默降级。`canConfigureAutomaticChecks` 是 `updaterController != nil` 的计算属性,设置窗的「自动检查更新」开关据此禁用。

更新文案按 UI 表面拆分,不要合并:

- `settingsStatusMessage`:设置窗版本行状态,默认 3 秒后由可取消 `Task` 清空;传 `autoDismissDelay: nil` 时常驻。
- `panelUpdateMessage`:popover 底栏被动提示,双击可触发 `startUpdate()`。
- `availableUpdateMessage`:发现新版的语义状态,驱动设置窗版本行和「立即更新」按钮。

`checkForUpdates()` 是设置窗手动检查,设置 `isManualCheckInProgress`;若已经有 `availableUpdateMessage`,只把该消息常驻显示到设置窗。`startUpdate()` 激活应用并调用 Sparkle 安装面板。`setAutomaticallyChecksForUpdates(_:)` 和 `refreshAutomaticCheckSetting()` 同步 Sparkle 开关状态。委托回调按 `isManualCheckInProgress` 路由:手动检查结果进 `settingsStatusMessage`,自动检查发现新版进 `panelUpdateMessage`。

Info.plist 位于 `CodexBar/Resources/Info.plist`,当前 `SUFeedURL = https://codexbar.zabrian.app/appcast.xml`,`SUScheduledCheckInterval = 3600`。

## 认证、隐私与沙盒

CodexBar 只与本机 app-server 进程通信,账号与额度数据不发往第三方服务。除 Sparkle appcast/DMG 下载外,应用自身不做网络请求。

App Sandbox 必须保持关闭(`ENABLE_APP_SANDBOX = NO`),否则无法可靠启动 Codex CLI 或读取当前用户登录状态。`CodexCLIResolver.environment` 必须用真实用户 home 运行 app-server 和版本探测,以免 Xcode 运行时 `HOME` 指向 app container 导致 "codex account authentication required"。

## Git 提交规范

- 提交 message 使用 **Conventional Commits 前缀 + 中文标题 + 空行 + 缩进 bullet body**。
- 标题行格式:`<type>: <中文描述>`,描述简洁,不加句号。
- 常用 type:`feat`(新功能)、`fix`(修复)、`chore`(杂项/发布)、`refactor`(重构)、`docs`(文档)。
- 标题行后空一行再写 body;body 使用 4 个空格缩进的 `- ` 列表。
- body 每条 bullet 描述一个具体变更点,优先覆盖新增/修改的核心模块、用户可见行为、脚本/资源/配置变化;不要写泛泛总结。
- 简单文档或杂项改动如确实没有多个变更点,可以只写标题行;功能、修复、发布类提交必须写 body。
- 提交后不要主动 push,必须等用户明确同意后才能推送。

### Tag 规范

- tag 名格式:`v{MARKETING_VERSION}`(如 `v1.3.3`),与 Xcode target 的 `MARKETING_VERSION` 保持一致。
- 使用附注 tag(`git tag -a`),message 格式:`Release v{version}`(如 `git tag -a v1.3.3 -m "Release v1.3.3"`)。
- tag 同样不要主动 push,等用户明确同意。

## 发布流程

1. 用 `Developer ID Application` 证书签名并 notarization,Xcode 导出 `CodexBar.app` 到项目根目录。
2. `Scripts/create-dmg.sh [App.app] [Output.dmg]`:未传 app 时自动找到项目根目录唯一 `.app`;按 Xcode `MARKETING_VERSION` 生成默认 `CodexBar-v{version}.dmg`;DMG 内含 Applications 快捷方式和 Finder 布局。脚本依赖 `hdiutil`、`osascript`、`ditto`。
3. `Scripts/update-appcast.sh [CodexBar-vX.Y.Z.dmg]`:未传 DMG 时自动找项目根目录唯一 `.dmg`;用 Sparkle `sign_update` 签名,从 Release build settings 读取 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`,将同 build version 的旧 `<item>` 去重后写入 `Updates/appcast.xml`,有 `xmllint` 时校验。
4. 常用环境变量:`APPCAST_PATH`、`DOWNLOAD_BASE_URL`、`RELEASE_NOTES_BASE_URL`、`INCLUDE_RELEASE_NOTES`、`MINIMUM_SYSTEM_VERSION`、`SIGN_UPDATE`、`XCODE_PROJECT`、`XCODE_SCHEME`。
5. 上传 DMG 和更新后的 `appcast.xml` 到 `SUFeedURL` 对应站点。

# AGENTS.md

本文件是 Codex 在本仓库工作的持久指令。根目录范围内均适用；如果子目录未来出现更近的 `AGENTS.md`, 以更近文件为准。

本文件按 OpenAI GPT-5.5 prompt guidance 的思路组织: 结果优先、约束明确、上下文可追溯、验证轻量但必须执行。不要把它当成逐步脚本机械执行；遇到更直接、安全、可验证的路径时, 选择更高效的做法。

## 目标

CodexBar 是一个 macOS 菜单栏应用, 通过本机 Codex app-server 展示当前 Codex 账号、额度、token 用量、Codex CLI/APP 版本和交互日志。你的目标是交付可验证、范围清晰、贴合现有 SwiftUI/AppKit/MVVM 架构的修改, 并保护本地认证、隐私、菜单栏体验、Sparkle 更新和发布流程。

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
- 当前 build settings: `MACOSX_DEPLOYMENT_TARGET = 15.0`, `MARKETING_VERSION = 2.0.0`, `CURRENT_PROJECT_VERSION = 10`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。
- App Sandbox 必须保持关闭(`ENABLE_APP_SANDBOX = NO`), 因为应用要启动本机 Codex CLI/APP 内置 CLI, 并读取真实 macOS 用户的 Codex 登录状态。
- 工程使用 `PBXFileSystemSynchronizedRootGroup`; 新增或删除 `CodexBar/` 下 Swift 文件通常无需改 `project.pbxproj`。只有依赖、target/build settings 或资源归属变更才改 Xcode 工程文件。
- Swift 源码按目录组织: `App/`、`Controllers/`、`Models/`、`Services/`、`Views/`。不要把新 Swift 文件直接放回 `CodexBar/` 根层。
- 不要为 macOS 15 以下添加 SF Symbols 或 SwiftUI API fallback。

## 架构地图

主要数据流:

```text
CodexStatusService(JSON-RPC app-server)
  -> CodexStatusViewModel(@MainActor 状态发布)
  -> StatusItemController(菜单栏图标、popover、窗口入口)
  -> CodexStatusMenuView / AppSettingsView / LogView
```

关键文件职责:

- `App/CodexBarApp.swift`: `@main` 入口、空 `Settings` scene、`Bundle.displayVersionLabel`。
- `Controllers/StatusItemController.swift`: `NSStatusItem`、`NSPopover` 状态切换、右键菜单、设置/日志窗口入口、自动刷新启动。
- `Controllers/PopoverDismissMonitor.swift`: popover 外部点击关闭监控, 并稳定 `NSVisualEffectView` inactive 外观。
- `Controllers/PopoverFadeCoordinator.swift`: popover 淡入淡出、alpha 重置和动画任务取消。
- `Controllers/HostingWindowController.swift`: 设置和日志窗口的懒创建、居中、置顶和跨桌面打开行为。
- `Controllers/SettingsWindowController.swift`: 独立设置窗口。
- `Controllers/LogWindowController.swift`: 独立日志窗口。
- `Services/CodexStatus/CodexStatusViewModel.swift`: `@MainActor ObservableObject`, 发布 `snapshot`、`isRefreshing`、`loadState`、`codexConnectionInfo`、`autoRefreshCountdownStartedAt`。
- `Services/CodexStatus/CodexStatusService.swift`: app-server 连接生命周期、连接复用、认证刷新、rate limits/usage 降级和连接信息。
- `Services/CodexStatus/AppServerSession.swift`: JSON-RPC 请求/通知、请求日志回填、业务错误重试、unsupported method 记录。
- `Services/CodexStatus/AppServerPipeReaders.swift`: stdout 按行读取和 stderr drain, 不把子进程 stderr 展示给用户。
- `Services/CodexStatus/RequestLog.swift`: 常驻交互日志存储, 记录请求、响应、错误和无响应请求。
- `Services/CodexCLI/CodexCLIResolver.swift`: 解析全局 `codex` 与 `/Applications/Codex.app/Contents/Resources/codex`, 并构造真实用户环境。
- `Services/CodexCLI/CodexCLIVersionService.swift`: 并发探测全局 CLI 与 Codex APP 内置 CLI 的磁盘版本, 合成当前运行版本和「已更新至」提示。
- `Services/Settings/LoginItemSettings.swift`: 开机自启状态读取和注册/注销。
- `Services/Updates/AppUpdater.swift`: Sparkle 封装, 更新状态按设置窗、popover 和可用更新拆分。
- `Models/CodexAccountModels.swift`: account/read 响应和账号展示名。
- `Models/CodexQuotaModels.swift`: rate limits DTO、quota 业务快照、limit/window 转换和排序。
- `Models/CodexUsageModels.swift`: usage DTO、token summary、daily bucket 和近 30 周日期网格。
- `Models/CodexStatusError.swift`: app-server、传输、认证和 unsupported method 错误分类。
- `Views/Menu/CodexStatusMenuView.swift`: popover 主 UI 装配。
- `Views/Menu/CodexStatusMenuSections.swift`: 账号卡片、状态卡片、额度区、空数据和更新时间行。
- `Views/Menu/AutoRefreshCountdownView.swift`: 更新时间倒计时圆环和 popover 可见时的 `TimelineView` tick。
- `Views/Menu/QuotaRow.swift`: 单个 quota window 行和分段额度条。
- `Views/Menu/UsageHeatmap.swift` / `Views/Menu/TokenCountText.swift`: token 汇总、近 30 周热力图、hover tooltip 和 K/M/B 紧凑数字格式。
- `Views/Settings/AppSettingsView.swift`: 设置窗口主布局、开机自启、CodexBar 版本和更新操作入口。
- `Views/Settings/CodexVersionSection.swift`: Codex CLI/Codex APP 版本、当前使用标记、路径复制和「已更新至」提示。
- `Views/Settings/SettingsToggleRow.swift`: 设置页通用开关行。
- `Views/Log/LogView.swift`: 日志窗口 UI, 状态标签为「进行」「完成」「错误」「请求」。
- `Views/Shared/LiquidGlassStyle.swift`: 自绘 Liquid Glass 视觉入口。

## app-server 合约

启动命令统一是:

```bash
codex app-server --listen stdio://
```

必须通过 `CodexCLIResolver.resolveAppServerCommand()` 解析:

- 优先 PATH 中的全局 `codex`。
- 如果 PATH 中的 `codex` 等价于 `/Applications/Codex.app/Contents/Resources/codex`, 当作内置 Codex APP CLI, 不当作全局 CLI。
- 全局 CLI 不存在时回退 Codex APP 内置 CLI。
- 两者都不存在时返回 `CodexStatusError.executableNotFound`, UI 归为「初始化失败」, 日志记录具体错误。

启动环境由 `CodexCLIResolver.environment` 构造:

- 保留当前环境。
- `HOME` 必须来自 `getpwuid(getuid())` 的真实用户 home。
- 同步设置 `USER`、`LOGNAME`。
- 合并 Homebrew、npm global、`.local`、Volta 和系统路径。
- 确保 `TERM` 有值。
- 不要改回 Xcode sandbox/container 的 `HOME`, 否则会读不到真实 `~/.codex/auth.json`。

首次连接流程:

```json
{"method":"initialize","id":1,"params":{"clientInfo":{"name":"codex_bar","title":"Codex Bar","version":"<Bundle MARKETING_VERSION 或 1.0.0>"}}}
{"method":"initialized"}
{"method":"account/read","id":2,"params":{"refreshToken":false}}
```

`initialized` 是无 id 请求, 不等待响应; 日志中记录为空响应请求, 不归为通知类型。

同一会话后续读取:

- `account/read` 每轮复用连接时用 `refreshToken: false` 更新账户状态。
- `account/rateLimits/read` 读取额度。
- `account/usage/read` 读取 `summary.lifetimeTokens`、`summary.peakDailyTokens`、`dailyUsageBuckets`。
- 认证失败时同会话最多调用一次 `account/read`(`refreshToken: true`) 后重试原读取。
- 所有走 `AppServerSession.request` 的方法, 收到方法不支持错误后都记录到当前会话的 `unsupportedMethods`, 本连接后续不再请求该方法。
- 方法不支持必须是 JSON-RPC error, 且 message 包含 `Invalid request: unknown variant`。
- 请求有 JSON-RPC error 响应, 且不是认证失败、不是方法不支持、不是传输/解析故障时, 先立即重试同一个请求一次。
- 非认证业务错误重试后仍失败时不阻断整轮刷新, 详情只进日志。
- `account/rateLimits/read` 和 `account/usage/read` 重试后仍失败时, 若同账号有上次成功数据则复用旧数据并标记为 stale; 没有旧数据则不展示对应区域。
- 方法不支持不复用旧数据; 对应读取结果视为空。
- 传输/解析故障归为需要重建连接。

连接细节:

- `requestTimeout` 是 20 秒。
- `connectionMaxAge` 是 1 小时。
- `SIGPIPE` 已被忽略, 写入断管后应由 `write` 抛错并走重建。
- 复用连接出现传输故障时只重建重试一次。
- 全新连接初始化失败直接返回「初始化失败」, 不重复完整握手。
- `initialize` 响应 `userAgent` 首个 token 形如 `codex_bar/0.139.0 (...)`; 取 `/` 后版本号作为当前运行版本。

## UI 状态与日志

`CodexLoadState` 只有四种:

- `loading`
- `loaded`
- `notLoggedIn`
- `initializationFailed`

UI 只展示「未登录」和「初始化失败」两类特殊状态; 具体请求错误、启动错误、超时、断连、解析失败都进入日志。

日志状态标签:

- `.pending` ->「进行」
- `.response` ->「完成」
- `.failure` ->「错误」
- `.emptyResponse` ->「请求」

日志规则:

- 带 id 的 JSON-RPC 请求先记录为进行, 响应或错误到达后回填到同一条。
- `initialized` 这类无 id 请求记录为空响应。
- 日志容量上限 500 条, 单条详情上限 4000 字符。
- 合法 JSON 通过 `JSONSerialization` 重新序列化, 使用 `.sortedKeys` 和 `.withoutEscapingSlashes`; 非 JSON 错误消息保持原样。
- 不要把子进程 stderr 直接展示给用户。

## 数据模型

`CodexQuotaSnapshot`:

- 必须有 `AccountReadResponse.account`, 否则视为未登录。
- `rateLimitsResponse` 和 `usageResponse` 都可以为空; 账户有效时仍生成快照, UI 展示「暂无数据」。
- `isRateLimitsStale` / `isUsageStale` 标记额度或 token 区域是否来自同账号旧缓存; 本轮对应接口成功后重新生成 snapshot 并恢复为 `false`。
- 优先读取 `rateLimitsByLimitId`; 为空时回退顶层 `rateLimits`。
- 顶层 `rateLimits.limitId` 指向的主 limit 置顶, 缺省 `"codex"`。
- 其余 limit 按 `limitName ?? limitId` 做 localized standard 排序, 再按 `limitId` 稳定排序。
- `primary` / `secondary` 合成 `[QuotaWindow]`; 没有窗口的 limit 被过滤。
- `QuotaWindow.remainingPercent = clamp(100 - usedPercent, 0...100)`; 无 `usedPercent` 视为无数据。
- `windowDurationMins` 标签: 整天「N 天」, 整小时「N 小时」, 否则「N 分钟」, 缺失或非正数为「额度」。

`CodexUsageSnapshot`:

- `recentWeekGrid(columnCount:endingDaysAgo:today:)` 基于本地当天零点生成按周排列的日期网格, 每列从周日开始。
- UI 使用 30 列、7 行, 默认 `endingDaysAgo = 1`, 不包含今天。
- `nil` 表示未来日期或不可生成日期; 热力图不绘制方块也不参与峰值计算。

## 并发与隔离

工程开启 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; 未显式标注的类型会推断为 MainActor 隔离。

- UI 层保持 `@MainActor`: app delegate、status item controller、window controllers、view models、settings/updater。
- 服务层对外暴露 async API, 内部用串行 queue 管理 `Process`、`Pipe` 和连接状态。
- 非 UI 类型、DTO、模型、服务辅助类型和静态工具需要显式 `nonisolated`, 避免 main actor 隔离泄漏到同步服务代码。
- `CodexStatusService` 使用 `CodexBar.app-server` 队列。
- `CodexCLIVersionService` 使用 `CodexBar.codex-version` 队列, 全局和内置版本探测先并发启动再收集。
- `RequestLogStore` 可从后台队列写入, storage 用锁保护, SwiftUI 通知切回主线程发送。

## UI 约束

菜单栏:

- 正常图标是 `person.fill.checkmark`, 错误图标是 `person.fill.xmark`。
- 菜单栏不展示额度数字; 详情只在 popover 中展示。
- 左键切换 popover; 右键或 Control 点击显示「设置 / 日志 / 退出」。

Popover:

- `CodexStatusMenuView.menuWidth` 由热力图宽度和 padding 推导; 改热力图尺寸时同步检查弹窗宽度。
- 外层和分区使用 `.liquidGlassSurface(...)`; 分隔线使用 `LiquidGlassDivider`; 小徽章可用 `.liquidGlassCapsule(...)`。
- `LiquidGlassStyle.swift` 是自绘玻璃效果, 不是 macOS 原生 `.glassEffect`; 没有明确设计要求时不要切换。
- 账号图标双击触发刷新。邮箱文本双击切换模糊。
- 计划名是右侧加粗纯文字; `planBadgeTint(for:)` 优先级: enterprise -> team/business -> pro -> plus -> edu -> free -> 默认 cyan。
- 额度条展示剩余百分比, 颜色按 20% 一档: 红、橙、黄、薄荷、绿。
- 无 quota 数据时显示 `--` / `暂无数据`, 并使用占位色。
- `rateLimits` 或 `usage` 使用旧缓存时, 对应区域通过 `.markStale(true)` 降低透明度到 0.55, 不降低饱和度; 下一轮对应接口成功后恢复正常透明度。
- 重置时间格式是 `MM-dd HH:mm`。
- 更新时间行显示倒计时圆环、「数据更新时间」和 `HH:mm:ss`。
- 倒计时只在 popover 可见时用 `TimelineView` 每秒 tick; 普通 tick 不做连续动画, 仅刷新起点变化时播放恢复动画。
- token 区域显示「单日峰值」和「全时累计」; `TokenCountText` 对 1K 以下显示完整整数, 1K 起显示 K/M/B。
- 热力图是近 30 周、30 列 x 7 行、周日到周六排列、默认不包含今天。

设置窗口:

- 通过右键菜单「设置」打开独立 `AppSettingsView` 窗口。
- 不要恢复为 Option 点击或 popover 内设置区。
- 设置页包含「CodexBar 版本」和「Codex 版本」区域。
- `Codex CLI` 行图标用 `terminal`; `Codex APP` 行图标用 `app.badge`。
- 当前运行来源显示「当前使用」。
- 当前行优先展示 app-server 握手自报版本; 非当前行展示磁盘安装版本。
- 当前运行版本与磁盘安装版本不同时, 显示「已更新至 <version>」。
- 路径点击复制到剪贴板, 对应来源显示「已复制」1.5 秒; 保留路径文本布局宽度避免跳动。

日志窗口:

- 通过右键菜单「日志」打开。
- 日志窗口应持续显示全局 `RequestLogStore.shared` 中的记录, 不因窗口关闭丢失。
- 详情文本必须可选择, 长内容由存储层截断。

## Sparkle 更新

- `AppUpdater` 是 `@MainActor ObservableObject`。
- 初始化时先校验 `SUFeedURL`(http/https) 和 `SUPublicEDKey`(非空)。
- 任一缺失时不创建 `SPUStandardUpdaterController`, 更新操作显示「未配置更新资源」。
- `canConfigureAutomaticChecks` 是 `updaterController != nil`。
- `settingsStatusMessage` 用于设置窗版本行, 默认 3 秒后清空。
- `panelUpdateMessage` 用于 popover 底栏被动提示, 双击触发 `startUpdate()`。
- `availableUpdateMessage` 驱动设置窗版本行和「立即更新」按钮。
- 手动检查结果进 `settingsStatusMessage`; 自动发现新版进 `panelUpdateMessage`。
- 当前 `SUFeedURL = https://codexbar.zabrian.app/appcast.xml`, `SUScheduledCheckInterval = 3600`。

## 认证、隐私与沙盒

- CodexBar 只与本机 Codex app-server 通信; 账号、额度和 token 使用量不发往第三方服务。
- 除 Sparkle appcast/DMG 下载外, 应用自身不做网络请求。
- App Sandbox 必须保持关闭。
- app-server 和版本探测必须使用真实用户 home。
- 不要把 Codex auth 文件、stderr、原始敏感 RPC 响应或用户路径之外的敏感信息写入 UI、文档或测试夹具。

## 发布脚本

- `Scripts/dmg.sh [App.app] [Output.dmg]` 创建带 `/Applications` 链接的 DMG, 会尝试写 Finder 布局。
- `Scripts/appcast.sh [CodexBar-vX.Y.Z.dmg]` 更新 `appcast.xml`, 需要 Sparkle `sign_update`。
- 改发布脚本后至少运行 `bash -n Scripts/dmg.sh` 和 `bash -n Scripts/appcast.sh`。
- 更新 appcast、tag、push、上传 DMG 都必须先得到用户明确同意。

## Git 规则

- 不要主动 push。
- 不要回滚或覆盖你没做的未提交改动。
- 提交代码的时候不要做任何额外的改动，仅对目前代码进行提交即可。
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

- tag 名格式 `v{MARKETING_VERSION}`, 例如 `v2.0.0`。
- 使用附注 tag: `git tag -a v2.0.0 -m "Release v2.0.0"`。

## 最终检查

返回最终答复或执行不可逆动作前, 快速确认:

- 是否满足用户的所有明确要求。
- 是否基于当前代码和工具输出, 没有使用过期文件名或旧架构名。
- 是否运行了与改动匹配的验证命令。
- 是否说明了未验证项和原因。
- 是否避免泄露本机认证、路径之外的敏感信息或原始错误噪音。

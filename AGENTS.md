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

Codex Hook
  -> WorkflowHookEventRecorder(--hook-event)
  -> WorkflowStatsStorage(events.jsonl / daily.jsonl)
  -> WorkflowStatsService
  -> WorkflowStatsViewModel
  -> UsageSummaryView / UsageHeatmap
```

目录职责:

- `App/`: 入口和全局启动分支。
- `Controllers/`: 菜单栏、popover、设置窗口和日志窗口控制。
- `Models/`: account、quota、usage、workflow stats、共享日期网格和错误模型。
- `Services/`: app-server、Codex CLI、设置、Hook 统计、更新和日志服务。
- `Views/`: popover、设置、日志和共享 Liquid Glass 样式。

Hook 统计的配置、存储、保留策略和统计口径见 [Docs/CodexHook.md](Docs/CodexHook.md)。

## app-server 合约

- 详细合约见 [Docs/AppServer.md](Docs/AppServer.md)。
- 必须通过 `CodexCLIResolver.resolveAppServerCommand()` 解析, 不要绕过 resolver 直接启动。
- app-server 环境必须使用真实用户 `HOME`、`USER`、`LOGNAME`; 不要改回 Xcode sandbox/container 的 `HOME`。
- 保留认证失败 refresh token、unsupported method、业务错误重试、stale cache 和连接重建语义。
- 不要把子进程 stderr、认证文件或原始敏感 RPC 响应展示给用户。

## Codex Hook 合约

- 详细设计见 [Docs/CodexHook.md](Docs/CodexHook.md)。
- 设置开关只能追加或移除 CodexBar 自己的 Hook 处理器, 不能破坏用户已有 Hook。
- Hook 命令只支持 `--hook-event`。
- Hook 数据只保存在 `~/Library/Application Support/CodexBar/HookEvents/`。
- Hook 写入可能并发触发, 更新 `events.jsonl`、`daily.jsonl` 和 `maintenance.json` 时必须通过 `stats.lock` 加锁。

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
- 其余 limit 按 `limitName ?? limitId` 做 localized standard 排序, 再按 `limitId` 稳定排序。
- `primary` / `secondary` 合成 `[QuotaWindow]`; 没有窗口的 limit 被过滤。
- `QuotaWindow.remainingPercent = clamp(100 - usedPercent, 0...100)`; 无 `usedPercent` 视为无数据。
- `windowDurationMins` 标签: 整天「N 天」, 整小时「N 小时」, 否则「N 分钟」, 缺失或非正数为「额度」。

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
- 服务层对外暴露 async API, 内部用串行 queue 管理 `Process`、`Pipe` 和连接状态。
- 非 UI 类型、DTO、模型、服务辅助类型和静态工具需要显式 `nonisolated`, 避免 main actor 隔离泄漏到同步服务代码。
- `CodexStatusService` 使用 `CodexBar.app-server` 队列。
- `CodexCLIVersionService` 使用 `CodexBar.codex-version` 队列, 全局和内置版本探测先并发启动再收集。
- `RequestLogStore` 可从后台队列写入, storage 用锁保护, SwiftUI 通知切回主线程发送。
- `WorkflowStatsService` 使用 `CodexBar.workflow-stats` 队列读取快照。
- Hook 写入可能由多个 Codex 进程并发触发, 必须通过 `stats.lock` 和 `flock` 保护 `events.jsonl`、`daily.jsonl`、`maintenance.json` 的一致性。

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
- token 区域还显示「当前连胜」、「最长连胜」和「最长任务」。
- 热力图是近 30 周、30 列 x 7 行、周日到周六排列; Codex Hook 开启时包含今天, Hook 关闭时仅在 app-server 已返回当天 token bucket 时包含今天。
- Hook 关闭时热力图 tooltip 只显示日期和 token 数; 宽度使用 `tokenTooltipWidth`。
- Hook 开启时热力图 tooltip 首行左侧显示日期、右侧显示 token 数, 当天 token 数显示 `--`; 后续逐行显示「会话总数」、「对话轮次」、「子智能体」、「工具调用」、「权限请求」、「上下文压缩」。
- 工作流统计只展示在用量热力图 tooltip 中, 不再有单独的工作流统计区。

设置窗口:

- 通过右键菜单「设置」打开独立 `AppSettingsView` 窗口。
- 不要恢复为 Option 点击或 popover 内设置区。
- 设置页包含「CodexBar 版本」和「Codex 版本」区域。
- `Codex CLI` 行图标用 `terminal`; `Codex APP` 行图标用 `app.badge`。
- 当前运行来源显示「当前使用」。
- 当前行优先展示 app-server 握手自报版本; 非当前行展示磁盘安装版本。
- 当前运行版本与磁盘安装版本不同时, 显示「已更新至 <version>」。
- 路径点击复制到剪贴板, 对应来源显示「已复制」1.5 秒; 保留路径文本布局宽度避免跳动。
- 设置页包含「启用 Codex Hook」开关; 开启后会写入全局 Codex Hook 配置, 用于热力图展示更多本机统计数据。
- Codex Hook 开关下方说明文案为小号辅助文字; 不展示启用/关闭状态文案, 只在失败时展示错误消息。

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
- Codex Hook 工作流统计只写入本机 `~/Library/Application Support/CodexBar/HookEvents/`, 不发往第三方服务。
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

- tag 名格式 `v{MARKETING_VERSION}`, 例如 `v2.0.0`。
- 使用附注 tag: `git tag -a v2.0.0 -m "Release v2.0.0"`。

## 最终检查

返回最终答复或执行不可逆动作前, 快速确认:

- 是否满足用户的所有明确要求。
- 是否基于当前代码和工具输出, 没有使用过期文件名或旧架构名。
- 是否运行了与改动匹配的验证命令。
- 是否说明了未验证项和原因。
- 是否避免泄露本机认证、路径之外的敏感信息或原始错误噪音。

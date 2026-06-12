# AGENTS.md

此文件为 Codex 等代码代理在本仓库工作时提供上下文和约定。请优先遵循这里的项目事实、构建命令和实现边界。

## 项目概览

CodexBar 是一个 macOS 菜单栏应用(SwiftUI + MVVM,最低 macOS 15.0),通过本机 Codex app-server 展示当前 Codex 账号的额度和 token 用量。主入口是 `MenuBarExtra`,弹窗使用 `.menuBarExtraStyle(.window)`。唯一外部依赖是 Sparkle(SwiftPM)。

## 构建验证

修改后运行以下命令,确保无 error 和 warning:

```bash
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build
```

SourceKit 经常对跨文件类型误报「Cannot find type ... in scope」(索引滞后),以 `xcodebuild` 实际编译结果为准。

工程使用文件系统同步组(`PBXFileSystemSynchronizedRootGroup`):新增/删除源文件无需修改 `project.pbxproj`,只有依赖变更才需要改它。

## 架构

数据流:`CodexRateLimitService`(JSON-RPC 常驻连接)→ `RateLimitsViewModel`(状态发布)→ `MenuBarStatusView`(菜单栏图标 + 在 `.task` 中驱动每分钟自动刷新)/ `RateLimitsMenuView`(弹窗)。

- `CodexBarApp.swift`:入口,创建 `RateLimitsViewModel` 和 `@StateObject AppUpdater`,后者以 `environmentObject` 注入弹窗。
- `CodexRateLimitService.swift`:app-server 常驻连接管理 + JSON-RPC 请求/响应。
- `RateLimitModels.swift`:wire 响应模型(纯 Decodable,不含展示逻辑)、业务快照模型(`CodexQuotaSnapshot` → `limits: [CodexQuotaLimitSnapshot]` → `windows: [QuotaWindow]`,支持多 limit 多窗口)、`CodexRateLimitError`(含 `requiresLogin`、`isAuthenticationRequired` 分类属性)。
- `RateLimitsViewModel.swift`:错误状态单一来源——只发布 `lastError: CodexRateLimitError?`,`errorMessage`、`requiresLogin`、`hasError` 都是派生计算属性,**不要再加并列的错误布尔**。
- `QuotaRow.swift`:额度行和分段进度条;`LoginItemSettings.swift`:`SMAppService.mainApp` 开机自启;`AppUpdater.swift`:Sparkle 封装。

## Codex app-server 连接(核心逻辑)

启动优先级:全局 `codex` CLI 优先,找不到则回退 `/Applications/Codex.app/Contents/Resources/codex`;两者都没有时弹窗展示「找不到 Codex CLI 或 Codex App」。启动命令:`codex app-server --listen stdio://`。

应用维持**一条常驻连接**,首次握手顺序(必须在请求额度前完成,否则 app-server 拒绝请求):

```json
{"method":"initialize","id":1,"params":{"clientInfo":{"name":"codex_bar","title":"Codex Bar","version":"1.0.0"}}}
{"method":"initialized"}
{"method":"account/read","id":2,"params":{"refreshToken":false}}
```

之后每分钟在同一会话上请求 `account/rateLimits/read` 和 `account/usage/read`。

额度解析(`CodexQuotaSnapshot` 的转换 init,wire DTO 本身不做排序/兜底):优先读 `rateLimitsByLimitId`(多 limit),为空则回退顶层 `rateLimits`;顶层 `rateLimits.limitId` 指向的主 limit 置顶(缺省 `"codex"`),其余按名称排序;每个 limit 的 `primary`/`secondary` 窗口合成 `[QuotaWindow]`,无窗口的 limit 被过滤,全部为空才抛 `missingRateLimitWindow`。

连接重建规则(`CodexRateLimitService.ensureConnection`):

- 进程已退出 → 重建。
- 连接存活超过 `connectionMaxAge`(1 小时)→ 定期回收重建(覆盖 codex 全局升级、服务端状态漂移)。
- **复用的**连接上请求失败 → 丢弃重建一次再试;**全新**连接上的失败直接抛出,不做二次重试。
- 登录类错误(`requiresLogin`)→ 丢弃连接但不重试;下次轮询起新进程读取最新 `~/.codex/auth.json`,用户重新登录后最多一分钟自动恢复。

认证重试:`account/rateLimits/read` 返回认证错误时,先在同一会话上调 `account/read`(`refreshToken: true`)再重试一次;仍失败抛 `authenticationRequired`。

token 统计来自 `account/usage/read`(`summary.lifetimeTokens`、`summary.peakDailyTokens`、`dailyUsageBuckets`);本机 app-server 不支持该方法时,token 区域不展示,额度信息仍正常显示。

## 并发约定

工程开启了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`:未显式标注的类型一律推断为 MainActor 隔离。因此**所有非 UI 类型必须显式标 `nonisolated`**,否则会报「Call to main actor-isolated initializer in a synchronous nonisolated context」。

`CodexRateLimitService` 是 `nonisolated final class` + `@unchecked Sendable`,连接状态只在私有串行 `DispatchQueue` 上读写,对外暴露 async 接口。

## 认证和沙盒

Xcode target 已关闭 App Sandbox(需要启动本机 Codex CLI 并读取用户登录状态)。服务层用真实用户 home(`getpwuid`)运行 app-server——Xcode 运行时 `HOME` 可能指向 app container,导致读不到 `~/.codex` 而报 "codex account authentication required"。

## UI 与错误展示约定

- 菜单栏正常图标 `person.fill.checkmark`,错误图标 `person.fill.xmark`,切换用 `.contentTransition(.symbolEffect(.replace))`。菜单栏不展示额度数字,详情只在弹窗中展示。
- App 图标保持白底黑色 `timelapse`。
- 不要给 symbol API 加低版本 fallback,最低系统版本已是 macOS 15.0。
- 弹窗按 limit 分节展示(节标题取 `limitName` 回退 `limitId`,首字母大写,节之间 `Divider`)。分段条展示**剩余**额度(`100 - usedPercent`);额度行标签由 `windowDurationMins` 动态生成(如 `300` → `5 小时`,`10080` → `7 天`)。重置时间格式 `MM-dd HH:mm`,更新时间格式 `HH:mm:ss`。
- token 贡献墙为 30 列 × 7 行蓝色方块热力图,token 数按 `M`/`B` 紧凑单位展示。
- 设置区仅在按住 Option 点击菜单栏图标时展示;开机自启状态读取是同步 XPC,也只在设置区可见时刷新。
- **错误文案不暴露内部细节**:`serverTimeout` 只携带 JSON-RPC 步骤名;子进程 stderr 由 `PipeDrain` 排空丢弃,不进入任何用户可见文案。
- 登录类错误(`requiresLogin`):弹窗顶部橙色提示「Codex 未登录」,旧快照置灰(opacity 0.4)保留,红色错误行被抑制。其他错误:红色小字展示 `errorDescription`,旧快照保持全亮度。
- 错误文案保持显示直到某次刷新成功(`refresh()` 开始时不清空 `lastError`);旧额度快照永远不清空。

## 自动更新(Sparkle)

`AppUpdater`(`@MainActor`、`ObservableObject`)初始化时先校验 Info.plist 的 `SUFeedURL`(http/https)和 `SUPublicEDKey`(非空),任一缺失则不创建 `SPUStandardUpdaterController`,双击版本文案显示「未配置更新资源」(Debug/未签名构建静默降级)。`statusMessage` 是唯一发布的 UI 状态,3 秒后由可取消的 `Task` 自动清空。Info.plist 位于 `CodexBar/Resources/Info.plist`(`SUFeedURL = https://codexbar.zabrian.app/appcast.xml`,检查间隔 3600 秒)。

## Git 提交规范

- 提交 message 使用 **Conventional Commits 前缀 + 中文描述**,格式:`<type>: <中文描述>`。
- 常用 type:`feat`(新功能)、`fix`(修复)、`chore`(杂项/发布)、`refactor`(重构)、`docs`(文档)。
- 描述简洁一行,不加句号。
- **提交后不要主动 push,必须等用户明确同意后才能推送。**

### Tag 规范

- tag 名格式:`v{MARKETING_VERSION}`(如 `v1.2.1`),与 Xcode target 的 `MARKETING_VERSION` 保持一致。
- 使用**附注 tag**(`git tag -a`),message 格式:`Release v{version}`(如 `git tag -a v1.2.1 -m "Release v1.2.1"`)。
- tag 同样不要主动 push,等用户明确同意。

## 发布流程

1. 用 `Developer ID Application` 证书签名并 notarization,Xcode 导出 `CodexBar.app` 到项目根目录。
2. `Scripts/create-dmg.sh`:自动找到根目录唯一 `.app`,按 `MARKETING_VERSION` 生成 `CodexBar-v{version}.dmg`(含 Applications 快捷方式和 Finder 布局)。
3. `Scripts/update-appcast.sh [dmg]`:用 Sparkle `sign_update` 签名 DMG,从 build settings 读版本号,将 `<item>` 写入 `Updates/appcast.xml`(同版本去重,`xmllint` 校验)。常用环境变量:`DOWNLOAD_BASE_URL`、`INCLUDE_RELEASE_NOTES`、`MINIMUM_SYSTEM_VERSION` 等。
4. 上传 DMG 和更新后的 `appcast.xml` 到 `SUFeedURL` 对应站点。

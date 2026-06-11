# CodexBar 项目记忆

## 项目概览

CodexBar 是一个 macOS 菜单栏应用，用来展示当前本机 Codex 账号的额度信息。应用使用 SwiftUI + MVVM，主入口是 `MenuBarExtra`，弹窗使用 `.menuBarExtraStyle(.window)`。

当前最低系统版本是 macOS 15.0。

## 核心功能

- 菜单栏图标：正常时显示 `person.fill.checkmark`，任何错误（包括未登录）时显示 `person.fill.xmark`，切换使用 `.contentTransition(.symbolEffect(.replace))` 动画。App 图标使用白底黑色 `timelapse`。
- 弹窗第一行展示账号信息和套餐。
- 弹窗展示两行分段电量条，额度行标签根据 `windowDurationMins` 动态生成。
- 每行额度在进度条右侧展示剩余百分比和重置时间。
- 弹窗展示最近 14 个完整自然日的 token 柱状图、累计 token 和单日峰值 token。
- 鼠标划过 token 柱状图中的单日柱子时，展示对应日期和用量。
- 应用运行时每分钟自动刷新，即使弹窗未打开也会刷新。
- 双击账号图标可手动刷新。
- 按住 Option/Alt 点击菜单栏图标时，才展示设置区。设置区为单行布局：左侧「开机自动启动」开关，右侧「退出」按钮，不展示刷新按钮。
- 没有通知功能：不监听 `account/rateLimits/updated`，不发送 macOS 本地通知（该功能已整体移除，不要恢复）。
- 弹窗错误只展示普通错误文案，不包含 Debug 明细或环境变量模拟入口。

## Codex 数据来源与常驻连接

应用通过本机 Codex app-server 读取数据。启动优先级：

1. 如果全局 Codex CLI 可用，优先使用：

```bash
codex app-server --listen stdio://
```

2. 如果找不到全局 CLI，则回退到 Codex.app 内置二进制：

```bash
/Applications/Codex.app/Contents/Resources/codex app-server --listen stdio://
```

应用与 app-server 维持**一条常驻连接**：首次拉取时启动进程，按顺序完成握手：

```json
{"method":"initialize","id":1,"params":{"clientInfo":{"name":"codex_bar","title":"Codex Bar","version":"1.0.0"}}}
{"method":"initialized"}
{"method":"account/read","id":2,"params":{"refreshToken":false}}
```

之后每分钟在同一会话上请求 `account/rateLimits/read` 和 `account/usage/read`。注意：不能在 `initialize` 和 `initialized` 完成前请求额度，否则 app-server 会拒绝请求。

连接重建规则（`CodexRateLimitService.ensureConnection`）：

- 进程已退出 → 重建。
- 连接存活超过 `connectionMaxAge`（1 小时）→ 定期回收重建，覆盖 codex 全局升级后切换新二进制、服务端状态漂移等陈旧问题。
- **复用的**连接上请求失败 → 丢弃重建一次再试；**全新**连接上的失败直接抛出，不做二次重试（避免故障时整套握手做两遍）。
- 登录类错误（`requiresLogin`）→ 丢弃连接但不重试；下一次轮询起新进程读取最新 `~/.codex/auth.json`，用户重新登录后最多一分钟自动恢复。

认证重试：`account/rateLimits/read` 返回认证错误时，先在同一会话上调 `account/read`（`refreshToken: true`）刷新 token 再重试一次；仍失败抛 `authenticationRequired`。

每日 token 统计使用 `account/usage/read`，读取 `summary.lifetimeTokens`、`summary.peakDailyTokens` 和 `dailyUsageBuckets`。如果本机 app-server 不支持该方法，token 统计区域不展示，额度信息仍正常显示。

## 并发约定

工程开启了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`：没有显式标注的类型一律推断为 MainActor 隔离。因此**所有非 UI 类型必须显式标 `nonisolated`**（`CodexRateLimitService`、`AppServerSession`、模型类型等都已标注），否则会出现「Call to main actor-isolated initializer in a synchronous nonisolated context」一类的错误。

`CodexRateLimitService` 是 `nonisolated final class` + `@unchecked Sendable`，连接状态只在私有串行 `DispatchQueue` 上读写，对外暴露 async 接口。

## 认证和沙盒

CodexBar 必须使用真实 macOS 用户的 Codex 登录数据。之前遇到过 Xcode 运行时 `HOME` 指向 app container，导致 app-server 读取不到 `/Users/{username}/.codex`，报错：

```text
codex account authentication required to read rate limits
```

当前服务层会用真实用户 home（`getpwuid`）运行 app-server，避免读到沙盒容器路径。

Xcode target 已关闭 App Sandbox，因为应用需要启动本机 Codex CLI 并访问用户的 Codex 登录状态。

如果既找不到全局 Codex CLI，也找不到 Codex.app 内置二进制，弹窗会展示 `找不到 Codex CLI 或 Codex App` 错误。

## 代码组织

- `CodexBarApp.swift`：应用入口，创建 `RateLimitsViewModel`，配置 `MenuBarExtra`。
- `RateLimitsViewModel.swift`：视图模型。错误状态单一来源：只发布 `lastError: CodexRateLimitError?`，`errorMessage`、`requiresLogin`、`hasError` 都是从它派生的计算属性，不要再加并列的错误布尔。
- `CodexRateLimitService.swift`：常驻 app-server 连接管理 + JSON-RPC 请求/响应。
- `RateLimitModels.swift`：Codex 响应模型、业务快照模型、`CodexRateLimitError`（含 `requiresLogin`、`isAuthenticationRequired` 分类属性）。
- `MenuBarStatusView.swift`：菜单栏常驻图标（checkmark/xmark 切换 + 动画），并在 `.task` 中启动自动刷新。
- `RateLimitsMenuView.swift`：点击菜单栏后的弹窗内容，含未登录橙色提示和设置区。
- `QuotaRow.swift`：额度行和分段进度条。
- `LoginItemSettings.swift`：使用 `SMAppService.mainApp` 管理开机自启。
- `Assets.xcassets/AppIcon.appiconset`：App 图标资源，白底黑色中心符号使用 `timelapse`。
- `Scripts/create-dmg.sh`：将项目根目录下导出的 `.app` 打包成拖拽安装 DMG。

工程使用文件系统同步组（`PBXFileSystemSynchronizedRootGroup`），新增/删除源文件无需修改 `project.pbxproj`。

## UI 约定

- 菜单栏正常图标 `person.fill.checkmark`，错误图标 `person.fill.xmark`，切换用 `.contentTransition(.symbolEffect(.replace))` + `.animation(.default, value:)`。
- 不要给 symbol API 加低版本 fallback；最低系统版本已经定为 macOS 15.0。
- App 图标保持白底黑色 `timelapse`，不要恢复成蓝绿色图标。
- 菜单栏不展示额度数字、窗口标签或外层圈数；额度详情只在弹窗中展示。
- 弹窗账号图标使用 `person.fill`，双击该图标刷新数据。
- 弹窗字体要保持紧凑，避免菜单栏弹窗内容被截断。
- 分段条展示剩余额度，剩余额度计算方式是 `100 - usedPercent`。
- 额度行标签示例：`300` 分钟显示 `5 小时`，`10080` 分钟显示 `7 天`；缺少 `windowDurationMins` 时再回退到默认文案。
- 重置时间格式使用 `MM-dd HH:mm`；更新时间格式使用 `HH:mm:ss`。
- token 数按 `M`、`B` 紧凑单位展示；token 柱状图使用橙色，单日用量越高颜色越浓。

## 错误展示约定

- 登录类错误（`requiresLogin` 为 true：`notLoggedIn`、`authenticationRequired`、消息含 "authentication required" 的 `serverError`）：弹窗顶部橙色提示「Codex 未登录」+ 图标 `person.crop.circle.badge.exclamationmark`；旧快照置灰（opacity 0.4）保留展示；红色错误行被抑制，避免重复文案。
- 其他错误：弹窗红色小字展示 `errorDescription`；旧快照保持全亮度。
- 错误文案保持显示直到某次刷新成功（`refresh()` 开始时不清空 `lastError`）。
- 旧额度快照永远不清空，弹窗继续显示上一次成功读取的数据和更新时间。
- 开机启动设置失败会展示 `设置开机启动失败: ...`，属于 `LoginItemSettings` 的独立错误位，与额度错误互不影响。

## 构建验证

修改后运行确保无 error 和 warning

```bash
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build
```

SourceKit 经常对跨文件类型报「Cannot find type ... in scope」，属索引滞后误报，以 `xcodebuild` 实际编译结果为准。

## 分发备注

项目用于直接分发时，应使用 `Developer ID Application` 证书签名，并进行 notarization。

Xcode 导出 `CodexBar.app` 到项目根目录后，可以运行：

```bash
Scripts/create-dmg.sh
```

脚本会自动查找当前目录下唯一的 `.app`，根据 Xcode target 的 `MARKETING_VERSION` 生成 `CodexBar-v{version}.dmg`。脚本会在 DMG 中放入 `CodexBar.app` 和 `Applications -> /Applications` 快捷方式，并写入 Finder 布局：app 在左侧，Applications 在右侧。若有多个工程或 scheme，可用 `XCODE_PROJECT`、`XCODE_SCHEME` 环境变量指定。

## Git 远端

当前远端仓库：

```text
git@github.com:bob-zebedy/CodexBar.git
```

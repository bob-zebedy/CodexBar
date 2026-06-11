# CodexBar 项目记忆

## 项目概览

CodexBar 是一个 macOS 菜单栏应用，用来展示当前本机 Codex 账号的额度信息。应用使用 SwiftUI + MVVM，主入口是 `MenuBarExtra`，弹窗使用 `.menuBarExtraStyle(.window)`。

当前最低系统版本是 macOS 15.0。

## 核心功能

- 菜单栏只展示 `timelapse` SF Symbol，App 图标使用白底黑色 `timelapse`。
- 弹窗第一行展示账号信息和套餐。
- 弹窗展示两行分段电量条，额度行标签根据 `windowDurationMins` 动态生成。
- 每行额度在进度条右侧展示剩余百分比和重置时间。
- 弹窗展示最近 14 个完整自然日的 token 柱状图、累计 token 和单日峰值 token。
- 鼠标划过 token 柱状图中的单日柱子时，展示对应日期和用量。
- 更新时间显示在左侧。
- 应用运行时每分钟自动刷新，即使弹窗未打开也会刷新。
- 收到 `account/rateLimits/updated` 后会重新查询额度，并在「额度通知」已开启时发送 macOS 本地通知。
- 双击账号图标可手动刷新。
- 按住 Option/Alt 点击菜单栏图标时，才展示控制区。
- Option/Alt 设置区左侧上下排列「开机启动」和「额度通知」开关，右下方展示「退出」按钮，不展示刷新按钮。
- 弹窗错误只展示普通红色错误文案，不包含 Debug 明细或环境变量模拟入口。

## Codex 数据来源

应用通过本机 Codex app-server 读取数据。启动优先级：

1. 如果全局 Codex CLI 可用，优先使用：

```bash
codex app-server --listen stdio://
```

2. 如果找不到全局 CLI，则回退到 Codex.app 内置二进制：

```bash
/Applications/Codex.app/Contents/Resources/codex app-server --listen stdio://
```

连接后必须按顺序发送：

```json
{"method":"initialize","id":1,"params":{"clientInfo":{"name":"codex_bar","title":"Codex Bar","version":"1.0.0"}}}
{"method":"initialized"}
{"method":"account/read","id":2,"params":{"refreshToken":false}}
{"method":"account/rateLimits/read","id":3}
{"method":"account/usage/read","id":4}
```

注意：不能在 `initialize` 和 `initialized` 完成前请求额度，否则 Codex app-server 会拒绝请求。

每日 token 统计使用 `account/usage/read`，读取 `summary.lifetimeTokens`、`summary.peakDailyTokens` 和 `dailyUsageBuckets`。
如果本机 Codex app-server 不支持 `account/usage/read`，token 统计区域不展示，额度信息仍正常显示。

`account/rateLimits/updated` 是 app-server notification，不是可请求方法。应用后台保留一个 app-server 连接监听该 notification；收到后重新调用 `account/rateLimits/read` 获取完整额度并更新 UI，在「额度通知」开启且系统通知权限已授权时发送本地通知。不要直接用 notification 中的稀疏 `rateLimits` payload 覆盖完整快照。

后台监听连接启动时也必须按 `account/read`、`account/rateLimits/read` 的顺序初始化额度路径；如果监听连接因为 app-server 退出、认证失败或响应超时而断开，应用会在 30 秒后重新启动监听连接。

## 认证和沙盒

CodexBar 必须使用真实 macOS 用户的 Codex 登录数据。之前遇到过 Xcode 运行时 `HOME` 指向 app container，导致 app-server 读取不到 `/Users/{username}/.codex`，报错：

```text
codex account authentication required to read rate limits
```

当前服务层会用真实用户 home 运行 app-server，避免读到沙盒容器路径。

Xcode target 已关闭 App Sandbox，因为应用需要启动本机 Codex CLI 并访问用户的 Codex 登录状态。

如果既找不到全局 Codex CLI，也找不到 Codex.app 内置二进制，弹窗会展示 `找不到 Codex CLI 或 Codex App` 错误。

## 代码组织

- `CodexBarApp.swift`：应用入口，创建 `RateLimitsViewModel`，配置 `MenuBarExtra`。
- `RateLimitsViewModel.swift`：视图模型，负责快照状态、刷新状态、自动刷新。
- `CodexRateLimitService.swift`：启动 Codex app-server，并处理 JSON-RPC 请求/响应。
- `RateLimitModels.swift`：Codex 响应模型、业务快照模型、错误文案。
- `MenuBarStatusView.swift`：菜单栏常驻展示，只包含 `timelapse` 动画图标。
- `RateLimitsMenuView.swift`：点击菜单栏后的弹窗内容。
- `QuotaRow.swift`：额度行和分段进度条。
- `LoginItemSettings.swift`：使用 `SMAppService.mainApp` 管理开机自启。
- `Assets.xcassets/AppIcon.appiconset`：App 图标资源，白底黑色中心符号使用 `timelapse`。
- `Scripts/create-dmg.sh`：将项目根目录下导出的 `.app` 打包成拖拽安装 DMG。

## UI 约定

- 菜单栏图标使用 `timelapse`。菜单栏图标直接使用：

```swift
.symbolEffect(.variableColor.cumulative.hideInactiveLayers.nonReversing, options: .repeat(.continuous))
```

- 不要再给 `symbolEffect` 加低版本 fallback；最低系统版本已经定为 macOS 15.0。
- App 图标保持白底黑色 `timelapse`，不要恢复成蓝绿色图标。
- 菜单栏不展示额度数字、窗口标签或外层圈数；额度详情只在弹窗中展示。
- 弹窗账号图标使用 `person.fill`，双击该图标刷新数据。
- 弹窗字体要保持紧凑，避免菜单栏弹窗内容被截断。
- 分段条展示剩余额度，剩余额度计算方式是 `100 - usedPercent`。
- 额度行标签示例：`300` 分钟显示 `5 小时`，`10080` 分钟显示 `7 天`；缺少 `windowDurationMins` 时再回退到默认文案。
- 重置时间格式使用 `MM-dd HH:mm`。
- 更新时间格式使用 `HH:mm:ss`。
- token 数按 `M`、`B` 紧凑单位展示。
- token 柱状图使用橙色，单日用量越高颜色越浓。

## 错误和调试

- 当前代码不包含 Debug UI、Debug 详情展示或环境变量模拟错误入口。
- Codex 交互错误会通过 `CodexRateLimitError.localizedDescription` 展示在弹窗中。
- 每分钟自动刷新失败时，如果已有旧额度快照，旧快照不会被清空；弹窗继续显示上一次成功读取的数据和对应更新时间，同时展示错误文案。
- `account/rateLimits/updated` 触发的刷新如果失败，不会更新 UI，也不会发送通知；只有当前没有旧快照时才会把错误展示到弹窗中。
- 开机启动设置失败会展示 `设置开机启动失败: ...`。

## 构建验证

修改后至少运行：

```bash
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build
```

当前已验证该命令可通过。

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

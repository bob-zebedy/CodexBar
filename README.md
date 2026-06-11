# CodexBar

CodexBar 是一个轻量级 macOS 菜单栏应用，用来查看当前本机 Codex 账号的额度使用情况。

它会启动本机 Codex 的 app-server，完成 JSON-RPC 初始化流程后读取账号信息和额度信息，并在菜单栏弹窗中展示不同时间窗口的额度。

## 功能

- 菜单栏使用 `timelapse` SF Symbol；App 图标是白底黑色 `timelapse`
- 弹窗第一行展示账号信息和套餐
- 弹窗使用两行分段电量条展示额度窗口，标签根据 `windowDurationMins` 动态生成
- 每行额度在进度条右侧展示剩余百分比和重置时间
- 弹窗展示最近 14 个完整自然日的 token 柱状图、累计 token 和单日峰值 token
- 鼠标划过 token 柱状图中的单日柱子时，展示对应日期和用量
- 更新时间显示在额度行下方，并使用 `HH:mm:ss` 格式
- 应用运行时每分钟自动刷新额度，即使弹窗未打开也会刷新
- 收到 `account/rateLimits/updated` 后会重新查询额度，并在「额度通知」已开启时发送本地通知
- 双击账号图标可手动刷新
- 不按 Option/Alt 点击菜单栏图标时，只展示额度内容
- 按住 Option/Alt 点击菜单栏图标时，才展示设置区；设置区包含「开机启动」「额度通知」开关和「退出」按钮

## 运行要求

- macOS 15.0 或更高版本
- 已安装全局 Codex CLI，或已安装 Codex.app
- 当前 macOS 用户已在 Codex 中完成登录

CodexBar 会优先使用全局 Codex CLI 启动本机 app-server：

```bash
codex app-server --listen stdio://
```

如果找不到全局 `codex` 命令，会回退到 Codex.app 内置的二进制：

```bash
/Applications/Codex.app/Contents/Resources/codex app-server --listen stdio://
```

如果两个入口都不可用，弹窗中会展示「找不到 Codex CLI 或 Codex App」的错误。

连接后会先发送初始化请求，再读取账号和额度：

```json
{"method":"initialize","id":1,"params":{"clientInfo":{"name":"codex_bar","title":"Codex Bar","version":"1.0.0"}}}
{"method":"initialized"}
{"method":"account/read","id":2,"params":{"refreshToken":false}}
{"method":"account/rateLimits/read","id":3}
{"method":"account/usage/read","id":4}
```

额度窗口来自 Codex app-server 返回的 `primary` 和 `secondary`：

- `usedPercent`：已用百分比
- `windowDurationMins`：额度窗口分钟数，用来生成 `5 小时`、`7 天`、`5h`、`7d` 等标签
- `resetsAt`：秒级 Unix 时间戳，弹窗中显示为 `MM-dd HH:mm`

剩余额度统一按 `100 - usedPercent` 计算。

应用会保留一个后台 app-server 连接监听 `account/rateLimits/updated` 通知。该通知是稀疏更新，收到后不会直接用通知 payload 更新 UI，而是重新调用 `account/rateLimits/read` 获取完整额度并更新 UI；如果「额度通知」开启且系统通知权限已授权，则发送 macOS 本地通知。

后台监听连接启动时也会按 `account/read`、`account/rateLimits/read` 的顺序初始化额度路径。如果监听连接因为 app-server 退出、认证失败或响应超时而断开，应用会在 30 秒后重新启动监听连接。

「额度通知」开关只在按住 Option/Alt 打开菜单栏弹窗时展示。开启该开关时会请求 macOS 通知权限；关闭后不再发送额度更新通知。

token 使用量来自 Codex app-server 返回的 `account/usage/read`：

- `summary.lifetimeTokens`：累计 token
- `summary.peakDailyTokens`：单日峰值 token
- `dailyUsageBuckets`：按天聚合的 token 使用量，日期字段为 `startDate`

如果本机 Codex app-server 不支持 `account/usage/read`，token 统计区域不会展示，额度信息仍会正常显示。

token 数使用 `M`、`B` 紧凑单位展示。
token 柱状图使用橙色，单日用量越高颜色越浓。

## 错误展示

CodexBar 会在弹窗中用红色小字展示错误，例如未安装 Codex、app-server 启动失败、响应超时、当前未登录、需要重新验证身份、响应中缺少额度窗口等。应用不包含调试模拟入口，也不会在窗口里展示 Debug 明细。

如果应用运行期间 Codex 退出登录或认证失效，每分钟自动刷新会继续尝试读取额度；刷新失败时会展示对应错误。如果之前已经成功读取过额度，旧的额度快照不会被清空，弹窗会继续显示上一次成功读取的数据和对应更新时间，同时显示错误文案。收到 `account/rateLimits/updated` 后触发的刷新如果失败，不会更新 UI，也不会发送通知；只有在当前没有任何旧快照时才会把该错误展示到弹窗中。

## 构建

可以直接用 Xcode 打开 `CodexBar.xcodeproj`，也可以使用命令行构建：

```bash
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build
```

## 分发

如果不通过 App Store 分发，可以在 Xcode 中 Archive，然后使用 `Developer ID Application` 证书导出应用。

分享给其他用户前，建议完成 notarization，这样 macOS Gatekeeper 可以正常校验应用来源。

导出 `CodexBar.app` 到项目根目录后，可以用脚本生成拖拽安装 DMG：

```bash
Scripts/create-dmg.sh
```

脚本会自动查找当前目录下唯一的 `.app`，生成项目根目录下的 `CodexBar-v{version}.dmg`，并在 DMG 中放入：

- `CodexBar.app`
- `Applications -> /Applications` 快捷方式

DMG 文件名中的版本号来自 Xcode target 的 `MARKETING_VERSION`，读取失败时才会回退到 app 的 `Info.plist`。如果项目中有多个 Xcode 工程或 scheme，可以通过环境变量指定：

```bash
XCODE_PROJECT=CodexBar.xcodeproj XCODE_SCHEME=CodexBar Scripts/create-dmg.sh
```

脚本会写入 Finder 布局：打开 DMG 后 `CodexBar.app` 在左侧，`Applications` 快捷方式在右侧。

也可以显式指定输入 app 和输出路径：

```bash
Scripts/create-dmg.sh CodexBar.app CodexBar-v1.0.0.dmg
```

如果把应用移动到 `/Applications` 后再使用开机自启，建议打开应用后重新开启一次「开机启动」，让 macOS 记录最终的应用路径。

## 隐私

CodexBar 只会和本机 Codex app-server 进程通信，不会把账号信息或额度数据发送给任何第三方服务。

# CodexBar

CodexBar 是一个轻量级 macOS 菜单栏应用，用来查看当前本机 Codex 账号的额度使用情况。

它会启动本机 Codex 的 app-server，完成 JSON-RPC 初始化流程后读取账号信息和额度信息，并在菜单栏弹窗中展示不同时间窗口的额度。

## 功能

- 菜单栏使用 `timelapse` SF Symbol；App 图标是白底黑色 `timelapse`
- 弹窗第一行展示账号信息和套餐
- 弹窗使用两行分段电量条展示额度窗口，标签根据 `windowDurationMins` 动态生成
- 每行额度在进度条右侧展示剩余百分比和重置时间
- 更新时间显示在额度行下方，并使用 `HH:mm:ss` 格式
- 应用运行时每分钟自动刷新额度，即使弹窗未打开也会刷新
- 双击账号图标可手动刷新
- 不按 Option/Alt 点击菜单栏图标时，只展示额度内容
- 按住 Option/Alt 点击菜单栏图标时，才展示「开机启动」开关和「退出」按钮

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
```

额度窗口来自 Codex app-server 返回的 `primary` 和 `secondary`：

- `usedPercent`：已用百分比
- `windowDurationMins`：额度窗口分钟数，用来生成 `5 小时`、`7 天`、`5h`、`7d` 等标签
- `resetsAt`：秒级 Unix 时间戳，弹窗中显示为 `MM-dd HH:mm`

剩余额度统一按 `100 - usedPercent` 计算。

## 错误展示

CodexBar 会在弹窗中用红色小字展示错误，例如未安装 Codex、app-server 启动失败、响应超时、当前未登录、需要重新验证身份、响应中缺少额度窗口等。应用不包含调试模拟入口，也不会在窗口里展示 Debug 明细。

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

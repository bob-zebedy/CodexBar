# CodexBar

> 在 macOS 菜单栏实时查看 Codex 账号额度、token 用量和工作流数据统计。

CodexBar 是一个轻量级 macOS 菜单栏应用。它直接连接本机 Codex 的 app-server，定期读取额度信息；也可以通过 Codex Hook 记录本机工作流数据，让你不用打开终端就能随时知道: 还剩多少额度、什么时候重置、最近用了多少 token，以及今天的会话、对话轮次、工具调用等情况。

<p align="center">
  <img src="Images/record.gif" width="532">
</p>

## 特性

- **额度一目了然**: 分段电量条展示各时间窗口 (如 5 小时、7 天) 的剩余额度，附剩余百分比和重置时间
- **用量热力图**: 展示近 30 周的每日 token 用量，鼠标悬停可查看单日明细
- **详细统计**: 开启 Codex Hook 后，热力图会展示会话总数、对话轮次、子智能体调用次数、工具调用次数、权限请求次数和上下文压缩次数
- **跨设备同步**: 开启 Codex Hook 后可选择把脱敏后的每日工作流聚合同步到当前 iCloud 账号
- **自动刷新**: 每分钟后台刷新一次，弹窗未打开也保持最新；双击账号图标可手动刷新
- **自动更新**: 内置 Sparkle 更新检查，新版本自动更新
- **本地优先**: 账号、额度和 token 用量只与本机 Codex app-server 通信；Hook 工作流统计默认只保存在本机，只有用户开启「跨设备同步」后才通过 CloudKit private database 同步脱敏每日聚合

## 安装

### 下载 DMG

从 [Releases](https://github.com/bob-zebedy/CodexBar/releases) 下载。

之后的新版本会通过内置的 Sparkle 自动更新推送。

### 运行要求

- macOS 15.0 或更高版本
- 已安装 [Codex CLI](https://github.com/openai/codex) (全局 `codex` 命令或 `Codex.app`)
- 已在 Codex 中完成登录

> 提示: 如果把应用移动到 `/Applications` 后才开启开机自启，建议重新开关一次「开机启动」让 macOS 记录最终路径。

## 启用 Codex Hook

CodexBar 可以在设置中开启「启用 Codex Hook」

开启后会在全局 `~/.codex/hooks.json` 中增加以下 Hook，用于接收 Codex 的会话、工具调用、权限请求、上下文压缩和子智能体事件。

开启前会通过本机 Codex app-server 检查全局 `config.toml` 是否禁用了 Hook；如果已禁用，CodexBar 不会写入配置，并会在 Hook 选项下方提示。写入后还会用 `hooks/list` 确认 CodexBar 自己的 Hook 命令、事件、来源、启用状态、信任状态以及 Codex 返回的警告或错误；未信任或已修改时只会把当前 CodexBar Hook 的 key/hash 写入 `hooks.state` 后再次验证。

- `SessionStart`: 记录一次 Codex 会话开始，用于统计会话总数
- `UserPromptSubmit`: 记录用户提交提示词事件，保留为原始活动事件
- `PreToolUse`: 记录工具调用开始
- `PostToolUse`: 记录工具调用结束，和 `PreToolUse` 一起用于统计工具调用次数
- `PermissionRequest`: 记录 Codex 发起权限请求的次数
- `PreCompact`: 记录上下文压缩开始
- `PostCompact`: 记录上下文压缩结束，和 `PreCompact` 一起用于统计上下文压缩次数
- `Stop`: 记录一次回复/任务结束，用于统计对话轮次
- `SubagentStart`: 记录子智能体开始
- `SubagentStop`: 记录子智能体结束，和 `SubagentStart` 一起用于统计子智能体次数

每个事件都会追加一个 `command` 类型的 Hook，命令形如:

```bash
'/Applications/CodexBar.app/Contents/MacOS/CodexBar' --hook-event
```

开启后，用量热力图会包含今天；鼠标悬停到任意一天时，弹窗会在 token 数之外展示当天的会话总数、对话轮次、子智能体、工具调用、权限请求和上下文压缩次数。关闭 Hook 时，弹窗只展示日期和 token 数；如果 app-server 尚未返回当天 token 数据，热力图不会额外占位展示今天。

CodexBar 只会追加或移除 command 中包含当前 CodexBar 可执行路径的 Hook，不会删除其他 Codex Hook。

统计数据默认只保存在本机 `~/Library/Application Support/CodexBar/HookEvents/`。开启「跨设备同步」后，CodexBar 会通过 CloudKit private database 把去掉 `sessionIds` / `turnIds` 的每日聚合副本同步到当前 iCloud 账号；iCloud 不可用时该开关不可操作，并在设置页显示「iCloud 不可用」。

## 从源码构建

项目使用 Swift 6、SwiftUI + AppKit + MVVM，依赖 Sparkle (SwiftPM)。

```bash
git clone git@github.com:bob-zebedy/CodexBar.git
cd CodexBar
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build
```

也可以直接用 Xcode 打开 `CodexBar.xcodeproj` 运行。

## 源码结构

Swift 源码按职责放在 `CodexBar/` 下的子目录中:

- `App/`: 应用入口
- `Controllers/`: 菜单栏、菜单面板和独立窗口控制器
- `Models/`: account、quota、usage、工作流统计、共享日期网格和错误分类模型
- `Services/`: actor 隔离的 app-server 会话、Codex CLI 解析、版本探测、Hook 设置、工作流统计、日志存储、开机自启和 Sparkle 更新
- `Views/`: 菜单面板、设置窗口、日志窗口和共享 Liquid Glass 样式

更详细的启动、刷新、Hook 统计、跨设备同步、设置、日志、更新和发布流程见 [开发文档](Docs/DevelopmentGuide.md) 与 [跨设备同步文档](Docs/CrossDeviceSync.md)。

## 隐私

CodexBar 只通过本机 Codex app-server 读取账号信息、额度数据和 token 用量，这些数据不会发送给第三方服务。Hook 工作流数据默认只保存在本机；用户显式开启「跨设备同步」后，CloudKit 仅保存脱敏后的每日聚合副本，不保存原始 Hook events、`sessionIds` 或 `turnIds`。

除用户开启「跨设备同步」后的 CloudKit 请求外，只有检查和下载 App 更新时会产生额外网络请求，请求范围仅包含 [appcast](https://codexbar.zabrian.app/appcast.xml) 和 appcast 中对应的 DMG 下载地址。

## 许可证

本项目采用 [GNU General Public License v3.0](LICENSE)

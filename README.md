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
- **自动刷新**: 每分钟后台刷新一次，弹窗未打开也保持最新；双击账号图标可手动刷新
- **自动更新**: 内置 Sparkle 更新检查，新版本自动更新
- **本地优先**: 只与本机 Codex app-server 进程通信，不向任何第三方服务发送账号、额度、token 或工作流统计数据

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

开启前会通过本机 Codex app-server 检查全局 `config.toml` 是否禁用了 Hook；如果已禁用，CodexBar 不会写入配置，并会在 Hook 选项下方提示。写入后还会用 `hooks/list` 确认 CodexBar 自己的 Hook 命令、事件、来源、启用状态、信任状态以及 Codex 返回的警告或错误。

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
'/Applications/CodexBar.app/Contents/MacOS/CodexBar'
```

开启后，用量热力图会包含今天；鼠标悬停到任意一天时，弹窗会在 token 数之外展示当天的会话总数、对话轮次、子智能体、工具调用、权限请求和上下文压缩次数。关闭 Hook 时，弹窗只展示日期和 token 数；如果 app-server 尚未返回当天 token 数据，热力图不会额外占位展示今天。

CodexBar 只会追加或移除 command 中包含当前 CodexBar 可执行路径的 Hook，不会删除其他 Codex Hook。

统计数据只保存在本机 `~/Library/Application Support/CodexBar/HookEvents/`，不会发送给任何个人或第三方服务。

## 从源码构建

```bash
git clone git@github.com:bob-zebedy/CodexBar.git
cd CodexBar
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build
```

也可以直接用 Xcode 打开 `CodexBar.xcodeproj` 运行。项目使用 SwiftUI + MVVM 依赖 Sparkle (SwiftPM)

## 源码结构

Swift 源码按职责放在 `CodexBar/` 下的子目录中:

- `App/`: 应用入口
- `Controllers/`: 菜单栏、菜单面板和独立窗口控制器
- `Models/`: account、quota、usage、工作流统计、共享日期网格和错误分类模型
- `Services/`: app-server 会话、Codex CLI 解析、版本探测、Hook 设置、工作流统计、开机自启和 Sparkle 更新
- `Views/`: 菜单面板、设置窗口、日志窗口和共享 Liquid Glass 样式

更详细的启动、刷新、Hook 统计、设置、日志、更新和发布流程见 [开发文档](Docs/DevelopmentGuide.md)。

## 隐私

CodexBar 只与本机 Codex app-server 进程通信。账号信息、额度数据、token 用量和 Hook 工作流数据不会被收集或发送给任何个人或服务。

只有检查和下载 App 更新时会产生额外网络请求，请求范围仅包含 [appcast](https://codexbar.zabrian.app/appcast.xml) 和 appcast 中对应的 DMG 下载地址。

## 许可证

本项目采用 [GNU General Public License v3.0](LICENSE)

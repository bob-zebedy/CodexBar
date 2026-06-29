# CodexBar

> 常驻 macOS 菜单栏的 Codex 状态看板

CodexBar 在不打开 Codex CLI 或 Codex App 的情况下快速查看 Codex 账号状态、额度重置时间、Token 用量和本机使用情况统计。它连接本机 Codex app-server 获取账号与用量信息，也可以通过 Codex Hook 记录本机 Codex 事件，让菜单栏成为一个轻量、实时、的 Codex 仪表盘。

<p align="center">
  <img src="Images/record.gif" width="532">
</p>

## 为什么需要 CodexBar

Codex 的额度、Token 用量和使用情况通常分散在终端、App 或 Session 中。CodexBar 把这些信息放到一个可随时呼出的菜单栏面板中，适合需要频繁使用 Codex、关注剩余额度和使用情况的 macOS 用户。

- 查看当前账号是否已登录，以及 Codex CLI / Codex.app 的运行版本
- 跟踪不同时间窗口的额度剩余比例和下一次重置时间
- 用 30 周热力图回顾每日 Token 用量
- 在开启 Codex Hook 后在 30 周热力图中可查看会话、对话轮次、工具调用、权限请求、上下文压缩和子智能体统计 (仅在开启后可记录查看，无法查看到历史数据)
- 通过可选 iCloud 私有数据库同步实现跨平台数据合并

## 有什么功能

### 菜单栏即状态中心

CodexBar 是一个无 Dock 图标的 macOS 菜单栏应用。

左键点击菜单栏图标即可打开状态面板。

右键 (或者 `⌃ + 鼠标左键点击`) 可进入设置、日志或退出应用。

使用默认全局快捷键 `⌘ ⇧ W` 适合在任何工作区快速查看当前 Codex 状态。

### 额度与重置时间一眼可见

额度区用分段电量条展示不同时间窗口的剩余额度，并显示剩余百分比和重置时间。存在可用手动重置机会时，鼠标悬停在 `重置 xN` 上会显示各重置机会的过期时间和数量。

### 近 30 周 Token 热力图

热力图以周为列、日为行展示近 30 周的每日 Token 用量。

鼠标悬停到任意日期时，会打开侧边详情面板展示当天 Token 数和用量强度。

开启 Codex Hook 后，同一面板还会展示当天的使用详情统计。

### Codex Hook 使用详情

在设置中开启「启用 Codex Hook」后，CodexBar 会把自身注册为本机 Codex Hook 用于记录会话开始、回复结束、工具调用、权限请求、上下文压缩和子智能体事件。

统计结果会汇总到热力图详情面板中，不打断正常的 Codex 使用流程。

CodexBar 只会追加或移除属于当前 CodexBar 可执行文件的 Hook 处理器，不会删除用户已有的其他 Codex Hook。

更详细的配置、存储和统计口径见 [Codex Hook 文档](Docs/CodexHook.md)

### 可选跨设备同步

如果已经开启 Codex Hook，且当前 iCloud 账号可用，可以在设置里开启「跨设备同步」

CodexBar 会把该设备的使用详情数据同步到当前 iCloud 账号的 CloudKit private database，用于在多台 Mac 上合并查看工作流统计。

同步不会上传 Codex 账号、额度、Token 用量、原始 Hook events、会话 ID、轮次 ID、请求日志或 Codex 认证文件。

完整同步范围见 [跨设备同步文档](Docs/CrossDeviceSync.md)

### 日志与版本信息

CodexBar 内置请求日志窗口，用于查看 app-server 请求状态和排查刷新问题。设置页会展示 CodexBar 版本、当前 Codex CLI / Codex.app 版本、运行来源和本地安装路径，路径点击即可复制。

### 自动更新

CodexBar 使用 Sparkle 检查更新。安装后，新版本会通过内置更新流程推送；也可以从设置窗口手动检查更新。

## 安装

### 下载

从 [Releases](https://github.com/bob-zebedy/CodexBar/releases) 下载最新 DMG，打开后把 `CodexBar.app` 拖入 `/Applications`。

后续版本会通过内置 Sparkle 自动更新推送。

### 运行要求

- macOS 15.0 或更高版本
- 已安装 [Codex CLI](https://github.com/openai/codex)，或已安装 `Codex.app`
- 已在 Codex 中完成登录

> 如果移动应用位置后才开启开机自启，建议重新开关一次「开机启动」，让 macOS 记录最终应用路径。

## 隐私

CodexBar 默认通过本机 Codex app-server 读取账号、额度和 Token 用量。若 app-server 返回可用手动重置机会，CodexBar 会使用本机 Codex OAuth token 向 `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` 发起只读请求，用于读取这些重置机会的过期时间；请求失败时不会展示过期时间，也不会保留原始响应。

Codex Hook 工作流数据默认只保存在本机:

```text
~/Library/Application Support/CodexBar/HookEvents/
```

只有在用户开启「跨设备同步」后，CodexBar 才会通过 `CloudKit private database` 同步每日使用详情数据; 同步的数据副本只包含各个事件数量，不包含事件具体的数据。

除上述重置机会过期时间查询、Sparkle appcast / DMG 下载，以及用户开启跨设备同步后的 CloudKit 请求外，CodexBar 自身不发起其他网络请求。

## 从源码构建

项目使用 Swift 6、SwiftUI + AppKit + MVVM，依赖 Sparkle (SwiftPM)

```bash
git clone git@github.com:bob-zebedy/CodexBar.git
cd CodexBar
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build
```

也可以直接用 Xcode 打开 `CodexBar.xcodeproj` 运行。

## 项目文档

- [app-server 通信合约](Docs/AppServer.md)
- [Codex Hook 工作流统计](Docs/CodexHook.md)
- [跨设备同步](Docs/CrossDeviceSync.md)
- [开发文档](Docs/DevelopmentGuide.md)

Swift 源码按职责放在 `CodexBar/` 下:

- `App/`: 应用入口
- `Controllers/`: 菜单栏、菜单面板和独立窗口控制器
- `Models/`: 账号、额度、用量、工作流统计和错误模型
- `Services/`: app-server、Codex CLI、设置、Hook、统计、日志、开机自启和更新服务
- `Views/`: 菜单面板、设置窗口、日志窗口和共享 Liquid Glass 样式

## 许可证

本项目采用 [GNU General Public License v3.0](LICENSE)

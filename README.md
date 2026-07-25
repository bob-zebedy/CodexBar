# CodexBar

CodexBar 是一款 macOS 菜单栏应用, 用于查看本机 Codex 账号, 额度, Token 用量和任务状态; 应用不显示 Dock 图标, 主要数据通过本机 Codex app-server 获取

<p align="center">
  <img src="Images/preview.gif" width="600" alt="CodexBar 预览">
</p>

## 功能

- 查看账号, 订阅类型, 额度窗口, 剩余比例和重置时间
- 查看手动重置机会及其过期时间
- 查看 Token 摘要和近 30 周用量热力图
- 通过可选 Codex Hook 展示运行中, 等待批准, 最近完成和最近终止的任务
- 按天统计会话, 轮次, 工具调用, 权限请求, 上下文压缩, 子 Agent 和常用模型
- 提供额度, 任务和重置机会通知, 可分别选择通知声音
- 在 Codex 任务运行时按需阻止系统休眠
- 通过 iCloud 私有数据库同步脱敏的每日工作流聚合
- 支持菜单栏额度指示, 全局快捷键, 开机启动, 交互日志和 Sparkle 更新

## 运行要求

- macOS 15.0 或更高版本
- 已安装并登录 [Codex CLI](https://github.com/openai/codex), ChatGPT App 或 Codex App

CodexBar 优先使用 `PATH` 中的全局 `codex`, 找不到时依次检查 ChatGPT App 和 Codex App 内置的 Codex 可执行文件

## 安装

使用 Homebrew

```bash
brew install --cask bob-zebedy/tap/codexbar
```

也可以从 [Releases](https://github.com/bob-zebedy/CodexBar/releases) 下载 DMG, 并将 `CodexBar.app` 拖入 `/Applications`

## 基本使用

- 左键点击菜单栏图标: 打开或关闭主面板
- 右键或 `Control` + 左键点击: 打开设置, 日志和退出菜单
- 全局快捷键: 默认 `⌘⇧W`
- 打开设置: `⌘,`
- 主面板打开时打开日志: `⌘L`

完整说明见 [使用指南](Docs/UserGuide.md)

## 数据与隐私

账号, 额度和 Token 用量由本机 Codex app-server 返回; Hook 原始事件默认只保存在本机

```text
~/Library/Application Support/CodexBar/HookEvents/
```

跨设备同步关闭时, 工作流数据不会上传; 开启后只同步每日聚合, 不上传原始事件, 会话 ID, 轮次 ID, app-server 日志或 Codex 认证文件

应用自身的网络访问仅用于

- 查询手动重置机会的过期时间
- Sparkle 更新检查与下载
- 用户开启后的 CloudKit 私有数据库同步

## 开发

使用 Xcode 打开 `CodexBar.xcodeproj`, 或运行

```bash
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build
```

工程结构, 构建和发布说明见 [开发指南](Docs/DevelopmentGuide.md)

## 文档

- [使用指南](Docs/UserGuide.md)
- [Codex app-server](Docs/AppServer.md)
- [Codex Hook 与工作流统计](Docs/CodexHook.md)
- [跨设备同步](Docs/CrossDeviceSync.md)
- [阻止系统休眠](Docs/KeepAlive.md)
- [开发指南](Docs/DevelopmentGuide.md)

## 许可证

本项目采用 [GNU General Public License v3.0](LICENSE)

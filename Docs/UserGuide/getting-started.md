# 安装与快速开始

简体中文 | [English](../en/UserGuide/getting-started.md)

## 运行要求

- macOS 15.0 或更高版本
- 已安装并登录 [Codex CLI](https://github.com/openai/codex)，或安装了内置 Codex 的 ChatGPT App 或 Codex App
- 当前使用的 Codex 版本需要为 `0.143.0` 或更高版本
- 使用 Hook 相关功能时，当前使用的 Codex 版本需要为 `0.145.0` 或更高版本
- 使用跨设备同步时，Mac 需要登录可用的 iCloud 账户

CodexBar 默认自动选择来源，优先使用全局安装的 Codex CLI，找不到时再尝试 ChatGPT App 和 Codex App 内置的 Codex。可在“设置 > 关于 > Codex 版本 > 来源”中手动选择。

## 安装

### 通过 Homebrew

```bash
brew install --cask bob-zebedy/tap/codexbar
```

### 通过 DMG

1. 从 [GitHub Releases](https://github.com/bob-zebedy/CodexBar/releases) 下载最新 DMG
2. 打开 DMG 并将 CodexBar 拖入 Applications
3. 从 Applications 启动 CodexBar

## 第一次启动

CodexBar 是菜单栏 App，启动后不会在 Dock 中显示图标：

1. 在屏幕顶部菜单栏找到 CodexBar 图标
2. 左键点击图标打开主面板
3. 等待首次账户和用量刷新完成
4. 如果显示未登录，先在当前 Codex 中完成登录
5. 如果需要实时任务、任务类通知、防睡眠或 Hook 统计，在 `设置 > 高级` 中开启 CodexBar Hook

CodexBar 每 60 秒自动刷新一次账户、额度和 Token 用量，双击主面板中的账户图标可以立即刷新。

## 基本操作

| 操作 | 结果 |
| --- | --- |
| 左键点击菜单栏图标 | 打开或关闭主面板 |
| 右键或 Control 点击菜单栏图标 | 打开设置、日志和退出菜单 |
| `⌘⇧W` | 使用默认全局快捷键打开或关闭主面板 |
| `⌘,` | 打开设置窗口 |
| `⌘L` | 主面板打开时关闭面板并打开日志窗口 |
| 双击账户图标 | 立即刷新账户、额度和用量 |
| 双击账户邮箱 | 切换邮箱模糊显示 |
| 悬停热力图方块 | 查看当天 Token 和 Hook 统计 |
| 点击活动卡片 | 打开并发任务中心 |
| 点击 `留存重置` | 查看各批次过期时间 |
| `设置 > 高级 > 自动重置` | 配置是否自动重置以及提前量 |

全局快捷键优先在鼠标所在屏幕打开主面板，菜单栏锚点不可用时会使用独立浮动面板。

## 开启更多功能

- [CodexBar Hook](activity-and-hook.md)：实时任务、每日活动统计和按任务防睡眠
- [系统通知](notifications.md)：任务和额度提醒，需允许 macOS 通知权限
- [自动重置](settings.md#自动重置)：提前使用即将过期的留存重置，可能短暂唤醒 Mac
- [防止系统睡眠](sleep-prevention.md)：长任务期间保持 Mac 唤醒，需批准后台服务
- [跨设备同步](sync-data-privacy.md)：合并多台 Mac 的 Hook 统计，需登录 iCloud

## 语言与地区

CodexBar 提供简体中文和英文界面，默认跟随 macOS 的 App 语言偏好。

需要单独切换时，可在 macOS 系统设置的语言与地区页面为 CodexBar 指定 App 语言。

下一步可以阅读 [主面板与菜单栏](main-panel.md) 或 [设置参考](settings.md)

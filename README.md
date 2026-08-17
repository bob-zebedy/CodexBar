<div align="center">

<img src="Images/icon.png" width="128" alt="CodexBar">

# CodexBar

**在 macOS 菜单栏一眼看清 Codex**

简体中文 | [English](README.en.md)

[![macOS](https://img.shields.io/badge/macOS-15.0+-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Release](https://img.shields.io/github/v/release/bob-zebedy/CodexBar?color=1F6FEB)](https://github.com/bob-zebedy/CodexBar/releases)
[![Downloads](https://img.shields.io/github/downloads/bob-zebedy/CodexBar/total?color=2EA043)](https://github.com/bob-zebedy/CodexBar/releases)
[![License](https://img.shields.io/github/license/bob-zebedy/CodexBar?color=8957E5)](LICENSE)

[功能](#功能) | [安装](#安装) | [快速开始](#快速开始) | [使用文档](#使用文档) | [隐私](#隐私)

<img src="Images/preview.gif" width="640" alt="CodexBar 预览">

</div>

---

CodexBar 是面向 macOS 15 及更高版本的菜单栏 App, 用于集中展示 Codex 账户, 额度, Token 用量和实时任务状态

它可以在任务完成, 等待批准或额度变化时提醒你, 也能只在 Codex 任务运行期间自动防止系统睡眠

## 功能

### 账户与额度一目了然

- 展示当前 Codex 账户和套餐
- 展示全部额度窗口, 剩余比例和重置时间
- 展示可用积分和手动重置次数
- 支持自动重置，可设置在手动重置次数过期前 15 分钟到 6 小时执行，默认提前 30 分钟；计划到点时可唤醒 Mac，并在执行前重新确认可用状态
- 可在菜单栏图标旁直接显示所选额度窗口

### 看见自己的 Codex 使用节奏

- 展示累计 Token, 单日峰值和连续使用天数
- 展示最长任务时长
- 通过 30 周热力图回顾每日 Token 用量
- 开启 CodexBar Hook 后可查看会话, 对话轮次, 工具调用和子 Agent 等每日统计

### 不错过正在发生的任务

- 菜单栏状态点区分运行中, 等待批准和刚完成任务
- 主面板展示当前任务, 项目, 模型, 推理强度和持续时间
- 任务中心集中查看并发任务, 最近完成和最近终止记录
- 支持任务完成, 等待批准和异常会话提醒

### 让长任务安心运行

- 只在符合条件的 Codex 任务存在时防止系统睡眠
- 可选择等待批准期间继续保持, 或同时保持屏幕常亮
- 支持最长防睡眠时间, 低电量保护和异常会话保护
- 任务结束或保护条件触发后自动恢复系统睡眠

### 融入 macOS 工作流

- 作为菜单栏 App 运行, 不占用 Dock
- 支持全局快捷键, 开机启动和自动更新
- 支持简体中文和英文界面
- 可选通过 iCloud 合并多台 Mac 的每日 Hook 统计

## 安装

### Homebrew

```bash
brew install --cask bob-zebedy/tap/codexbar
```

### DMG

从 [GitHub Releases](https://github.com/bob-zebedy/CodexBar/releases) 下载最新版本并拖入 Applications

## 运行要求

- macOS 15.0 或更高版本
- 已安装并登录 [Codex CLI](https://github.com/openai/codex) 或安装了内置 Codex 的 ChatGPT App 或 Codex App
- 当前运行的 Codex 版本需要为 `0.143.0` 或更高版本
- 使用实时任务等 Hook 功能时, 当前运行的 Codex 版本需要为 `0.145.0` 或更高版本
- 使用跨设备同步时, Mac 需要登录可用的 iCloud 账户

## 快速开始

1. 启动 CodexBar, 在菜单栏找到 CodexBar 图标
2. 左键点击图标查看账户, 额度和 Token 用量
3. 右键或按住 Control 点击图标打开设置, 日志或退出菜单
4. 在 `设置 > 高级` 中启用 CodexBar Hook, 解锁实时任务, 任务类通知, 防睡眠和 Hook 统计

默认全局快捷键为 `⌘⇧W`, 可在设置中重新录制或关闭

## 使用文档

| 文档 | 内容 |
| --- | --- |
| [用户手册](Docs/UserGuide/README.md) | 安装, 主面板, Hook, 通知, 防睡眠, 同步, 全部设置和问题排查 |
| [开发者指南](Docs/DeveloperGuide/README.md) | 架构, 数据链路, 核心状态机, 存储, 隐私边界和开发验证 |
| [文档导航](Docs/README.md) | 文档导航 |

## 隐私

CodexBar 所有数据都在本地处理, 只有在开启跨设备同步功能后才会将各种汇总的数据上传到 iCloud private database

完整的数据访问, 本机存储和网络边界见 [数据, 同步与隐私](Docs/UserGuide/sync-data-privacy.md)

## 反馈

Bug, 功能建议或使用问题欢迎通过 [GitHub Issues](https://github.com/bob-zebedy/CodexBar/issues) 反馈

## 许可证

[GNU General Public License v3.0](LICENSE)

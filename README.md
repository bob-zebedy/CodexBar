<div align="center">

<img src="Images/icon.png" width="128" alt="CodexBar">

# CodexBar

**在 macOS 菜单栏一眼看清 Codex**

简体中文 | [English](README.en.md)

[![macOS](https://img.shields.io/badge/macOS-15.0+-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![Release](https://img.shields.io/github/v/release/bob-zebedy/CodexBar?color=1F6FEB)](https://github.com/bob-zebedy/CodexBar/releases)
[![Downloads](https://img.shields.io/github/downloads/bob-zebedy/CodexBar/total?color=2EA043)](https://github.com/bob-zebedy/CodexBar/releases)
[![License](https://img.shields.io/github/license/bob-zebedy/CodexBar?color=8957E5)](LICENSE)

[功能](#功能) | [安装](#安装) | [快速开始](#快速开始) | [隐私](#隐私) | [运行架构](https://codexbar.zabrian.app/architecture) | [性能报告](https://codexbar.zabrian.app/performance)

<img src="Images/preview.gif" width="640" alt="CodexBar 预览">

</div>

---

CodexBar 是 macOS 的菜单栏 App，用于集中展示 Codex 账户、额度、Token 用量和实时任务状态。

## 功能

### 账户与额度一目了然

- 查看账户、套餐、积分，以及各额度窗口的剩余比例和重置时间
- 在菜单栏直接显示关注的额度
- 查看留存重置及到期时间，支持到期前自动使用

### 随时掌握任务进展

- 查看项目、模型、推理强度、任务耗时和 Token 用量
- 实时显示执行状态、等待操作、任务进度和最近事件
- 在任务中心集中查看并发任务及最近完成、失败和中断的记录

### 回顾使用情况

- 查看累计用量、单日峰值、连续使用天数和最长任务时长
- 通过热力图查看每日 Token 用量和活动统计
- 通过 iCloud 汇总多台 Mac 的使用记录

### 及时收到提醒

- 接收任务完成、等待审批、额度变化和保护提醒
- 按需选择通知类型、音效和任务触觉反馈
- 通过屏幕顶部的任务流光感知状态变化，支持自定义外观

### 让长任务安心运行

- 任务运行时自动防止 Mac 睡眠，结束后恢复正常睡眠
- 可在等待审批时继续保持唤醒，或同时保持屏幕常亮
- 支持防睡眠时限、低电量保护和异常会话保护

### 按你的习惯使用

- 自定义主面板区域的顺序、显隐和动画效果
- 支持全局快捷键、开机启动和自动检查更新
- 提供简体中文、英文界面，以及便于排查问题的日志查看功能

## 安装

### Homebrew

```bash
brew install --cask bob-zebedy/tap/codexbar
```

### DMG

从 [GitHub Releases](https://github.com/bob-zebedy/CodexBar/releases) 下载最新版本并拖入 Applications。

## 运行要求

- macOS 15.0 或更高版本
- 已安装并登录 [Codex CLI](https://github.com/openai/codex) 或安装了内置 Codex 的 ChatGPT App 或 Codex App
- Codex 后台服务版本为 `0.157.0` 或更高版本
- 使用跨设备同步时，Mac 需要登录可用的 iCloud 账户

## 隐私

活动原始事件和实时任务在本机处理。开启跨设备同步后，日级活动聚合和 Token 用量记录会上传到 iCloud private database。

## 反馈

Bug、功能建议或使用问题欢迎通过 [GitHub Issues](https://github.com/bob-zebedy/CodexBar/issues) 反馈。

## 许可证

[GNU General Public License v3.0](LICENSE)

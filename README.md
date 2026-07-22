# CodexBar

> 在 macOS 菜单栏，一眼查看 Codex 状态、额度与使用情况。

CodexBar 是一款无 Dock 图标的 macOS 菜单栏应用。无需打开 Codex CLI 或 Codex App，即可快速了解账号状态、剩余额度、重置时间、Token 用量和正在进行的任务。

<p align="center">
  <img src="Images/preview.gif" width="600" alt="CodexBar 预览">
</p>

## 主要功能

- **额度状态**：查看各时间窗口的剩余额度、重置时间和手动重置机会
- **Token 热力图**：用近 30 周日历热力图回顾每日 Token 用量
- **实时任务**：开启 Codex Hook 后，查看运行中、等待批准、最近完成和终止的任务
- **工作流统计**：按日期查看会话、对话轮次、工具调用、权限请求、上下文压缩和子 Agent 等数据
- **及时提醒**：可选额度告急、额度恢复、等待批准、长任务完成通知与触觉反馈
- **跨设备汇总**：通过可选的 iCloud 私有数据库同步每日聚合数据
- **本地优先**：账号、额度、Token 用量和工作流事件均以本机处理为主
- **原生体验**：支持全局快捷键、开机启动、系统日志和 Sparkle 自动更新

## 安装

### Homebrew

```bash
brew install --cask bob-zebedy/tap/codexbar
```

也可以从 [Releases](https://github.com/bob-zebedy/CodexBar/releases) 下载最新 DMG，并将 `CodexBar.app` 拖入 `/Applications`

运行要求：

- macOS 15.0 或更高版本
- 已安装并登录 [Codex CLI](https://github.com/openai/codex) 或 Codex App

更多使用方法见[使用指南与常见问题](Docs/UserGuide.md)

## 许可证

本项目采用 [GNU General Public License v3.0](LICENSE)

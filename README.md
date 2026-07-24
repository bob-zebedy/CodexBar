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
- **阻止系统休眠**：可选仅在任务真正运行时阻止 macOS 的空闲、合盖和手动休眠，可设置从最近任务启动或获批恢复起的最长期限，并在等待批准、任务结束或到期后自动恢复；恢复后会立即让系统重新评估是否已经满足休眠条件
- **工作流统计**：按日期查看会话、对话轮次、工具调用、权限请求、上下文压缩和子 Agent 等数据
- **及时提醒**：可选额度告急、额度恢复、等待批准、长任务完成通知与触觉反馈，各类通知声音可独立选择
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

「阻止系统休眠」需要 Codex Hook，并在首次开启时要求 macOS 允许 CodexBar 后台项目；关闭 Hook 会自动关闭并置灰该选项。最长防休眠期限可选 1、2、4、8、12、24 小时或无限制，默认 12 小时；新任务启动以及同一任务等待用户批准后恢复运行都会重新计时，普通 Hook 活动不会续期。任务运行时，CodexBar 同时关闭系统休眠并持有阻止空闲休眠的系统 assertion。每次恢复时先还原任务开始前的系统设置，再释放 assertion，让 macOS 按当前空闲计时、其他 assertion 和电源策略立即重新判断是否应休眠；普通合盖且系统确认合盖应休眠时还会主动请求休眠。电脑原本就全局禁止休眠或处于外接显示器合盖工作模式时不会强制休眠。合盖运行会增加耗电和发热，请确保 Mac 通风良好，不要在密闭包内使用。

## 许可证

本项目采用 [GNU General Public License v3.0](LICENSE)

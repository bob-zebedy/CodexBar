# CodexBar 用户手册

## 文档目录

| 文档 | 内容 |
| --- | --- |
| [安装与快速开始](getting-started.md) | 运行要求、安装方式、基本操作和功能依赖 |
| [主面板与菜单栏](main-panel.md) | 菜单栏状态、账户、额度、Token 热力图和任务中心 |
| [实时任务与 CodexBar Hook](activity-and-hook.md) | Hook 的作用、启用方式、任务状态和历史统计 |
| [通知与提醒](notifications.md) | 每类通知的触发条件、默认值、音效和触觉反馈 |
| [防止系统睡眠](sleep-prevention.md) | 生效条件、全部保护选项、CodexBarHelper 授权和外部来源共存 |
| [数据、同步与隐私](sync-data-privacy.md) | 本机数据、iCloud 同步、重建数据和网络边界 |
| [设置参考](settings.md) | 通用、高级和关于页面中每一个设置的作用，包括自动重置 |
| [常见问题与排查](troubleshooting.md) | 登录、Hook、通知、自动重置、防睡眠、同步和日志问题 |

## 按目标快速查找

- 只想查看账户和额度，从 [安装与快速开始](getting-started.md) 开始
- 想看正在运行或等待批准的任务，阅读 [实时任务与 CodexBar Hook](activity-and-hook.md)
- 想在重置次数到期前自动重置额度，阅读 [设置参考](settings.md#自动重置)
- 想在长任务期间阻止 Mac 睡眠，阅读 [防止系统睡眠](sleep-prevention.md)
- 想知道某个开关是否会上传数据，阅读 [数据、同步与隐私](sync-data-privacy.md)
- 已经遇到错误提示，直接进入 [常见问题与排查](troubleshooting.md)

## 术语约定

| 术语 | 含义 |
| --- | --- |
| Codex | Codex CLI, ChatGPT App 或 Codex App 中运行的 Codex 能力 |
| app-server | CodexBar 在本机启动并连接的 Codex 数据接口进程 |
| CodexBar Hook | CodexBar 安装到 Codex 配置中的事件处理器 |
| 实时任务 | CodexBar 根据 Hook 事件和本机会话状态判断出的运行中或等待批准任务 |
| Hook 聚合 | 从本机 Hook 原始事件计算出的每日会话、轮次和工具等统计 |
| CodexBarHelper | 负责系统级睡眠状态切换和固定自动重置唤醒计划的 CodexBar 后台服务 |

返回 [CodexBar README](../../README.md)

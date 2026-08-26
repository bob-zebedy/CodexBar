# 实时任务与 CodexBar Hook

简体中文 | [English](../en/UserGuide/activity-and-hook.md)

## Hook 解决什么问题

账户、额度和 Token 用量是周期性快照，无法说明一轮 Codex 任务正在运行、等待批准还是已经结束。

CodexBar Hook 会在 Codex 的关键事件发生时记录少量结构化字段，为 CodexBar 提供以下能力：

- 菜单栏任务状态点和任务提示
- 主面板活动卡片和并发任务中心
- 任务完成、等待批准和异常会话提醒
- 任务触觉反馈
- 每日会话、轮次、工具调用、权限请求、上下文压缩和子 Agent 统计
- 按实时任务自动防止系统睡眠
- 跨设备同步每日 Hook 聚合
- 从原始事件重建历史聚合

## 启用条件

开启 CodexBar Hook 前需要满足以下条件：

- CodexBar 能连接当前运行的 Codex app-server
- app-server 实际运行版本为 `0.145.0` 或更高版本
- Codex 配置中的 `features.hooks` 没有被全局关闭
- 当前 `hooks.json` 是有效 JSON

版本检查以当前已连接 app-server 的握手版本为准，不是磁盘上刚安装的版本。

更新 Codex 后如果仍提示版本过低，退出并重新打开 CodexBar 以建立新连接。

## 开启方法

1. 右键或 Control 点击菜单栏图标
2. 选择 `设置`
3. 打开 `高级` 页面
4. 开启 `CodexBar Hook`
5. 等待开关完成配置和校验

CodexBar 会在每次打开设置窗口或 App 重新激活时重新检查已安装 Hook。

## 配置文件会发生什么变化

CodexBar 使用 `$CODEX_HOME/hooks.json`，未设置 `CODEX_HOME` 时使用 `~/.codex/hooks.json`

开启时会完成以下操作：

1. 读取并保留已有配置
2. 为 CodexBar 追加独立的 command handler
3. 让 Codex 校验事件列表、来源和信任状态
4. 只更新与当前 CodexBar handler 匹配的信任项

关闭时只删除同时匹配当前 CodexBar 可执行路径和 `--hook-event` 参数的 handler。

用户自己的 handler、其他 App 的 handler、未识别字段和无关信任项都会保留。

## 任务状态如何理解

| 状态 | 含义 | 是否算作活跃任务 |
| --- | --- | --- |
| 运行中 | 当前任务仍在产生进展 | 是 |
| 等待批准 | 当前任务正在等待用户批准下一步操作 | 是 |
| 最近完成 | 一轮任务已确认结束 | 否 |
| 最近终止 | 一轮任务被确认终止 | 否 |
| 已隐藏 | 运行中任务超过异常会话静默阈值 | 否 |

完成只表示一轮任务结束，不代表执行结果一定成功。

等待批准只用于真正由用户处理的批准请求，自动审核不会被显示成用户等待状态。

子 Agent 事件会更新所属顶层任务，不会独立显示为另一条并发任务。

Codex Auto-review 使用独立 reviewer agent 处理权限审核。CodexBar 会识别并排除这个内部审核任务，因此它不会显示在菜单栏、活动卡片或任务中心，也不会触发通知、触觉反馈、异常会话保护或防睡眠。其他子 Agent 的现有行为不变。

Auto-review 来源优先根据 rollout 元数据识别；rollout 来源不可用时，精确匹配 `codex-auto-review` 的 model 作为后备判定。实时任务读取本机 Hook 记录时应用同一规则，不回填或重写原始记录。

Hook 事件缺少 session ID 时，CodexBar 会按项目显示匿名任务。匿名任务仍可出现在运行中、等待批准、最近完成和最近终止列表中，但不触发任务通知或触觉反馈，不参与防睡眠和异常会话保护。

活动卡片和任务中心使用橙色匿名图标标记这类任务，悬停时显示 `匿名任务不参与防睡眠`

## Hook 事件与用途

| 事件 | 主要用途 |
| --- | --- |
| `SessionStart` 和 `SessionEnd` | 会话生命周期、会话统计和任务收尾 |
| `UserPromptSubmit` 和 `Stop` | 对话轮次、任务开始和完成候选 |
| `PreToolUse` 和 `PostToolUse` | 工具调用统计和任务进展 |
| `PermissionRequest` | 用户等待状态和权限请求统计 |
| `PreCompact` 和 `PostCompact` | 上下文压缩统计和任务进展 |
| `SubagentStart` 和 `SubagentStop` | 子 Agent 数量、状态和任务进展 |

## 每日统计如何计算

| 指标 | 含义 |
| --- | --- |
| 会话 | 当天不同 Codex session 的数量 |
| 对话轮次 | 当天不同 turn 的数量 |
| 工具调用 | `PreToolUse` 和 `PostToolUse` 两类计数中的较大值 |
| 权限请求 | `PermissionRequest` 事件数量 |
| 上下文压缩 | `PreCompact` 和 `PostCompact` 两类计数中的较大值 |
| 子 Agent | `SubagentStart` 和 `SubagentStop` 两类计数中的较大值 |
| 最常用模型 | 当天 Hook 事件中出现次数最多的模型 |

使用较大值可以在成对事件缺少一端时保留已经观察到的操作数量。

Auto-review 只从实时任务链路中排除，其 Hook 事件仍参与上述每日统计。

## 关闭 Hook 的影响

关闭 Hook 后以下功能停止更新：

- 实时任务和任务中心
- 菜单栏任务状态点
- 任务类通知和触觉反馈
- Hook 每日统计
- 防止系统睡眠
- 跨设备 Hook 聚合同步

账户、额度、Token 热力图、更新检查和日志窗口仍然可以使用。

## 数据边界

Hook 原始事件只保存时间、事件名、归一化来源 `origin`、模型、推理强度、权限模式、`reviewer`、`session`、`turn`、`agent`、工具名和工作目录等结构化字段。

CodexBar 不保存 rollout 路径、原始来源值、prompt 文本、Codex 回复、工具参数或工具输出。

完整存储和同步边界见 [数据、同步与隐私](sync-data-privacy.md)

返回 [用户手册](README.md)

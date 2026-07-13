# CodexBar

> 常驻 macOS 菜单栏的 Codex 状态看板

CodexBar 在不打开 Codex CLI 或 Codex App 的情况下快速查看 Codex 账号状态、额度重置时间、Token 用量和本机使用情况统计。它连接本机 Codex app-server 获取账号与用量信息，也可以通过 Codex Hook 记录本机 Codex 事件，让菜单栏成为一个轻量、实时的 Codex 仪表盘。

<p align="center">
  <img src="Images/preview.gif" width="600">
</p>

> 第一次使用或想了解所有可点击入口、状态含义和排障方法，请阅读[完整使用指南与常见问题](Docs/UserGuide.md)。

## 为什么需要 CodexBar

Codex 的额度、Token 用量和使用情况通常分散在终端、App 或 Session 中。CodexBar 把这些信息放到一个可随时呼出的菜单栏面板中，适合需要频繁使用 Codex、关注剩余额度和使用情况的 macOS 用户。

- 查看当前账号是否已登录，以及 Codex CLI / Codex.app 的运行版本
- 跟踪不同时间窗口的额度剩余比例和下一次重置时间
- 用 30 周热力图回顾每日 Token 用量
- 在开启 Codex Hook 后在 30 周热力图中可查看当天最热模型，以及会话、对话轮次、调用工具、权限请求、上下文压缩和子智能体统计 (仅在开启后可记录查看，无法查看到历史数据)
- 通过菜单栏状态点、活动卡片和并发任务中心实时查看 Codex 正在运行、等待批准及刚完成的任务
- 通过可选 iCloud 私有数据库同步实现跨设备数据合并
- 额度告急、额度恢复、任务等待批准、长任务完成时收到系统通知（可选开启）
- 任务等待批准或结束时通过支持的触控板获得触觉反馈（可选开启）

## 有什么功能

### 菜单栏即状态中心

CodexBar 是一个无 Dock 图标的 macOS 菜单栏应用。

左键点击菜单栏图标即可打开状态面板。

右键 (或者 `⌃ + 鼠标左键点击`) 可进入设置、日志或退出应用。

使用默认全局快捷键 `⌘ ⇧ W` 适合在任何工作区快速查看当前 Codex 状态。

系统设置快捷键 `⌘,` 会打开 CodexBar 的自定义设置窗口；菜单面板打开时按 `⌘L` 会直接打开日志窗口。

「菜单栏额度指示」默认开启，菜单栏图标左侧会以一条细竖向进度条显示当前账号 Codex 额度中所选窗口的剩余比例；关闭后菜单栏图标保持纯图标显示。

开启 Codex Hook 后，菜单栏小人右下角的状态点会反映实时任务状态：运行中为蓝色、等待批准为橙色、刚完成为绿色，暂无活动时不显示。主面板额度快照不可用时也不显示状态点，与活动卡片的「暂无数据」状态保持一致。状态优先级依次为等待批准、运行中、刚完成和暂无活动；小人保持系统前景色，账号异常仍使用带叉图标表示，额度竖条也保持自己的颜色。

菜单面板账号卡片下方会固定显示活动卡片，汇总当前项目、模型、工具、耗时和其他并发任务数量。主面板快照不可用时，活动卡片显示「暂无数据」且不开放任务中心；快照可用并存在活动任务、最近完成或最近终止记录时，点击卡片会打开并发任务中心，按等待确认、运行中、最近完成和最近终止分组展示全部任务。只有终止历史时，卡片显示最近一项灰色终止状态。面板优先在菜单右侧展开，空间不足时自动切换到左侧，并优先与活动卡片顶边对齐；暂时无法取得有效位置时会等待布局更新后重试，仍然失败才在主面板旁垂直居中。绿色完成状态保留 30 秒，最近完成和最近终止记录保留 10 分钟；终止记录不触发完成提醒。

### 额度与重置时间一眼可见

额度区用分段电量条展示不同时间窗口的剩余额度，并显示剩余百分比和重置时间。存在可用手动重置机会时，主 limit 标题右侧会显示 `重置次数: N`，点击后通过侧边详情面板按过期时间展示各重置机会的数量。

### 近 30 周 Token 热力图

热力图以周为列、日为行展示近 30 周的每日 Token 用量。

鼠标悬停到任意日期时，会打开侧边详情面板展示当天 Token 数和用量强度。

开启 Codex Hook 后，同一面板还会展示当天的使用详情统计。

### Codex Hook 使用详情

在设置中开启「启用 Codex Hook」后，CodexBar 会把自身注册为本机 Codex Hook 用于记录会话开始、回复结束、调用工具、权限请求、上下文压缩和子智能体事件。

统计结果会汇总到热力图详情面板中，不打断正常的 Codex 使用流程。

主 App 还会在后台只读 Hook JSONL：启动时按块恢复最近 24 小时的活动，之后 tail 当天新增事件，并在内存中维护并发任务状态。跨日任务缺少起点时会按精确 session + turn 定向查找更早的 Prompt；对于仍处于运行、等待终态确认或等待批准状态的精确 turn，CodexBar 会每秒增量读取对应本机 Codex session rollout，用 `task_started` 回填缺失起点、用 `task_complete` 补齐缺失的结束、用 `turn_aborted` 清理中断任务并生成最近终止记录，并用 `turn_context.approvals_reviewer` 区分用户审批和自动审批。只有 reviewer 明确为 `user` 且同时收到 `PermissionRequest` 时才显示等待批准；`auto_review` 不会触发等待状态或提醒。同 session 新 Prompt 会让旧 turn 立即退出活动列表，但先保留 5 秒终态确认窗口，优先接受 rollout 或迟到 Hook 的完成/终止信号，仍无终态才记为终止。不读取提示词、回复、推理、工具内容或审批内容。该实时状态用于菜单栏状态点、活动卡片、并发任务中心、可选任务通知和触觉反馈，不新增历史状态文件，也不参与跨设备同步。

CodexBar 只会追加或移除属于当前 CodexBar 可执行文件的 Hook，不会删除用户已有的其他 Codex Hook。

更详细的配置、存储和统计口径见 [Codex Hook 文档](Docs/CodexHook.md)

### 可选跨设备同步

如果已经开启 Codex Hook，且当前 iCloud 账号可用，可以在设置里开启「跨设备同步」

CodexBar 会把该设备的使用详情数据同步到当前 iCloud 账号的 CloudKit private database，用于在多台 Mac 上合并查看工作流统计。

同步不会上传 Codex 账号、额度、Token 用量、原始 Hook events、会话 ID、轮次 ID、请求日志或 Codex 认证文件。

完整同步范围见 [跨设备同步文档](Docs/CrossDeviceSync.md)

### 系统通知与触觉反馈

在设置中开启「系统通知」后，CodexBar 会在关键状态变化时发送本地通知:

- 额度剩余比例跌破所选阈值 (5% / 10% / 25%)
- 每个额度类型和时间窗口产生消耗后恢复至 100% 时提示额度已重置；窗口提供重置时间时，同一周期只提醒一次
- Codex 完成一轮超过所选时长的任务 (需开启 Codex Hook)
- Codex 请求批准工具操作并等待用户处理；当前 App 运行期间任务离开等待状态后自动撤回对应通知 (需开启 Codex Hook)
- 手动重置机会将在 7 天内过期，并按 24 小时间隔提醒

五类通知可以单独开关；全部为本地通知，不新增网络请求。

通知子面板中的「任务触觉反馈」默认开启；当任务进入等待批准或确认结束时，CodexBar 会每 100 ms 请求一次层级变化触觉反馈，连续 10 次。该功能服从 App 内「系统通知」总开关，但不依赖系统通知授权或长任务时长阈值；是否实际反馈及震感强弱由当前输入设备、辅助功能和系统偏好决定。

Hook 事件可能在一次轮询中成批到达。CodexBar 会先处理完整批次，再按任务合并等待状态：只有 reviewer 为 `user`、批次结束后仍在等待批准的任务才通知一次；自动审批以及已经恢复运行、完成或移除的短暂候选不会产生过期提醒。

Hook `Stop` 与本机 rollout 的完成信号会统一去重；迟到的重复完成、工具或权限事件不会让已完成任务重复通知、触发触觉反馈或重新显示为活动状态。

### 日志与版本信息

CodexBar 内置请求日志窗口，用于查看 app-server 请求状态和排查刷新问题。设置页会展示 CodexBar 版本、当前 Codex CLI / Codex.app 版本、运行来源和本地安装路径，路径点击即可复制。

### 自动更新

CodexBar 使用 Sparkle 检查更新。安装后，新版本会通过内置更新流程推送；也可以从设置窗口手动检查更新。

## 安装

### Homebrew

```bash
brew install --cask bob-zebedy/tap/codexbar
```

### 下载安装

从 [Releases](https://github.com/bob-zebedy/CodexBar/releases) 下载最新 DMG，打开后把 `CodexBar.app` 拖入 `/Applications`

后续版本会通过内置 Sparkle 自动更新推送。

### 运行要求

- macOS 15.0 或更高版本
- 已安装 [Codex CLI](https://github.com/openai/codex)，或已安装 `Codex.app`
- 已在 Codex 中完成登录

> 如果移动应用位置后才开启开机自启，建议重新开关一次「开机启动」，让 macOS 记录最终应用路径。

## 隐私

CodexBar 默认通过本机 Codex app-server 读取账号、额度和 Token 用量。若 app-server 返回可用手动重置机会，CodexBar 会使用本机 Codex OAuth token 向 `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` 发起只读请求，用于读取这些重置机会的过期时间；请求失败时不展示具体过期时间，重置次数侧边详情面板显示「未知过期时间」，也不会保留原始响应。

Codex Hook 工作流数据默认只保存在本机:

```text
~/Library/Application Support/CodexBar/HookEvents/
```

菜单栏实时任务状态只存在于当前 App 进程内。活动卡片和并发任务中心只展示工作目录最后一级项目名、模型、工具、阶段与耗时，不展示完整路径、会话 ID 或轮次 ID；这份状态不会上传到 CloudKit，也不会产生新的网络请求。为补齐 Hook 缺失的起点、结束或中断信号，CodexBar 只对当前活跃 turn 增量读取 `~/.codex/sessions/` 或 `~/.codex/archived_sessions/` 下对应 rollout JSONL，解析生命周期事件、turn ID 和起止耗时；不会提取、保存或展示其中的提示词、回复、推理和工具内容。

只有在用户开启「跨设备同步」后，CodexBar 才会通过 `CloudKit private database` 同步每日使用详情数据; 同步的数据副本只包含各个事件数量、项目聚合和模型名使用次数，不包含事件具体的数据。

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

- [完整使用指南与常见问题](Docs/UserGuide.md)
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

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> 本仓库已有一份详尽的 `AGENTS.md`，它是 app-server / Codex Hook / UI / 数据模型 / 发布 / Git 等各项合约的**权威来源**。本文件只做精炼导航，遇到具体行为约束请优先查 `AGENTS.md`、`Docs/AppServer.md` 与 `Docs/CodexHook.md`，不要凭记忆推断。

## 构建与验证

涉及 Swift/Xcode 工程、资源、build setting、Info.plist、SwiftPM、脚本或 UI 行为的改动后必须运行构建，要求无 error 和 warning：

```bash
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination generic/platform=macOS -derivedDataPath /tmp/CodexBarDerivedData build
```

- 没有测试 target；不存在单测可跑，验证以构建通过为准。
- `Metadata extraction skipped. No AppIntents.framework dependency found.` 是预期 warning，不算项目代码 warning。
- SourceKit 对跨文件类型偶有误报（新建文件时尤其明显），以 `xcodebuild` 结果为准，不要据此回退正确改动。
- 纯文档改动只需 `git diff --check`。
- 发布脚本改动后至少 `bash -n Scripts/dmg.sh` / `bash -n Scripts/appcast.sh`。

## 工程约定（影响如何改代码，非显而易见）

- **App Sandbox 必须保持关闭**（`ENABLE_APP_SANDBOX = NO`）：应用要启动本机 Codex CLI 并读取真实用户的 Codex 登录状态。
- app-server 与版本探测**必须使用真实用户 `HOME`/`USER`/`LOGNAME`**，不能回退到 Xcode sandbox/container 的 home。
- 工程使用 `PBXFileSystemSynchronizedRootGroup`：新增/删除 `CodexBar/` 下的 Swift 文件**通常无需改 `project.pbxproj`**；只有依赖、target/build settings、资源归属变更才动工程文件。仅 `Resources/Info.plist` 在同步组里被排除。
- 源码按目录分层：`App/` `Controllers/` `Models/` `Services/` `Views/`。新文件放入对应子目录，不要丢回 `CodexBar/` 根层。
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`：未标注的类型会被推断为 MainActor 隔离。UI 层保持 `@MainActor`；**DTO、模型、服务辅助类型、静态工具必须显式 `nonisolated`**，否则 main actor 隔离会泄漏进同步的服务代码。
- 最低 macOS 15.0；不要为 15 以下添加 SF Symbols 或 SwiftUI API 的 fallback。

## 架构（两条独立数据流）

应用是 `LSUIElement` 菜单栏程序（无 Dock 图标、无主窗口），入口 `CodexBarApp` 在启动时先分流：若标准输入中有 Codex Hook payload 且顶层 `hook_event_name` 有效，则走 `WorkflowHookEventRecorder` 记录一条 Hook 事件并立即退出，否则正常起 UI。

**1. 状态/额度流**（实时数据）

```
CodexStatusService (JSON-RPC over `codex app-server --listen stdio://`)
  → CodexStatusViewModel (@MainActor 发布 CodexLoadState / CodexQuotaSnapshot)
  → StatusItemController (菜单栏图标、popover、设置/日志窗口入口)
  → CodexStatusMenuView / AppSettingsView / LogView
```

- app-server 启动命令统一由 `CodexCLIResolver.resolveAppServerCommand()` 解析（优先全局 `codex`，否则回退 Codex.app 内置 CLI），**不要绕过 resolver**。
- 握手与读取顺序、超时/重连、token 刷新、stale 缓存等约束见 `Docs/AppServer.md` 与 `AGENTS.md` 的「app-server 合约」。
- 错误处理哲学：UI 只暴露 `notLoggedIn` / `initializationFailed` 两类特殊状态；所有具体请求/启动/超时/解析错误进 `RequestLogStore.shared`（容量 500、请求 payload 预览 4000 字符、响应和错误详情不截断），不直接展示子进程 stderr。

**2. Codex Hook 工作流统计流**（本机统计）

```
WorkflowHookEventRecorder (stdin hook_event_name 子进程)
  → WorkflowStatsStorage (events/YYYY-MM-DD.jsonl / daily.jsonl，~/Library/Application Support/CodexBar/HookEvents/)
  → WorkflowStatsService → WorkflowStatsViewModel
  → UsageSummaryView / UsageHeatmap (统计只在热力图侧边详情面板中展示)
```

- Hook 命令只写入当前 CodexBar 可执行文件路径，事件名来自 Codex 传入的 stdin payload 顶层 `hook_event_name`。
- 开启 Hook 前必须通过当前 app-server 会话调用 `config/read`，如果全局配置禁用了 Hook，则不写入 `hooks.json`，并在 Hook 选项下方提示。
- 开启 Hook 写入后必须通过当前 app-server 会话调用 `hooks/list` 验证 `command`、`eventName`、`enabled`、`sourcePath`、`trustStatus`、`warnings` 和 `errors`；未信任时提示用户去 Codex `/hooks` 信任。
- 设置开关只能追加/移除 `command` 包含当前 CodexBar 可执行路径的 Hook 处理器，绝不破坏其他用户 Hook。若用户自定义 Hook 命令也包含当前可执行路径，会被视为当前 CodexBar 处理器。
- Hook 写入可能由多个 Codex 进程并发触发，追加 `events/YYYY-MM-DD.jsonl` 并更新 `maintenance.json` 必须经 `stats.lock` + `flock` 加锁；`daily.jsonl` 由主 App 刷新维护流程写回。
- 字段兼容、保留策略、统计口径见 `Docs/CodexHook.md`。

## 并发分工

服务层对外暴露 async API，内部各用串行 `DispatchQueue` 管理 `Process`/`Pipe`/连接：`CodexBar.app-server`、`CodexBar.codex-version`（全局+内置版本并发探测后收集）、`CodexBar.workflow-stats`。`RequestLogStore` 可后台写入、用锁保护、通知切回主线程。

## 外部依赖与更新

- 唯一外部依赖：Sparkle（SwiftPM）。
- `AppUpdater` 初始化先校验 `SUFeedURL` 与 `SUPublicEDKey`，缺失则不创建 updater 并提示「未配置更新资源」。当前 `SUFeedURL = https://codexbar.zabrian.app/appcast.xml`。
- 发布：`Scripts/dmg.sh` 打 DMG、`Scripts/appcast.sh` 更新 `appcast.xml`（需 Sparkle `sign_update`）。tag、push、上传 DMG、改 appcast **均需用户明确同意**。

## Git

- 不主动 push；不回滚/覆盖非自己产生的未提交改动；提交时只提交当前代码、不附带额外改动。
- 提交信息：Conventional Commits 前缀 + 中文标题（`<type>: <描述>`，无句号），功能/修复/发布类需写 body（空行后 4 空格缩进 bullet，bullet 间不空行，整段 body 放进同一个 `-m` 或用 `git commit -F`）。type 常用 `feat`/`fix`/`chore`/`refactor`/`docs`。
- tag 格式 `v{MARKETING_VERSION}`，使用附注 tag。

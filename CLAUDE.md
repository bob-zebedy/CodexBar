# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

CodexBar 是一个 macOS 菜单栏应用 (`LSUIElement`, 无 Dock 图标)，用于展示本机 Codex 的账号状态、额度、Token 用量和工作流统计。技术栈: Swift 6 + SwiftUI + AppKit + MVVM，唯一外部依赖是 Sparkle (SwiftPM)。最低系统版本 macOS 15.0，App Sandbox 保持关闭（需要启动本机 `codex` 进程并写入用户级 Hook 配置）。

## 常用命令

```bash
# 构建（唯一 scheme 是 CodexBar，无测试 target）
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build

# 格式化（配置在 .swiftformat，Swift 6 语言模式、4 空格缩进）
swiftformat .

# Lint（配置在 .swiftlint.yml，只检查 CodexBar/ 目录）
swiftlint

# 发布脚本
Scripts/build.sh    # archive + Developer ID 导出 + notarize
Scripts/dmg.sh      # 打包 DMG
Scripts/appcast.sh  # 签名并更新 Sparkle appcast
```

本仓库没有测试 target；验证改动依靠构建通过 + 实际运行。

## Git 规则

基本约束:

- 不要主动 push，除非用户明确要求。
- 不要回滚、覆盖或丢弃不是你产生的未提交改动。
- 被要求提交时，**禁止**顺带修改任何文件内容：不做格式化、不做清理、不补文档，只把当前已有改动原样提交。

Commit message 格式: Conventional Commits 前缀 + 中文标题，需要 body 时空一行后写 4 空格缩进的 bullet。

- 标题格式 `<type>: <中文描述>`，不加句号；常用 type: `feat`、`fix`、`chore`、`refactor`、`docs`。
- 功能、修复、发布类提交必须写 body；简单文档或杂项改动可只写标题行。
- body 中多条 bullet 连续排列，bullet 之间不空行。
- 用命令行提交时，完整 body 放在同一个 `-m` 参数里或用 `git commit -F` 传文件，不要为每条 bullet 单独 `-m`。

示例:

```text
fix: 修复 Codex 状态刷新

    - 合并设置页 onAppear 和 didBecomeActive 的重复版本探测
    - 保留当前运行版本与磁盘安装版本不一致时的更新提示
```

Tag:

- tag 名格式 `v{MARKETING_VERSION}`（版本号从 Xcode build settings 读取）。
- 使用附注 tag: `git tag -a v{MARKETING_VERSION} -m "Release v{MARKETING_VERSION}"`。

## 架构总览

详细流程（含时序图、错误处理矩阵、UI 尺寸常量）见 `Docs/DevelopmentGuide.md`，这是最权威的参考。协议细节见 `Docs/AppServer.md`（app-server JSON-RPC 合约）、`Docs/CodexHook.md`（Hook 统计口径）、`Docs/CrossDeviceSync.md`（CloudKit 同步链路）。

### 启动分流（关键设计）

入口 `CodexBar/App/CodexBarApp.swift` 的 `init()` 最先调用 `WorkflowHookEventRecorder.handleIfRequested()`：

- 带 `--hook-event` 参数启动 → Hook 子进程模式：从 stdin 读 JSON payload，在 `flock` 锁内追加一行 JSONL 后立即退出，绝不初始化菜单栏 UI。写入失败静默吞掉，不阻断 Codex。
- 普通启动 → `CodexBarAppDelegate` 创建长期对象（`CodexStatusViewModel`、`WorkflowViewModel`、各 Settings、`AppUpdater`），由 `StatusItemController.install()` 装配菜单栏。

### 两条主数据链路

1. **app-server 链路**：`CodexStatusService`（actor）通过 `CodexCLIResolver` 解析出 `codex` 可执行文件（PATH 全局优先，回退 Codex.app 内置），启动 `codex app-server --listen stdio://`，用 `AppServerSession` 做 stdio JSON-RPC，合成 `CodexQuotaSnapshot` 交给 `CodexStatusViewModel` 发布。刷新间隔 60 秒，请求超时 20 秒，连接最长复用 1 小时。
2. **Hook 链路**：Hook 子进程写入 `~/Library/Application Support/CodexBar/HookEvents/events/YYYY-MM-DD.jsonl`；主 App 的 `WorkflowService`（actor）串行做增量聚合，产出 `daily.jsonl` 和 `WorkflowSnapshot` 供热力图详情面板展示。可选的跨设备同步由 `WorkflowSyncScheduler`（唯一调度者）+ `WorkflowSyncService` 走 CloudKit private database，只上传脱敏的 daily 聚合。

### 并发与隔离

工程开启 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`：所有类型默认 MainActor 隔离。因此：

- UI、控制器、ViewModel、设置、更新类直接依赖默认 MainActor，不需要额外标注
- 服务共享状态用 actor 管理（`CodexStatusService`、`WorkflowService`、`CodexCLIVersionService`）
- DTO、模型、同步辅助类型和静态工具必须显式标注 `nonisolated`
- 后台同步写入用锁：`RequestLogStorage` 用 `OSAllocatedUnfairLock`，Hook 写入用 `stats.lock` + `flock`
- 非 Sendable 的管道 IO 集中在 `PipeReadBuffer`（`JSONLineReader` / `PipeDrain` 复用它）

### 错误处理原则

- 菜单面板只暴露三种结果（`CodexFetchOutcome`）：有数据、未登录、初始化失败；启动失败/超时/断连/解析失败等细节全部只进请求日志窗口（`RequestLogStorage`，上限 500 条）
- 账号有效时 rate limits 和 usage 允许单独失败：复用同账号旧缓存并标记 stale（UI 半透明），无缓存则该区域不显示
- Hook 子进程任何失败都静默退出，优先保证不拖慢 Codex

### 菜单面板与侧边面板

- 菜单面板是 `NSPopover`（status item 锚点不可信时回退屏幕顶部居中的 `NSPanel`），关闭逻辑由 `MenuSurfaceDismissMonitor` 统一管理
- 两个侧边详情面板（热力图详情、重置次数）是菜单面板的 borderless nonactivating child panel，公共行为集中在 `Controllers/SidePanelSupport.swift`（panel 工厂、定位夹紧、抽屉动画、child window 挂载），玻璃皮肤共用 `Views/Shared/LiquidGlassStyle.swift`
- ⚠️ `HeatmapDetailPanelController` 每次 hover 内容变化必须替换 `hostingController.rootView` 并同步 `setContentSize`，不要用常驻 ObservableObject 推送 hover context——Hook 开关切换会导致面板在两种尺寸间变化，复用同一棵 SwiftUI 布局树会触发 AppKit layout 递归

### 修改 Hook 配置的约束

`~/.codex/hooks.json` 的读写在 `CodexHookSettings`：只识别并移除 command 同时包含「当前 CodexBar 可执行路径 + `--hook-event`」的 handler，必须保留用户已有 Hook、其他 App 的 Hook 和同事件下的其他 handler。写入前需通过 app-server `config/read` 确认全局未禁用 Hook，写入后用 `hooks/list` 验证。

## 隐私与数据边界

改动涉及网络或日志时必须遵守：

- App 只发起四类网络请求：本机 app-server stdio 通信（不算网络）、重置机会过期时间只读查询（`chatgpt.com/backend-api/wham/rate-limit-reset-credits`）、Sparkle 更新、用户显式开启后的 CloudKit 同步
- 不展示 app-server stderr；不展示或记录 Codex OAuth token / `auth.json` 内容
- 不把原始敏感 RPC 响应写进文档或测试夹具
- CloudKit 只同步去掉 `sessionIds` / `turnIds` 的 daily 聚合，不同步原始 Hook events、账号、额度或 Token 用量

## 目录职责

| 目录                    | 职责                                                           |
| ----------------------- | -------------------------------------------------------------- |
| `CodexBar/App/`         | SwiftUI 入口和启动分流                                         |
| `CodexBar/Controllers/` | 菜单栏、菜单面板、侧边 child panel、设置/日志窗口控制器        |
| `CodexBar/Models/`      | account、quota、usage、workflow、日期网格和错误模型            |
| `CodexBar/Services/`    | app-server、Codex CLI 解析、Hook、统计维护、同步、更新、登录项 |
| `CodexBar/Views/`       | 菜单面板、设置窗口、日志窗口和共享 Liquid Glass 样式           |
| `Scripts/`              | 构建、DMG 和 appcast 发布脚本                                  |

## 文档同步

改动涉及流程、错误处理、UI 常量或数据边界时，同步更新 `Docs/DevelopmentGuide.md` 中对应章节；协议或统计口径变化时更新 `Docs/AppServer.md` / `Docs/CodexHook.md` / `Docs/CrossDeviceSync.md`。

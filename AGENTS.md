# AGENTS.md

本文件面向在本仓库工作的编码代理。优先遵循这里的项目约定；需要更细背景时再阅读 `Docs/` 下的专题文档。

## 项目概览

CodexBar 是一个 macOS 15+ 菜单栏应用，使用 Swift 6、SwiftUI + AppKit + MVVM。应用通过本机 Codex app-server 读取账号、额度和 token 用量，通过可选 Codex Hook 记录本机 Codex 工作流事件，并在菜单栏面板、设置窗口和日志窗口中展示状态。

工程只有一个 Xcode app target：`CodexBar`。当前没有独立测试 target 或 `*Tests*` 目录。

## 重要边界

- 应用是 `LSUIElement` 菜单栏 App，不显示 Dock 图标，也不依赖主窗口。
- 最低系统版本是 macOS 15.0。
- App Sandbox 关闭，因为需要启动本机 `codex`、读取用户 Codex 登录状态，并写入用户级 Hook 配置。
- 除手动重置机会过期时间查询、Sparkle 更新、用户显式开启跨设备同步后的 CloudKit private database 同步外，App 自身不应新增网络请求。
- Codex 账号、额度、token 用量只在本机处理。Hook 工作流统计默认只写本机文件，跨设备同步只上传 daily 聚合数据，不上传原始事件、会话 ID、轮次 ID、请求日志或认证文件。
- 不要回滚或清理与当前任务无关的未提交变更；仓库可能处于脏工作树状态。

## Git 规则

- 不要主动 push。
- 不要回滚或覆盖你没做的未提交改动。
- 提交 Git 时候**禁止**任何改动任何内容，仅对目前代码进行提交即可。
- 提交 message 使用 Conventional Commits 前缀 + 中文标题 + 空行 + 4 空格缩进 bullet body。
- 提交 body 中多条 bullet 必须连续排列，bullet 之间不要空行；使用命令提交时，将完整 body 放在同一个 `-m` 参数或 `git commit -F` 文件中，不要为每条 bullet 单独使用 `-m`。
- 标题格式：`<type>: <中文描述>`，不加句号。
- 常用 type：`feat`、`fix`、`chore`、`refactor`、`docs`。
- 功能、修复、发布类提交必须写 body；简单文档或杂项可只写标题行。

示例：

```text
fix: 修复 Codex 状态刷新

    - 合并设置页 onAppear 和 didBecomeActive 的重复版本探测
    - 保留当前运行版本与磁盘安装版本不一致时的更新提示
```

Tag：

- tag 名格式 `v{MARKETING_VERSION}`。
- 使用附注 tag：`git tag -a v{MARKETING_VERSION} -m "Release v{MARKETING_VERSION}"`。

## 目录结构

- `CodexBar/App/`: SwiftUI 入口和 AppDelegate 启动分流。
- `CodexBar/Controllers/`: 菜单栏、菜单面板、侧边详情面板、设置窗口、日志窗口和窗口行为。
- `CodexBar/Models/`: account、quota、usage、workflow、日期网格、快捷键和错误模型。
- `CodexBar/Services/`: app-server、Codex CLI 解析、Codex 版本探测、Hook 设置、工作流统计、同步、日志、登录项和更新服务。
- `CodexBar/Views/`: 菜单面板、设置窗口、日志窗口和共享 Liquid Glass 样式。
- `CodexBar/Resources/`: Info.plist、entitlements、图标和 asset catalog。
- `Docs/`: app-server、Codex Hook、跨设备同步和开发文档。
- `Scripts/`: Release 构建、公证、DMG 和 Sparkle appcast 发布脚本。

## 构建与验证

日常编译验证：

```bash
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build
```

也可以直接用 Xcode 打开 `CodexBar.xcodeproj` 运行。

发布相关脚本：

```bash
Scripts/build.sh
Scripts/dmg.sh
Scripts/appcast.sh
```

`Scripts/build.sh` 默认执行 Release archive、导出 Developer ID app、公证、staple 和 Gatekeeper 校验。没有发布凭据或不需要完整发布流程时，不要把它当作普通本地验证命令。

当前没有自动化测试套件。修改后至少跑一次 `xcodebuild ... build`；如果改动涉及菜单面板、窗口焦点、Hook 或同步逻辑，需要手动说明还应覆盖的交互场景。

## Swift 与并发约定

- 项目使用 Swift 6，`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。UI 和 ViewModel 默认按 MainActor 思考。
- 服务共享状态优先使用 `actor` 管理。
- DTO、纯模型、静态工具、日期/格式化辅助、跨 actor 传递类型应根据需要显式标注 `nonisolated` 或保证 `Sendable` 语义清晰。
- 不要用阻塞式 I/O 或长耗时操作卡住 MainActor；从服务层异步返回后再回写 UI 状态。
- 已有防重入和过期结果丢弃逻辑要保留，例如 `RefreshTaskCoordinator` 保护刷新结果只让最新 generation 提交。
- 注释保持克制，只解释非显然的生命周期、焦点、actor 或系统 API 约束。

## UI 与窗口约定

- 菜单栏按钮左键切换主面板；右键或 Control+点击打开上下文菜单。
- `⌘,` 打开自定义设置窗口；菜单面板打开时 `⌘L` 打开日志窗口。
- 默认全局快捷键是 `⌘⇧W`，由 `GlobalHotKeySettings` 和 `GlobalHotKeyController` 管理。
- 主菜单面板可能通过 `NSPopover` 锚定 status item，也可能在锚点不可信时使用 fallback `NSPanel`。处理快捷键、屏幕选择和焦点时要保留这些分支。
- 设置窗口和日志窗口复用 `HostingWindowController` / `AuxiliaryHostingWindow` 行为。它们可以成为 key window，但不应成为 main window。
- 侧边详情面板共享 `SidePanelSupport.swift` 的定位、动画、挂载和 chrome 行为；新增侧边面板能力时优先复用共享支持代码。
- 保持现有 Liquid Glass 视觉风格，避免引入与系统菜单栏工具不一致的重装饰 UI。

## Hook、同步与数据文件

- Hook 子进程入口在 `CodexBarApp.init()` 中最先调用 `WorkflowHookEventRecorder.handleIfRequested()`；Hook 模式要快速读取 stdin 并退出，不进入普通 App 启动流程。
- CodexBar 只追加或移除属于当前 CodexBar 可执行文件的 Hook 处理器，不应删除用户已有的其他 Codex Hook。
- 本机 Hook 事件默认写入：

```text
~/Library/Application Support/CodexBar/HookEvents/
```

- 跨设备同步依赖用户开启 Codex Hook 且 iCloud 可用；只同步脱敏 daily 聚合行。同步范围变更时必须同时更新 `Docs/CrossDeviceSync.md`。
- Hook 事件口径、字段或聚合方式变更时必须同步更新 `Docs/CodexHook.md`。

## 文档同步

涉及这些行为时，需要更新对应文档：

- app-server 请求、错误处理或通信合约：`Docs/AppServer.md`
- Hook 注册、事件存储、统计口径：`Docs/CodexHook.md`
- CloudKit 同步范围、冲突处理、隐私边界：`Docs/CrossDeviceSync.md`
- 架构、启动流程、窗口焦点或模块边界：`Docs/DevelopmentGuide.md`
- 用户可见功能、安装或隐私说明：`README.md`

## 代码修改原则

- 优先贴合现有文件结构和类型职责，不为了小改动新建抽象。
- 修改 shared controller、shared service、模型解析或持久化 key 时，要考虑旧数据和降级路径。
- 处理用户设置时保持默认值、持久化 key 和旧版本迁移兼容。
- 处理窗口、菜单、快捷键、App 激活或事件监听时，要特别注意 `LSUIElement` App 的焦点行为。
- 不要把发布产物、DerivedData、临时 DMG、签名文件或个人凭据提交进仓库。

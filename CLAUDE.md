# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 写作风格

本仓库的中文文本 (提交信息; 代码注释; 文档) 统一遵守

- 禁止使用中文标点, 一律使用半角标点
- 行末禁止使用标点
- 行内标点后如果还有文字, 间隔一个英文空格
- 行内代码后尽量不要紧跟标点, 需要断句时补一个词或者使用空格再断

## 项目概述

CodexBar 是一个 macOS 菜单栏应用, 以 `LSUIElement` 方式运行, 没有 Dock 图标, 展示本机 Codex 的账号状态; 额度; Token 用量; 实时任务和工作流统计; 技术栈 Swift 6 + SwiftUI + AppKit + MVVM, 唯一外部依赖是 Sparkle 2.9.3+ (SwiftPM); 最低系统版本 macOS 15.0

Xcode 工程有两个 target: 主 App `CodexBar` 和随 App 嵌入的 root helper `CodexBarHelper` (command-line tool + LaunchDaemon); **没有测试 target**, 验证靠构建通过 + 实际运行

App Sandbox 未开启, entitlements 只声明 iCloud/CloudKit, 因为需要启动本机 `codex` 进程; 读取用户 Codex 登录状态; 写入用户级 Hook 配置

## 常用命令

```bash
# 日常编译验证 (唯一 scheme 是 CodexBar)
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build

# 格式化: 配置在 .swiftformat, 覆盖整个仓库 (Swift 6 语言模式, 4 空格缩进)
swiftformat .

# Lint: 配置在 .swiftlint.yml, included 只有 CodexBar/
# 即 Shared/; CodexBarHelper/; Scripts/ 不在 lint 范围内
swiftlint

# 发布流程 (需要 Developer ID 凭据, 不要当普通本地验证跑)
Scripts/build.sh    # Release archive + Developer ID 导出 + notarize + staple + Gatekeeper 校验
Scripts/dmg.sh      # 打包 DMG
Scripts/appcast.sh  # sign_update 签名并写入 appcast.xml

# 注销 KeepAlive LaunchDaemon; 清理前需先退出所有 CodexBar 实例
# 常用: --dry-run 只显示目标, --check 只验证临时清理 App,
#       --release-only / --debug-only 限定范围, --sign-identity 指定签名身份
Scripts/cleanup.swift --help
```

日常调试直接 `open CodexBar.xcodeproj` 用 Xcode 跑 Debug scheme; 注意 Debug 产物用的是 `app.zabrian.codexbar.debug` 这个 bundle ID, 与 Release 安装版可以共存, 排查防休眠问题时要确认自己看的是哪一套 helper

`Scripts/build.sh` 会先清空 `build/` 目录, 成功后只留最终产物 `.app` 文件; 凭据推荐用 keychain profile, 先跑一次 `xcrun notarytool store-credentials "codexbar-notary" --apple-id "<Apple ID>" --team-id "<Team ID>"` 存好, 之后构建加上 `--notary-profile codexbar-notary`

Debug 与 Release 使用不同 bundle ID, 分别是 `app.zabrian.codexbar.debug` 与 `app.zabrian.codexbar` 两个, helper 相应带 `.debug.helper` 与 `.helper` 后缀, 所以 `CodexBarHelper/` 下有两份 LaunchDaemon plist, `cleanup.swift` 也需要同时处理两套

## Git 规则

- 不要主动 push, 除非用户明确要求
- 不要回滚; 覆盖或丢弃不是你产生的未提交改动, 工作树可能是脏的
- 被要求提交时, **禁止**顺带修改任何文件内容: 不格式化; 不清理; 不补文档, 只把当前已有改动原样提交

Commit message: Conventional Commits 前缀 + 中文标题, 需要 body 时空一行后写 4 空格缩进 bullet

- 标题写成 `<type>: <中文描述>` 的形式, 不加句号; 常用 type 有 `feat` `fix` `chore` `refactor` `docs`
- 功能; 修复; 发布类提交必须写 body; 简单文档或杂项可只写标题行
- body 中多条 bullet 连续排列, bullet 之间不空行
- 命令行提交时把完整 body 放进同一个 `-m` 参数或改用 `git commit -F` 传文件, 不要为每条 bullet 单独 `-m`
- message 中禁止使用中文标点, 行末禁止使用标点, 行内标点后如果有文字则间隔一个英文空格

```text
fix: 修复 Codex 状态刷新

    - 合并设置页 onAppear 和 didBecomeActive 的重复版本探测
    - 保留当前运行版本与磁盘安装版本不一致时的更新提示
```

Tag 名 `v{MARKETING_VERSION}` 里的版本号从 Xcode build settings 读取, 使用附注 tag `git tag -a v3.x.y -m "Release v3.x.y"`

## 架构

### 启动分流 (关键设计)

`CodexBar/App/CodexBarApp.swift` 的 `init()` 最先调用 `WorkflowHookEventRecorder.handleIfRequested()`

- 带 `--hook-event` 启动 -> **Hook 子进程模式**: 从 stdin 读 JSON payload, 在 `flock` 锁内追加一行 JSONL 后立即 `exit(EXIT_SUCCESS)` 退出, 绝不初始化菜单栏 UI; 写入失败静默吞掉, 不阻断 Codex; Hook handler 超时由 `hookTimeoutSeconds` 定为 5 秒, 等锁预算据此推算为 3 秒, 两者必须一起改
- 普通启动 -> `CodexBarAppDelegate` 创建全部长期对象, 它在 `Controllers/StatusItemController.swift` 内, 再由 `StatusItemController.install()` 装配菜单栏; AppDelegate 是唯一的装配点, 新增服务在这里注入

### 三条数据链路

**链路一: app-server (额度/用量)**

`CodexStatusService` (actor) -> `CodexCLIResolver` 解析 `codex` 可执行文件, PATH 全局优先, 回退 `/Applications/ChatGPT.app` 或 `Codex.app` 内置 -> 启动 `codex app-server --listen stdio://` -> `AppServerSession` 做 stdio JSON-RPC -> 合成 `CodexQuotaSnapshot` -> `CodexStatusViewModel` 发布给 UI

- 刷新间隔 60 秒, 请求超时 20 秒, 连接最长复用 1 小时, 让后台升级的 codex 二进制有机会生效
- 主要方法有 `initialize` `account/read` `account/rateLimits/read` `account/usage/read` `config/read` `config/batchWrite` `hooks/list`
- `SIGPIPE` 被忽略, app-server 退出后写管道由 write 抛错走重建路径
- stdout 可能混有无关日志行, `AppServerSession` 先用轻量 `RPCIDEnvelope` 匹配 id 再完整解码

**链路二: Hook 统计 (历史聚合)**

Hook 子进程按天写入 `~/Library/Application Support/CodexBar/HookEvents/events/YYYY-MM-DD.jsonl` 这类文件, 主 App 的 `WorkflowService` (actor) 增量聚合出 `daily.jsonl` 与 `WorkflowSnapshot` 供热力图详情面板展示; 可选跨设备同步由 `WorkflowSyncScheduler` (唯一调度者) 与 `WorkflowSyncService` 负责, 走 `iCloud.app.zabrian.codexbar` 容器的 CloudKit private database, 只上传脱敏 daily 聚合

`WorkflowStorage` 管理的存储目录含 `events/` `daily.jsonl` `stats.lock` `maintenance.json` `Sync/` 五项; 保留期 210 天, 对原始事件文件和 daily 聚合同时生效, 清理由 `pruneExpiredEventFiles` 执行; 聚合里的会话与轮次标识额外只保留 3 天, 过期后被 compact 掉

**链路三: 实时任务, 由 `CodexActivityMonitor` 驱动**

`CodexActivityMonitor` 是菜单栏图标; 活动卡片; 通知; 触觉反馈和防休眠的**唯一任务状态来源**, 由两个 reader 供料

- `HookEventTailReader` (actor) 的 bootstrap 覆盖滚动 24 小时并作为单次事务发送, 之后按当日文件 offset 增量 tail
- `CodexSessionLifecycleReader` (actor) 增量读取 `~/.codex/sessions` 与 `archived_sessions` 下的 rollout JSONL, 只提取 turn 生命周期字段, 不解码会话或工具内容

系统唤醒时 `NSWorkspace.didWakeNotification` 会触发立即 drain 并重置生命周期解析回退

### 防休眠 (KeepAlive) 与 root helper

两套机制叠加, 职责不同

- `SystemSleepService` 用进程内 `IOPMAssertion` 建立 `PreventUserIdleSystemSleep` 断言, 只挡空闲休眠, 不需要提权; 断言名必须是 ASCII, 否则 `pmset -g assertions` 显示不出标识
- `CodexBarHelper` 是 root LaunchDaemon, 通过 XPC 接受 `setSleepDisabled` 请求, 执行 `/usr/bin/pmset -a disablesleep` 覆盖合盖休眠

链路: `KeepAliveController` (MainActor) 订阅 `activityMonitor.$snapshot` 与 `codexHookSettings.$isEnabled` -> `SMAppService.daemon(plistName:)` 注册 -> `NSXPCConnection` -> helper

关键约束

- `shouldDisableSleep` 是用户意图与依赖可用性的唯一汇合点, 要求 `isEnabled && codexHookSettings.isEnabled && hasRunningTasks && helperStatus == .enabled && !hasReachedMaximumDuration` 同时成立; **依赖不满足只让效果失效, 绝不回写用户保存的 `isEnabled`**
- helper 只做一件事; 不要给 root helper 增加网络; 任意命令执行或其他文件访问能力
- 调用方校验由 XPC 层强制; helper 启动时用 `SecCodeCopySelf` 读自身签名, 拼出形如 `anchor apple generic and certificate leaf[subject.OU] = "<team>" and identifier "<主 App identifier>"` 的 requirement 字符串, 交给 `NSXPCListener.setConnectionCodeSigningRequirement` 生效; 没有逐次连接的 audit token 检查, 改签名或改 bundle ID 会直接连不上
- 恢复哨兵放在 `/Library/Application Support/CodexBar/<machService>.state` 这个路径, **必须保持 `absent` `present` `unreadable` 三态**, 把读取失败折叠成 nil 会让恢复流程以为无需恢复, 使 `SleepDisabled=1` 永久残留; watchdog 宽限 15 秒, 哨兵自检 60 秒一次
- 切换失败按 2/4/8...256 秒重试, 列表耗尽 (约 8.5 分钟) 即放弃, 瞬时抖动能自愈, 权限类故障不该无限重试

### 通知

- `CodexNotificationService` 是集中式的 MainActor 服务, 订阅额度快照与实时活动, 负责阈值穿越判定; 去重, dedup key 落 UserDefaults; 额度重置识别; 触觉反馈和本地通知
- `NotificationSettings` 管 CodexBar 自身通知; `CodexCLINotificationSettings` 是另一回事, 它通过 app-server `config/read` 与 `config/batchWrite` 读写 Codex 自己的用户级 `config.toml`

### 并发与隔离

工程开启 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 设置, 所有类型默认 MainActor 隔离

- UI; 控制器; ViewModel; Settings; 更新类直接依赖默认隔离, 不需要额外标注
- 服务共享状态用 actor 管理, 包括 `CodexStatusService` `WorkflowService` `WorkflowSyncService` `CodexCLIVersionService` `HookEventTailReader` `CodexSessionLifecycleReader`
- DTO; 纯模型; 静态工具; 跨 actor 传递的类型必须显式标注 `nonisolated`
- 跨进程写统计文件用 `stats.lock` 加 `flock` 保护, Hook 子进程有等待上限, 主 App 无限等待; `RequestLogStorage` 用 `OSAllocatedUnfairLock`
- 非 Sendable 的管道 IO 集中在 `PipeReadBuffer` 里, `JSONLineReader` 与 `PipeDrain` 复用它
- 保留既有防重入与过期结果丢弃逻辑, 例如 `RefreshTaskCoordinator` 只让最新 generation 提交结果
- 不要用阻塞 I/O 或长耗时操作卡住 MainActor

### 错误处理原则

- 菜单面板的 `CodexFetchOutcome` 只暴露有数据; 未登录; 初始化失败三种结果, 而启动失败; 超时; 断连; 解析失败等细节全部只进日志窗口, 由 `RequestLogStorage` 保存, 上限 500 条
- 账号有效时 rate limits 和 usage 允许单独失败, 复用同账号旧缓存并标记 stale, UI 显示为半透明, 无缓存则该区域不显示; 账号变化时整体丢弃缓存避免串号
- 各 Settings 类把读取类错误与操作类错误分开存储, 定时 refresh 不能抹掉用户操作或校验的结论, 参见 `CodexHookSettings` 与 `KeepAliveController`
- Hook 子进程任何失败都静默退出, 优先保证不拖慢 Codex

## UI 与窗口约定

- 菜单栏按钮左键切换主面板; 右键或 Control+点击打开上下文菜单; `⌘,` 打开自定义设置窗口, 菜单面板打开时 `⌘L` 打开日志窗口; 默认全局快捷键 `⌘⇧W` 由 `GlobalHotKeySettings` 与 `GlobalHotKeyController` 管理
- 主面板是锚定 status item 的 `NSPopover` 弹窗, 锚点不可信时回退到 `FallbackPanelController` 提供的屏幕顶部居中 `NSPanel` 面板, 处理快捷键; 屏幕选择和焦点时要保留这两个分支
- 关闭逻辑统一由 `MenuSurfaceDismissMonitor` 管理, 淡出由 `MenuSurfaceFadeCoordinator` 负责
- 侧边详情面板 (热力图详情; 重置次数) 是主面板的 borderless nonactivating child panel, 公共能力集中在 `Controllers/SidePanelSupport.swift` 里, 含 `SidePanelContentHost` `SidePanelDrawerAnimator` panel 工厂和定位夹紧; 新增侧边面板优先复用, 不要另起一套
- 设置窗口 (通用/高级/关于三页) 和日志窗口复用 `HostingWindowController` 的行为, 可以成为 key window, 但不应成为 main window
- 视觉风格统一走 `Views/Shared/LiquidGlassStyle.swift` 这一套, 避免引入与系统菜单栏工具不一致的重装饰 UI

## Hook 配置改写约束

`~/.codex/hooks.json` 的读写全部在 `CodexHookSettings` 里完成, Codex 目录优先取 `CODEX_HOME` 环境变量, 找不到时回退真实用户 HOME 下的 `.codex` 目录

- 只识别并移除 command 同时包含当前 CodexBar 可执行路径与 `--hook-event` 的 handler, 必须保留用户已有 Hook 以及其他 App 的 Hook 和同事件下的其他 handler
- 写入前通过 app-server `config/read` 确认全局未禁用 Hook, 写入后用 `hooks/list` 验证
- 读取失败 (I/O 或 JSON 格式错误) 不提供 Hook 装没装的信息, 必须保留上次已知值, 不能当成用户关闭了 Hook

## 隐私与数据边界

改动涉及网络; 日志或同步时必须遵守

- App 只有四类出网行为, 分别是本机 app-server stdio 通信 (不算网络); 重置机会过期时间只读查询; Sparkle 更新; 用户显式开启后的 CloudKit 同步, 新增网络请求需要非常明确的理由
- 只读查询打到 `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` 这一个地址, 也是全仓库唯一的 `URLSession` 调用点, 位于 `CodexResetCreditsService` 内; Sparkle 更新走 `https://codexbar.zabrian.app/appcast.xml` 这个 feed
- 不展示 app-server stderr; 不展示或记录 Codex OAuth token 与 `auth.json` 内容; 不把原始敏感 RPC 响应写进文档
- CloudKit 只同步去掉 `sessionIds` 与 `turnIds` 的 daily 聚合, 不同步原始 Hook events; 账号; 额度或 Token 用量

## 代码修改原则

- 优先贴合现有文件结构和类型职责, 不为小改动新建抽象
- 改 shared controller; shared service; 模型解析或持久化 key 时, 要考虑旧数据和降级路径; 用户设置要保持默认值; 持久化 key 和旧版本迁移兼容
- **任何兼容性问题都必须主动询问用户, 不要自行拍板**; 只要改动会影响新旧共存就适用, 不限于旧数据迁移或丢弃; 持久化 key 改名或改结构; 老版本升上来的降级路径; 最低系统版本与 API 可用性取舍; 云端记录格式变更; 先说清影响面和几种做法的代价, 等用户选定再动手
- 处理窗口; 菜单; 快捷键; App 激活或事件监听时, 特别注意 `LSUIElement` 应用特有的焦点行为
- 注释保持克制, 只解释非显然的生命周期; 焦点; actor 或系统 API 约束; 现有注释多为解释为什么的类型, 沿用同样风格
- 改动涉及菜单面板; 窗口焦点; Hook; 同步; 通知或防休眠时, 构建通过之外还要说明应手动覆盖的交互场景; 防休眠额外要验证 App 包内 helper 与 plist 位置; 签名; 首次系统授权; 运行/等待切换和异常退出后的恢复
- 不要把发布产物; DerivedData; 临时 DMG; 签名文件或个人凭据提交进仓库

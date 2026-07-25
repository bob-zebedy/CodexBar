# CodexBar 开发指南

CodexBar 是 macOS 15+ 菜单栏应用, 使用 Swift 6, SwiftUI, AppKit 和 MVVM; 工程包含主 App 与一个随 App 嵌入的 root helper

## 工程配置

| 项目 | 配置 |
| --- | --- |
| Xcode 工程 | `CodexBar.xcodeproj` |
| Scheme | `CodexBar` |
| 最低系统 | macOS 15.0 |
| Swift | 6.0 |
| UI | SwiftUI + AppKit |
| 默认 actor isolation | `MainActor` |
| App Sandbox | 关闭 |
| Hardened Runtime | 开启 |
| 更新 | Sparkle |
| 同步 | CloudKit private database |

主 App 是 `LSUIElement`, 没有 Dock 图标和传统主窗口; App Sandbox 关闭, 以便启动本机 Codex, 读取用户 Codex 配置并管理 Hook; 应用启用 Hardened Runtime

## Targets

### CodexBar

主菜单栏应用, 负责

- app-server 通信
- 账号, 额度和 Token 用量展示
- Hook 注册, 实时任务和工作流聚合
- 通知, 设置, 日志和更新
- CloudKit 同步
- 防休眠状态控制和 helper 注册

Bundle identifier

```text
Debug:   app.zabrian.codexbar.debug
Release: app.zabrian.codexbar
```

### CodexBarHelper

随 App 嵌入的 root LaunchDaemon, 只接受签名匹配的 CodexBar XPC 客户端请求, 并使用 `pmset` 切换 `disablesleep`; 详细边界见 [阻止系统休眠](KeepAlive.md)

Bundle identifier

```text
Debug:   app.zabrian.codexbar.debug.helper
Release: app.zabrian.codexbar.helper
```

## 目录结构

```text
.
├── CodexBar/
│   ├── App/
│   │   └── CodexBarApp.swift                         SwiftUI 入口和 AppDelegate 启动装配
│   ├── Controllers/
│   │   ├── StatusItemController.swift                状态栏入口, 主面板和应用级 UI 装配
│   │   ├── FallbackPanelController.swift             状态栏锚点不可用时的备用主面板
│   │   ├── GlobalHotKeyController.swift              全局快捷键注册和事件处理
│   │   ├── ActivityCenterPanelController.swift       任务中心侧边面板
│   │   ├── HeatmapDetailPanelController.swift        热力图日期详情侧边面板
│   │   ├── NotificationOptionsPanelController.swift  通知选项侧边面板
│   │   ├── ResetCreditsPanelController.swift         手动重置机会侧边面板
│   │   ├── SidePanelSupport.swift                    侧边面板定位, 挂载, 动画和外观支持
│   │   ├── HostingWindowController.swift             SwiftUI 辅助窗口通用控制
│   │   ├── SettingsWindowController.swift            设置窗口生命周期
│   │   ├── LogWindowController.swift                 日志窗口生命周期
│   │   ├── MenuSurfaceDismissMonitor.swift           外部点击, 焦点和快捷键关闭处理
│   │   ├── MenuSurfaceFadeCoordinator.swift          主面板与侧边面板淡入淡出协调
│   │   └── ScreenGeometry.swift                      屏幕选择, 锚点和可见区域计算
│   ├── Models/
│   │   ├── CodexAccountModels.swift                  账号和订阅模型
│   │   ├── CodexQuotaModels.swift                    额度限制和时间窗口模型
│   │   ├── CodexUsageModels.swift                    Token 用量模型
│   │   ├── CodexActivityModels.swift                 实时任务和任务快照模型
│   │   ├── CodexHookEvent.swift                      Hook 原始事件模型
│   │   ├── CodexWorkflowModels.swift                 每日聚合和同步模型
│   │   ├── CodexStatusError.swift                    状态读取错误分类
│   │   ├── CodexWeekGrid.swift                       周视图和日期网格模型
│   │   ├── UsageHeatmapDay.swift                     热力图日期展示模型
│   │   ├── GlobalHotKeyShortcut.swift                快捷键组合模型
│   │   └── DateFormatter.swift                       日期解析和显示格式
│   ├── Services/
│   │   ├── CodexCLI/
│   │   │   ├── CodexCLIResolver.swift                Codex 路径和配置目录解析
│   │   │   └── CodexCLIVersionService.swift          CLI 版本和实际使用来源探测
│   │   ├── CodexStatus/
│   │   │   ├── AppServerSession.swift                app-server stdio 会话和 JSON 请求
│   │   │   ├── AppServerPipeReaders.swift            stdout 和 stderr 异步读取
│   │   │   ├── CodexStatusService.swift              账号, 额度和用量读取与缓存
│   │   │   ├── CodexStatusViewModel.swift            主面板状态和刷新协调
│   │   │   ├── CodexResetCreditsService.swift        手动重置机会过期时间查询
│   │   │   ├── CodexHookAppServerModels.swift        Hook 和配置接口 DTO
│   │   │   └── RequestLog.swift                      app-server 交互日志模型和内存存储
│   │   ├── KeepAlive/
│   │   │   ├── KeepAliveController.swift             任务驱动的防休眠和 helper 管理
│   │   │   └── SystemSleepService.swift              IOKit assertion 和系统休眠请求
│   │   ├── Notifications/
│   │   │   ├── CodexNotificationService.swift        额度, 任务和重置机会通知
│   │   │   └── NotificationSoundOption.swift         通知声音选项和资源映射
│   │   ├── Process/
│   │   │   └── ProcessTermination.swift              子进程退出和强制终止支持
│   │   ├── Settings/
│   │   │   ├── CodexHookSettings.swift               Hook 开关, 注册和验证状态
│   │   │   ├── CodexCLINotificationSettings.swift    Codex TUI 通知设置
│   │   │   ├── GlobalHotKeySettings.swift            全局快捷键持久化
│   │   │   ├── LoginItemSettings.swift               开机启动设置
│   │   │   ├── MainPanelSettings.swift               主面板任务中心设置
│   │   │   ├── MenuBarQuotaSettings.swift            菜单栏额度窗口设置
│   │   │   ├── NotificationSettings.swift            系统通知, 阈值和声音设置
│   │   │   └── WorkflowSyncSettings.swift            跨设备同步设置和状态
│   │   ├── Support/
│   │   │   └── RefreshTaskCoordinator.swift          刷新任务取消和过期结果丢弃
│   │   ├── Updates/
│   │   │   └── AppUpdater.swift                      Sparkle 更新状态和操作
│   │   └── Workflow/
│   │       ├── WorkflowHookEventRecorder.swift       Hook 子进程入口和事件写入
│   │       ├── HookEventTailReader.swift             Hook JSONL 实时增量读取
│   │       ├── CodexSessionLifecycleReader.swift     rollout 任务生命周期读取
│   │       ├── CodexActivityMonitor.swift            Hook 与 rollout 实时任务合并
│   │       ├── WorkflowService.swift                 本地聚合, 维护和手动重建
│   │       ├── WorkflowSyncService.swift             CloudKit 上传, 拉取和合并
│   │       ├── WorkflowSyncScheduler.swift           维护, 重建和同步串行调度
│   │       └── JSONLines.swift                       JSONL 编解码和稳定序列化
│   ├── Views/
│   │   ├── Menu/
│   │   │   ├── CodexStatusMenuView.swift             主面板根视图
│   │   │   ├── CodexStatusMenuSections.swift         账号, 额度, 用量和底部区域
│   │   │   ├── CodexActivityCard.swift               主面板任务卡片
│   │   │   ├── CodexActivityCenterView.swift         任务中心列表
│   │   │   ├── QuotaRow.swift                        额度窗口行
│   │   │   ├── ResetCreditsPanelView.swift           重置机会详情
│   │   │   ├── UsageHeatmap.swift                    Token 热力图
│   │   │   ├── AutoRefreshCountdownView.swift        自动刷新倒计时
│   │   │   ├── TokenCountText.swift                  Token 数量格式化视图
│   │   │   └── ScreenFrameReader.swift               SwiftUI 屏幕坐标读取
│   │   ├── Settings/
│   │   │   ├── AppSettingsView.swift                 通用, 高级和关于设置页
│   │   │   ├── CodexVersionSection.swift             Codex 路径和版本信息
│   │   │   ├── HotKeyRecorderRow.swift               快捷键录制控件
│   │   │   ├── NotificationOptionsView.swift         通知分类, 阈值和声音选项
│   │   │   ├── SettingsToggleRow.swift               设置开关通用行
│   │   │   └── SettingsIndentedRow.swift             设置缩进行布局
│   │   ├── Log/
│   │   │   └── LogView.swift                         app-server 交互日志窗口
│   │   └── Shared/
│   │       ├── LiquidGlassStyle.swift                Liquid Glass 通用样式
│   │       ├── QuotaPalette.swift                    额度颜色映射
│   │       └── PasteboardWriter.swift                剪贴板写入支持
│   └── Resources/                                    应用资源文件
├── Shared/
│   └── CodexBarHelperXPC.swift                       App 与 helper 共用的 XPC 契约
├── CodexBarHelper/
│   ├── main.swift                                    root helper 入口, XPC 和恢复逻辑
│   ├── app.zabrian.codexbar.helper.plist             Release LaunchDaemon 配置
│   └── app.zabrian.codexbar.debug.helper.plist       Debug LaunchDaemon 配置
├── Docs/
│   ├── UserGuide.md                                  用户操作和设置说明
│   ├── AppServer.md                                  app-server 通信说明
│   ├── CodexHook.md                                  Hook 和工作流统计说明
│   ├── CrossDeviceSync.md                            CloudKit 同步说明
│   ├── KeepAlive.md                                  防休眠和 root helper 说明
│   └── DevelopmentGuide.md                           架构, 构建和发布说明
├── Scripts/
│   ├── build.sh                                      Release 构建, 签名和公证
│   ├── dmg.sh                                        DMG 打包
│   ├── appcast.sh                                    Sparkle appcast 生成
│   └── cleanup.swift                                 KeepAlive helper 注销和检查
├── README.md                                         项目入口文档
├── AGENTS.md                                         编码代理项目约定
├── CLAUDE.md                                         代理入口说明
├── .swiftformat                                      SwiftFormat 配置
├── .swiftlint.yml                                    SwiftLint 配置
├── .gitignore                                        Git 忽略规则
├── appcast.xml                                       Sparkle 更新源
└── LICENSE                                           GPL-3.0 许可证
```

## 启动流程

### Hook 模式

`CodexBarApp.init()` 首先调用 `WorkflowHookEventRecorder.handleIfRequested()`; 命令行包含 `--hook-event` 时, 进程读取 stdin, 写入一条本地事件并直接退出, 不进入普通 App 生命周期

### 普通模式

1. `CodexBarApp` 安装自定义 `⌘,` 设置命令
2. `CodexBarAppDelegate` 创建共享服务, 设置对象和 ViewModel
3. `StatusItemController.install()` 创建状态栏入口, 主面板, 快捷键和刷新订阅
4. `CodexNotificationService` 订阅额度和任务变化
5. `CodexActivityMonitor` 启动 Hook 事件尾读和 rollout 生命周期读取
6. `KeepAliveController` 订阅实时任务并刷新 helper 状态

App 退出时依次卸载状态栏入口, 恢复防休眠状态并停止活动监控

## 主要数据流

| 数据 | 来源 | 处理 | 展示或输出 |
| --- | --- | --- | --- |
| 账号, 额度, Token | 本机 Codex app-server | `CodexStatusService` 读取并缓存 | 菜单栏图标, 主面板, 通知 |
| Hook 事件 | Codex 调用当前 App 的 Hook 模式 | 追加本地 JSONL | 实时任务和每日聚合 |
| rollout 生命周期 | `CODEX_HOME/sessions` 与 `archived_sessions` | 增量读取任务起点, 审批, 完成和终止 | 实时任务状态与时长 |
| 每日工作流 | 本地 Hook 事件 | `WorkflowService` 增量维护 | 热力图详情和任务统计 |
| 跨设备聚合 | CloudKit private database | `WorkflowSyncService` 缓存与合并 | 多设备工作流统计 |
| 休眠状态 | 实时运行任务 | Main App assertion + root helper | 系统电源策略 |

app-server 细节见 [Codex app-server](AppServer.md), Hook 与统计见 [Codex Hook 与工作流统计](CodexHook.md), 同步见 [跨设备同步](CrossDeviceSync.md)

## UI 与窗口

### 菜单栏入口

`StatusItemController` 是应用级装配点, 统一管理

- 状态栏图标与 tooltip
- `NSPopover` 主面板
- 无可信状态栏锚点时的 fallback `NSPanel`
- 右键上下文菜单
- 全局 Carbon hot key
- 侧边详情面板
- 设置和日志窗口

左键切换主面板; 右键或 `Control` + 左键打开上下文菜单; 全局快捷键默认 `⌘⇧W`, 打开时优先使用鼠标所在屏幕

### 主面板

主面板使用 SwiftUI, 固定宽度, 按顺序展示账号, 可选任务卡片, 额度, Token/热力图和底部状态; 数据不可用时保留账号状态和任务卡片位置, 并显示统一空状态

`MenuSurfaceDismissMonitor` 处理外部点击, `Esc`, `⌘L`, App 激活变化和 key window 变化; `⌘Space` 会短暂抑制失活关闭, `⌘Tab` 会关闭面板

### 侧边面板

热力图详情, 重置机会, 任务中心和通知选项复用 `SidePanelSupport` 的定位, 父子窗口挂载, 圆角和抽屉动画; 面板优先显示在请求侧, 空间不足时换边, 并限制在当前屏幕可见区域内

### 辅助窗口

设置和日志窗口继承 `HostingWindowController`; `AuxiliaryHostingWindow` 可以成为 key window, 但不会成为 main window; 重新打开时移动到当前 Space, 并按菜单栏所在屏幕或当前屏幕定位

设置窗口包含"通用""高级""关于"三页, 按当前内容高度调整窗口; 超过可用高度时由内部滚动视图承载

## 服务边界

### CodexStatusService

actor 持有一条 app-server stdio 会话, 负责连接复用, 认证刷新, 请求分类和同账号缓存; UI 只接收数据可用, 未登录和初始化失败三类状态

### WorkflowService

actor 负责每日聚合维护, 文件连续性检查, 保留期清理, 手动重建和同步快照合并; Hook 子进程与主 App 通过 `flock` 保护共享状态

### CodexActivityMonitor

MainActor 对象, 合并 Hook JSONL 和 rollout 生命周期, 发布统一任务快照和等待/完成 transition; 通知, 防休眠, 菜单栏状态点和任务中心都消费这份状态

### WorkflowSyncService

actor 使用 CloudKit 私有数据库, 维护设备 ID, zone 游标, 本地缓存, 上传确认 hash 和重建替换状态

### CodexNotificationService

MainActor 服务, 订阅额度快照和任务 transition, 负责通知权限, 阈值, 去重, 提示音, 触觉反馈和通知点击回调

### AppUpdater

封装 Sparkle 更新状态和设置; Feed URL, EdDSA 公钥和检查间隔来自 `Info.plist`; 自动检查间隔为 1 小时

## 并发约定

- App target 使用 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
- UI, 窗口控制器, 设置对象和 ViewModel 在 MainActor 上运行
- app-server, 聚合, CloudKit 等共享服务使用 actor 串行管理状态
- DTO, 纯模型, 格式化工具和跨 actor 数据根据用途标注 `nonisolated` 或满足 `Sendable`
- 管道读取器和锁封装自行保护非 Sendable 底层对象
- `RefreshTaskCoordinator` 和各类 generation 标记用于取消旧任务并丢弃过期结果
- 工作流维护, 同步和手动重建由 `WorkflowSyncScheduler` 串行调度
- 长时间文件和进程操作不应阻塞 MainActor

## 本地数据与设置

主要文件位置

| 路径 | 内容 |
| --- | --- |
| `${CODEX_HOME}/auth.json` | Codex 认证文件, 只用于本机手动重置机会查询 |
| `${CODEX_HOME}/hooks.json` | Codex Hook 配置 |
| `${CODEX_HOME}/sessions/` | Codex rollout 会话文件, 只增量读取生命周期字段 |
| `~/Library/Application Support/CodexBar/HookEvents/` | Hook 原始事件, 每日聚合和同步缓存 |
| `/Library/Application Support/CodexBar/` | root helper 恢复哨兵 |

用户设置通过 `UserDefaults`, `SMAppService`, Sparkle 和 Codex app-server 分别持久化; 修改设置 key 时需要保留缺省值和已有数据的兼容读取

主要缺省值

| 设置 | 默认值 |
| --- | --- |
| 全局快捷键 | `⌘⇧W` |
| 菜单栏额度指示 | 开启, 主额度窗口 |
| 主面板任务中心 | 开启 |
| 防休眠最长时限 | 12 小时 |
| 低额度阈值 | 10% |
| 长任务通知阈值 | 60 秒 |
| 跨设备同步 | 关闭 |

## 网络范围

除本机 app-server 通信外, 主 App 只在以下场景访问网络

- 查询手动重置机会过期时间
- Sparkle 更新检查和下载
- 用户开启跨设备同步后的 CloudKit private database 请求

root helper 不执行网络请求

## 构建与检查

日常编译

```bash
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build
```

也可以直接用 Xcode 打开 `CodexBar.xcodeproj`

当前工程没有独立测试 target; 修改后至少完成一次构建, 并按影响范围手动检查

- 菜单栏左键, 右键和全局快捷键
- popover 与 fallback panel 的屏幕和焦点行为
- `⌘,`, `⌘L`, 设置和日志窗口
- Hook 注册, 验证, 事件写入和任务状态
- CloudKit 开关, 同步状态和多设备合并
- 防休眠授权, 运行/等待切换, 上限和异常恢复

SwiftLint 配置位于 `.swiftlint.yml`, 检查范围为 `CodexBar/`

## 发布脚本

### 构建与公证

```bash
Scripts/build.sh --notary-profile <profile>
```

脚本执行 Release archive, Developer ID 导出, 签名验证, 公证, staple 和 Gatekeeper 校验; 默认清理 `build/`, 成功后只保留最终 `.app`; 没有发布凭据时可用 `--skip-notarization`, 但产物不是完整发布包

### DMG

```bash
Scripts/dmg.sh [App.app] [Output.dmg]
```

脚本复制 App, 创建 Applications 别名, 写入 Finder 布局, 并输出压缩 DMG; 默认文件名包含 `MARKETING_VERSION`

### Sparkle appcast

```bash
Scripts/appcast.sh [CodexBar-vX.Y.Z.dmg]
```

脚本读取 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`, 调用 Sparkle `sign_update`, 在 `appcast.xml` 顶部写入当前版本条目, 并校验 XML; 默认下载地址和发布说明地址来自脚本环境变量

### Helper 清理

```bash
Scripts/cleanup.swift [options]
```

脚本只注销 CodexBar Debug 和 Release KeepAlive LaunchDaemon, 并关闭对应防休眠偏好; 运行前需要退出所有 CodexBar 实例

## 发布检查

发布包至少确认

1. 主 App, helper 和 Sparkle framework 签名有效
2. App 包内 helper 与 LaunchDaemon plist 路径正确
3. `Info.plist` 的 Sparkle feed 和公钥有效
4. CloudKit entitlement 使用 `iCloud.app.zabrian.codexbar`
5. DMG 可挂载并可将 App 拖入 `/Applications`
6. appcast 的版本, build, 下载地址, 文件长度和 EdDSA 签名匹配产物

# UI 与应用生命周期

## LSUIElement 约束

CodexBar 在 [`Info.plist`](../../CodexBar/Resources/Info.plist) 中配置为 `LSUIElement`

它没有 Dock 图标和普通主窗口生命周期。菜单栏，popover，浮动面板，设置窗口和通知点击都必须显式处理 App 激活与焦点。

普通 SwiftUI Window 的默认行为不足以覆盖这些场景，因此 UI 采用 SwiftUI 内容加 AppKit Controller 的组合。

## 服务装配

[`StatusItemController.swift`](../../CodexBar/Controllers/StatusItemController.swift) 同时包含 AppDelegate 和菜单栏主控制器。

AppDelegate 负责：

- 创建长期 service，ViewModel 和 settings
- 建立 monitor 与通知，防睡眠的观察关系
- 启动状态刷新和 Hook 活动读取
- 创建状态栏控制器
- 安装全局快捷键
- 配置 Sparkle 更新
- 在 App 终止时协调防睡眠释放

对象由 composition root 显式持有，避免 SwiftUI View 生命周期意外销毁长期服务。

## 状态栏图标

状态图标综合 app-server 加载状态，菜单栏额度设置和任务活动快照。

任务状态点的优先级是：

```text
等待批准 > 运行中 > 最近完成 > 最近中断 > 空闲
```

图标生成结果按输入状态缓存，避免每次定时刷新重复绘制。非激活或不可用状态通过 alpha 表达。

左键打开主面板。右键或按住 Control 点击打开上下文菜单。

## 主面板

主面板优先使用 `NSPopover`，`behavior` 设为 `applicationDefined`

CodexBar 自己管理 dismiss，原因包括：

- 主面板可以打开设置，日志和侧边详情面板
- `LSUIElement` 激活切换会制造普通 transient popover 的误关闭
- 侧边面板需要被视为同一个交互表面
- 关闭动画需要统一淡出

[`MenuSurfaceDismissMonitor.swift`](../../CodexBar/Controllers/MenuSurfaceDismissMonitor.swift) 监听全局和本地事件，[`MenuSurfaceFadeCoordinator.swift`](../../CodexBar/Controllers/MenuSurfaceFadeCoordinator.swift) 统一协调关闭动画。

## Fallback panel

全局快捷键触发时，状态栏按钮的屏幕位置可能不可用或不可信。此时 [`FallbackPanelController.swift`](../../CodexBar/Controllers/FallbackPanelController.swift) 在鼠标所在屏幕显示浮动面板。

popover 和 fallback panel 承载同一份 SwiftUI 内容和状态。业务逻辑不能依赖具体容器类型。

## 侧边详情面板

主面板可以打开：

- 活跃度热力图详情
- Reset Credits 详情
- 活动中心

这些面板互斥，打开一个时关闭其他侧边面板。它们会把自己的屏幕区域加入主表面的额外 hit region，用户在主面板和侧边面板之间移动或点击时不会触发误关闭。

相关控制器包括：

- [`HeatmapDetailPanelController.swift`](../../CodexBar/Controllers/HeatmapDetailPanelController.swift)
- [`ResetCreditsPanelController.swift`](../../CodexBar/Controllers/ResetCreditsPanelController.swift)
- [`ActivityCenterPanelController.swift`](../../CodexBar/Controllers/ActivityCenterPanelController.swift)
- [`SidePanelSupport.swift`](../../CodexBar/Controllers/SidePanelSupport.swift)

## 设置和日志窗口

设置与日志使用独立 `NSWindowController`

`LSUIElement` App 打开普通窗口时需要暂时允许窗口成为 key，激活 App，再把焦点交给目标控件。关闭后恢复菜单栏 App 的非前台行为。

焦点恢复使用约 120 ms 延迟，给 AppKit 完成窗口和 activation 状态切换。这类延迟属于系统生命周期协调，不能简单删除为同步调用。

上下文菜单 action 会延迟到 menu tracking 结束后执行，避免 AppKit 仍在菜单事件循环中时创建或激活窗口。

## 全局快捷键

[`GlobalHotKeyController.swift`](../../CodexBar/Controllers/GlobalHotKeyController.swift) 使用 Carbon Hot Key API。

快捷键约束：

- 至少包含 2 个修饰键
- 拒绝 `Command-Space`
- 拒绝 `Command-Tab`
- 系统注册冲突时回滚到之前可用设置
- 设置变更立即重新注册

Carbon API 适合无 Dock 菜单栏 App，不需要安装全局键盘事件 tap 或请求输入监控权限。

## 自动刷新与面板打开

app-server 状态默认每 60 秒刷新。面板打开时会安排约 160 ms 的延迟刷新，先完成动画和焦点切换，再更新数据。

主面板显示倒计时。手动刷新由双击触发，避免单击状态栏本身与按钮动作产生歧义。

刷新协调器合并并发触发，防止定时器，面板打开和用户操作重复创建相同请求。

## 本地化和格式化

简体中文和英文界面字符串位于 [`Localizable.xcstrings`](../../CodexBar/Resources/Localizable.xcstrings)

日期，数字和百分比使用系统自动更新 locale。不在业务模型中固定中文格式，也不把本地化后的字符串作为状态机输入。

## 自动更新

[`AppUpdater.swift`](../../CodexBar/Services/Updates/AppUpdater.swift) 封装 Sparkle：

- appcast URL 来自 App 配置
- 自动检查间隔为 3600 秒
- 更新 UI 由设置页和上下文菜单触发
- CodexBarHelper 变化在更新后单独执行 fingerprint 和注册状态检查

发布脚本需要 Developer ID，签名和公证凭据，不属于日常本地构建流程。

## 手动验证矩阵

- 左键打开主面板，右键和 Control 点击打开上下文菜单
- 点击主面板外部正确关闭，点击侧边面板不误关闭
- 热力图，Reset Credits 和活动中心保持互斥
- 全局快捷键在状态栏锚点有效和无效场景都能打开面板
- 从通知点击激活 App 并打开面板
- 设置窗口首次打开，关闭和再次打开时焦点正确
- 上下文菜单打开设置或日志时没有焦点丢失
- 多显示器和不同菜单栏位置下 fallback panel 位于鼠标屏幕
- 快捷键冲突后原快捷键仍可用
- 面板打开刷新不会造成动画卡顿或重复请求

## 关键源码

- [`StatusItemController.swift`](../../CodexBar/Controllers/StatusItemController.swift)
- [`FallbackPanelController.swift`](../../CodexBar/Controllers/FallbackPanelController.swift)
- [`MenuSurfaceDismissMonitor.swift`](../../CodexBar/Controllers/MenuSurfaceDismissMonitor.swift)
- [`MenuSurfaceFadeCoordinator.swift`](../../CodexBar/Controllers/MenuSurfaceFadeCoordinator.swift)
- [`GlobalHotKeyController.swift`](../../CodexBar/Controllers/GlobalHotKeyController.swift)
- [`SettingsWindowController.swift`](../../CodexBar/Controllers/SettingsWindowController.swift)
- [`LogWindowController.swift`](../../CodexBar/Controllers/LogWindowController.swift)
- [`CodexStatusMenuView.swift`](../../CodexBar/Views/Menu/CodexStatusMenuView.swift)

# UI 与应用生命周期

## LSUIElement 约束

CodexBar 在 [`Info.plist`](../../CodexBar/Resources/Info.plist) 中配置为 `LSUIElement`

它没有 Dock 图标和普通主窗口生命周期。菜单栏、popover、浮动面板、设置窗口和通知点击都必须显式处理 App 激活与焦点。

普通 SwiftUI Window 的默认行为不足以覆盖这些场景，因此 UI 采用 SwiftUI 内容加 AppKit Controller 的组合。

## UI 架构的分工

SwiftUI 负责声明内容，AppKit 负责窗口和事件生命周期：

| 层 | 负责 | 不负责 |
| --- | --- | --- |
| SwiftUI View | 布局、数据展示、用户意图回调 | 创建长期服务、决定 key window、安装全局事件监听 |
| ViewModel 和 Settings | 发布稳定快照、保存用户设置 | 持有窗口或判断屏幕坐标 |
| AppKit Controller | popover, panel, window, focus, event monitor | 重新实现业务状态机 |
| AppDelegate | 组装和持有长期对象 | 承载具体视图布局 |

这个边界让同一份菜单内容可以装入 `NSPopover` 或 fallback `NSPanel`，同时避免 SwiftUI View 因 identity 变化而销毁 monitor、XPC 或通知服务。

## `LSUIElement` 下的 3 类焦点

开发时需要区分：

- App 是否 active
- 某个 window 是否 key
- 菜单表面是否逻辑上 presented

这 3 个状态不会自动同步。例如 Command-Space 会让 App resign active，但用户可能只是临时打开 Spotlight，不希望菜单立即消失。设置窗口可能已经可见，但菜单关闭动画期间不应抢回 key 造成闪烁。

因此代码不使用 `NSApp.isActive` 作为菜单唯一真相，而是维护显式的 menu surface 状态和当前容器，再由事件监听器协调 activation。

## 服务装配

[`CodexBarAppDelegate.swift`](../../CodexBar/Controllers/CodexBarAppDelegate.swift) 是普通模式的 composition root，[`StatusItemController.swift`](../../CodexBar/Controllers/StatusItemController.swift) 只负责菜单栏和相关窗口编排。

AppDelegate 负责：

- 创建长期 service, ViewModel 和 settings
- 建立 monitor 与通知、防睡眠的观察关系，并装配自动重置状态机
- 启动状态刷新和 Hook 活动读取
- 创建状态栏控制器
- 安装全局快捷键
- 配置 Sparkle 更新
- 在 App 终止时协调自动重置唤醒计划取消和防睡眠释放

对象由 composition root 显式持有，避免 SwiftUI View 生命周期意外销毁长期服务。

### 启动顺序为什么重要

普通模式的装配顺序体现依赖关系：

```text
创建 settings 和数据服务
  -> 建立 ViewModel
  -> 创建 status item 和窗口 controller
  -> 启动通知与自动重置副作用
  -> 启动 activity monitor 与 keep-alive 协调
  -> 启动周期刷新与更新服务
```

通知和防睡眠只消费 monitor 已发布的快照或转场，不反向控制 reader。Controller 通过闭包连接这些服务，从而避免服务层依赖 AppKit 容器。

终止时顺序反转，但 helper 系统状态是例外。AppDelegate 先异步确认自动重置唤醒计划已经取消，并确认防睡眠 lease 已释放，全部成功后才允许进程终止。详细事务见 [防睡眠系统](sleep-prevention.md)

## 状态栏图标

状态图标综合 app-server 加载状态、菜单栏额度设置和任务活动快照。

任务状态点的优先级是：

```text
等待批准 > 运行中 > 最近完成 > 最近中断 > 空闲
```

图标生成结果按输入状态缓存，避免每次定时刷新重复绘制。非激活或不可用状态通过 alpha 表达。

### 图像状态与 tooltip 状态分离

`StatusIconState` 同时含图像输入和 tooltip 输入，但 `renderState` 只保留真正影响像素的字段：

- 活跃任务持续时间每分钟变化，只更新 tooltip
- 额度过期但仍展示缓存时，图标和进度使用降低后的 alpha
- 指示点或额度条显隐变化时才启动约 0.18 秒的 10 帧动画
- 新渲染状态到达时取消旧动画，每帧再次确认目标状态仍是当前状态

如果直接对完整状态做 `NSImage` 重绘，每次计时文字变化都会打断动画并增加菜单栏绘制。将 render identity 显式建模是一个小而重要的性能边界。

无状态点和额度条时图标保持 template image，让系统根据浅色、深色和菜单栏状态自动着色。一旦加入自定义颜色或进度条就使用显式颜色绘制。

tooltip 只在存在实时任务持续时间时启动 60 秒计时器，空闲时不保留永久 timer。App 还把 `NSInitialToolTipDelay` 调整为 500 ms，让菜单栏这种小点击目标的状态解释更容易被发现。

左键打开主面板。右键或按住 Control 点击打开上下文菜单。

## 主面板

主面板优先使用 `NSPopover`, `behavior` 设为 `applicationDefined`

CodexBar 自己管理 dismiss，原因包括：

- 主面板可以打开设置、日志和侧边详情面板
- `LSUIElement` 激活切换会制造普通 transient popover 的误关闭
- 侧边面板需要被视为同一个交互表面
- 关闭动画需要统一淡出

[`MenuSurfaceDismissMonitor.swift`](../../CodexBar/Controllers/MenuSurfaceDismissMonitor.swift) 监听全局和本地事件，[`MenuSurfaceFadeCoordinator.swift`](../../CodexBar/Controllers/MenuSurfaceFadeCoordinator.swift) 统一协调关闭动画。

### 为什么需要显式开合状态机

`menuSurfaceState` 有 4 个状态：

```text
hidden -> opening -> shown -> closing -> hidden
```

它解决快速重复点击产生的中间态：

- `opening` 或 `shown` 时再次 toggle 进入关闭
- `closing` 时再次 toggle 先完成旧关闭，再打开新表面
- 关闭开始后取消延迟刷新和旧动画
- 非动画关闭会直接完成状态收口，不等待不会发生的 animation completion

只检查 `popover.isShown` 不足以表示 opening 或 fade-out 中的逻辑状态，也无法同时覆盖 fallback panel。

### dismiss 规则为什么由一个监听器管理

主面板的允许点击区域是一个集合：

```text
当前菜单窗口 + status item 按钮 + 所有已显示侧边面板
```

本地 monitor 处理 App 内鼠标和键盘，global monitor 处理其他 App 上的鼠标点击，workspace 和 window observer 处理激活变化。任一入口最后都调用同一 `onDismiss`

特殊规则包括：

- Escape 消费事件并关闭
- Command-Tab 允许系统切换，同时关闭面板
- Command-Space 短暂抑制 activation dismiss，避免打开 Spotlight 时误关
- 点击后重新固定 `NSVisualEffectView` 为 inactive，避免 AppKit 自动强调背景导致明暗跳变
- 初次安装 observer 后 `Task.yield()` 再补一次窗口获取和聚焦，覆盖 popover window 尚未挂载的时机

这些规则应作为一个交互表面整体修改。只给某个侧边 panel 单独添加 event monitor 会制造监听顺序和重复关闭问题。

### 淡入淡出作用在内容而不是窗口

popover 的系统窗口由 AppKit 管理，直接动画窗口 alpha 容易与系统显示状态冲突。`MenuSurfaceFadeCoordinator` 对活动容器的 content view 做动画，完成后再调用统一 close。

关闭期间辅助窗口暂时拒绝 `makeKey()`。否则原本已打开的设置或日志窗口可能在菜单 fade-out 的几帧里突然跳到前面。

## Fallback panel

全局快捷键触发时，状态栏按钮的屏幕位置可能不可用或不可信。此时 [`FallbackPanelController.swift`](../../CodexBar/Controllers/FallbackPanelController.swift) 在鼠标所在屏幕显示浮动面板。

popover 和 fallback panel 承载同一份 SwiftUI 内容和状态。业务逻辑不能依赖具体容器类型。

### 锚点为何需要可信度检查

全局快捷键可能在 status item 尚未完成布局、菜单栏位于另一块屏幕，或系统暂时不给出 button window 时触发。代码不会只检查 button 非 nil，还验证：

- window 和 screen 存在
- button 没有隐藏且 bounds 非空
- 转换后的屏幕 rect 有效且至少为 1 point
- rect 与目标屏幕 frame 在 1 point 容差内相交

只有全部成立才使用 popover 箭头。否则 fallback panel 放到鼠标所在屏幕。这避免 popover 被 AppKit 放到错误显示器或完全不可见的位置。

fallback panel 在展示前根据 SwiftUI fitting size 和目标屏幕可见区域约束尺寸。坐标计算集中在 `ScreenGeometry`，因为 AppKit 使用左下角原点，SwiftUI 局部布局和多显示器 frame 很容易混用。

## 侧边详情面板

主面板可以打开：

- 活跃度热力图详情
- Reset Credits 详情
- 活动中心

这些面板互斥，打开一个时关闭其他侧边面板。它们会把自己的屏幕区域加入主表面的额外 hit region，用户在主面板和侧边面板之间移动或点击时不会触发误关闭。

所有详情面板实现 `MenuSideDetailPanel` 并登记在 `sideDetailPanels` 数组。互斥关闭、主表面关闭和 hit testing 都遍历同一份名册。

这比在每对面板之间写互相关闭更可扩展。新增第 4 个面板时只需要加入名册，不需要补齐 6 对互斥关系。

hover 类型的热力图面板在打开其他面板前可以渐隐，点击类型的面板通常立即关闭旧面板。这是为了避免同一屏幕位置出现两个反向滑动动画叠加。

相关控制器包括：

- [`HeatmapDetailPanelController.swift`](../../CodexBar/Controllers/HeatmapDetailPanelController.swift)
- [`ResetCreditsPanelController.swift`](../../CodexBar/Controllers/ResetCreditsPanelController.swift)
- [`ActivityCenterPanelController.swift`](../../CodexBar/Controllers/ActivityCenterPanelController.swift)
- [`SidePanelSupport.swift`](../../CodexBar/Controllers/SidePanelSupport.swift)

## 设置和日志窗口

设置与日志由独立的 `HostingWindowController` 管理 `NSWindow`

`LSUIElement` App 打开普通窗口时需要暂时允许窗口成为 key、激活 App，再把焦点交给目标控件。关闭后恢复菜单栏 App 的非前台行为。

焦点恢复使用约 120 ms 延迟，给 AppKit 完成窗口和 activation 状态切换。这类延迟属于系统生命周期协调，不能简单删除为同步调用。

上下文菜单 action 会延迟到 menu tracking 结束后执行，避免 AppKit 仍在菜单事件循环中时创建或激活窗口。

### 辅助窗口的持有和定位

`HostingWindowController` 懒创建并长期复用单个 window：

- `isReleasedWhenClosed = false`，关闭只隐藏，下次保留窗口对象和 SwiftUI 状态
- `.moveToActiveSpace`，重开时跟随当前 Space，不把用户切回旧桌面
- 优先在 status item 所在屏幕居中，再退到 window screen 或 main screen
- miniaturized 窗口先 deminiaturize 再激活

设置窗口的高度随当前 tab 内容变化，但固定上边缘并限制到屏幕 visible frame。固定上边缘可以减少切换 tab 时整窗上下漂移，让标题栏保持稳定视觉锚点。

通知、自动重置和防睡眠的二级设置面板按需创建。控制器一旦创建就会长期订阅内容高度变化，如果 App 启动时预建所有面板，从未使用的 UI 也会一直参与更新。

自动重置与防睡眠从关闭切换为开启时，`AppSettingsView` 使用 `HelperFeatureConfirmation` 显示统一确认框。确认框按 `KeepAliveController.HelperStatus` 组合 Helper 提示与对应功能说明，用户确认后才调用设置对象写入开启状态。已开启设置行在 `.requiresApproval` 状态显示 `打开系统设置` 按钮。

二级设置入口使用各自的可用性结论：

- 通知读取 `NotificationSettings.canShowOptions`
- 自动重置要求 `AutoResetSettings.isEnabled` 且 `KeepAliveController.helperStatus == .enabled`
- 防睡眠读取 `KeepAliveController.canShowOptions`

入口条件失效时设置页发送对应的 `close` 动作，避免不可用的子面板继续显示。主开关关闭时，自动重置和防睡眠设置行不显示状态说明。

### 120 ms 焦点恢复不是业务延迟

菜单关闭时 `AuxiliaryHostingWindow` 暂时把 `allowsKeyFocus` 设为 false。关闭完成后等待约 120 ms 再恢复。

这段时间给 AppKit 完成 popover order-out, activation 和 key window 重算。删除延迟可能只在开发机上偶尔复现设置窗口闪前，因此应把它视为系统事件排序约束，而不是可以随意优化掉的等待。

右键菜单 action 也要等 `menuDidClose` 后通过主队列执行。menu tracking 是嵌套事件循环，在其中同步创建窗口会得到不稳定的 activation 顺序。

## 全局快捷键

[`GlobalHotKeyController.swift`](../../CodexBar/Controllers/GlobalHotKeyController.swift) 使用 Carbon Hot Key API。

快捷键约束：

- 至少包含 2 个修饰键
- 拒绝 `Command-Space`
- 拒绝 `Command-Tab`
- 系统注册冲突时回滚到之前可用设置
- 设置变更立即重新注册

Carbon API 适合无 Dock 菜单栏 App，不需要安装全局键盘事件 tap 或请求输入监控权限。

注册新快捷键采用先试后换：

1. 为候选快捷键安装临时 handler 和 hot key
2. 注册成功后才释放当前 registration
3. 注册失败时清理候选资源并恢复设置中的旧值

如果先注销旧快捷键，一次冲突会让用户同时失去新旧两组按键。`GlobalHotKeyRegistration` 在显式 invalidate 和 deinit 中都清理 Carbon 引用，避免重注册泄漏 handler。

至少两个修饰键降低误触概率。Command-Space 和 Command-Tab 被拒绝，因为它们属于核心系统导航，即使注册 API 某次允许也不应抢占。

## 自动刷新与面板打开

app-server 状态默认每 60 秒刷新。面板打开时会安排约 160 ms 的延迟刷新，先完成动画和焦点切换，再更新数据。

主面板显示倒计时。手动刷新由双击触发，避免单击状态栏本身与按钮动作产生歧义。

刷新协调器合并并发触发，防止定时器、面板打开和用户操作重复创建相同请求。

面板打开时 Hook 统计立即从本地缓存刷新，app-server 请求延后约 160 ms。前者便宜且能快速填充内容，后者可能启动进程或发协议请求，放在开场动画之后可减少首帧卡顿。

`refreshIfNeeded` 仍会执行 freshness 合并，160 ms 不是绕过协调器的第二套刷新路径。面板在等待期间关闭时 task 被取消，不再为不可见 UI 发请求。

## 修改 UI 生命周期时的检查顺序

1. 确定变化属于 SwiftUI 内容还是 AppKit 容器生命周期
2. 检查 popover 和 fallback panel 是否共用相同行为
3. 检查 opening 和 closing 中间态，不只验证稳定状态
4. 检查点击区域是否需要加入 extra surface
5. 检查 App active、key window 和逻辑 presented 是否可能分离
6. 检查任务或 timer 在关闭和 uninstall 时是否取消
7. 在多显示器、多 Space 和无可信 status item anchor 下验证
8. 从通知点击、全局快捷键和右键菜单 3 个入口分别打开

## 本地化和格式化

简体中文和英文界面字符串位于 [`Localizable.xcstrings`](../../CodexBar/Resources/Localizable.xcstrings)

日期、数字和百分比使用系统自动更新 locale。不在业务模型中固定中文格式，也不把本地化后的字符串作为状态机输入。

## 自动更新

[`AppUpdater.swift`](../../CodexBar/Services/Updates/AppUpdater.swift) 封装 Sparkle：

- appcast URL 来自 App 配置
- 自动检查间隔为 3600 秒
- 更新 UI 由设置页和上下文菜单触发
- CodexBarHelper 变化在更新后单独执行 fingerprint 和注册状态检查

发布脚本需要 Developer ID、签名和公证凭据，不属于日常本地构建流程。

## 手动验证矩阵

- 左键打开主面板，右键和 Control 点击打开上下文菜单
- 点击主面板外部正确关闭，点击侧边面板不误关闭
- 热力图、Reset Credits 和活动中心保持互斥
- 全局快捷键在状态栏锚点有效和无效场景都能打开面板
- 从通知点击激活 App 并打开面板
- 设置窗口首次打开、关闭和再次打开时焦点正确
- 通知、自动重置和防睡眠子面板互斥，顶边对齐对应设置行，内容变化后高度正确
- 上下文菜单打开设置或日志时没有焦点丢失
- 多显示器和不同菜单栏位置下 fallback panel 位于鼠标屏幕
- 快捷键冲突后原快捷键仍可用
- 面板打开刷新不会造成动画卡顿或重复请求

## 关键源码

- [`CodexBarAppDelegate.swift`](../../CodexBar/Controllers/CodexBarAppDelegate.swift)
- [`StatusItemController.swift`](../../CodexBar/Controllers/StatusItemController.swift)
- [`FallbackPanelController.swift`](../../CodexBar/Controllers/FallbackPanelController.swift)
- [`MenuSurfaceDismissMonitor.swift`](../../CodexBar/Controllers/MenuSurfaceDismissMonitor.swift)
- [`MenuSurfaceFadeCoordinator.swift`](../../CodexBar/Controllers/MenuSurfaceFadeCoordinator.swift)
- [`GlobalHotKeyController.swift`](../../CodexBar/Controllers/GlobalHotKeyController.swift)
- [`SettingsWindowController.swift`](../../CodexBar/Controllers/SettingsWindowController.swift)
- [`LogWindowController.swift`](../../CodexBar/Controllers/LogWindowController.swift)
- [`CodexStatusMenuView.swift`](../../CodexBar/Views/Menu/CodexStatusMenuView.swift)

# UI 与应用生命周期

简体中文 | [English](../en/DeveloperGuide/ui-and-lifecycle.md)

## LSUIElement 约束

CodexBar 在 [`Info.plist`](../../CodexBar/Resources/Info.plist) 中配置为 `LSUIElement`

它没有 Dock 图标和普通主窗口生命周期。菜单栏、popover、浮动面板、设置窗口和通知点击都必须显式处理 App 激活与焦点。

UI 使用 SwiftUI 声明内容，由 AppKit Controller 管理窗口。

## `LSUIElement` 下的 3 类焦点

开发时需要区分：

- App 是否 active
- 某个 window 是否 key
- 菜单表面是否逻辑上 presented

这 3 个状态不会自动同步。例如 Command-Space 会让 App resign active，但用户可能只是临时打开 Spotlight，不希望菜单立即消失。设置窗口可能已经可见，但菜单关闭动画期间不应抢回 key 造成闪烁。

因此代码不使用 `NSApp.isActive` 作为菜单唯一真相，而是维护显式的 menu surface 状态和当前容器，再由事件监听器协调 activation。

## 服务装配

[`CodexBarAppDelegate.swift`](../../CodexBar/Controllers/CodexBarAppDelegate.swift) 是普通模式的 composition root，[`StatusItemController.swift`](../../CodexBar/Controllers/StatusItemController.swift) 只负责菜单栏和相关窗口编排。

### 启动顺序

普通模式的装配顺序体现依赖关系：

```text
创建 settings、数据服务、ViewModel 和更新服务
  -> 创建并安装 StatusItemController
      -> 装配菜单栏、观察者和快捷键
      -> 对账 Hook 并启动周期刷新
  -> 启动通知与自动重置
  -> 连接异常会话保护回调
  -> 启动 activity monitor 与 keep-alive 协调
```

通知和防睡眠只消费 monitor 已发布的快照或转场，不反向控制 reader。Controller 通过闭包连接这些服务，从而避免服务层依赖 AppKit 容器。

终止时顺序反转，但 helper 系统状态是例外。AppDelegate 先异步确认自动重置唤醒计划已经取消，并确认防睡眠 lease 已释放，全部成功后才允许进程终止。详细事务见 [防睡眠系统](sleep-prevention.md)

## 状态栏图标

状态图标综合 app-server 加载状态、菜单栏额度设置和任务活动快照。

图标优先级是：

```text
账户异常 > 等待批准 > 运行中 > 最近 30 秒内的完成或终止 > 空闲
```

`CodexActivitySnapshot.statusItemActivity(at:)` 在没有活跃任务时按结束时间选择最新终态。`StatusItemController` 按结束时间加 30 秒安排到期任务，到期后恢复普通人形；系统唤醒时按当前时间重算，状态变化和卸载时取消旧任务。

### 分离图标与 tooltip 状态

`StatusIconState` 保存活动和额度输入。`StatusItemIconPresentation` 只发布影响图像的符号名称、额度、显隐和缓存标记，相同渲染状态不会重复发布：

- 活跃任务持续时间每分钟变化，只更新 tooltip
- 额度过期但仍展示缓存时，图标和进度使用降低后的 alpha
- `StatusItemIconView` 在符号名称变化时使用 `.replace.magic(fallback: .downUp.byLayer)` 非重复替换动画
- 额度显隐在 0.3 秒内将彩色圆弧从零绘制到当前额度，或从当前额度收回到零，底轨独立淡入淡出
- 人物按符号基线对齐，隐藏额度时恢复正常大小；大小和位置在 0.2 秒内过渡
- 关闭额度时保留最后的额度和配色供收回动画使用，零额度与缺失额度保持不同语义
- 初次渲染和唤醒重算时不播放过渡动画

SwiftUI 视图持续挂载在原生 `NSStatusBarButton` 中，透明图片用于系统自适应占位。图标使用系统前景色，宿主视图不接受焦点或鼠标命中，左右键仍交给原按钮处理。

tooltip 在存在活跃任务时每 60 秒更新，空闲时停止计时。`NSInitialToolTipDelay` 为 500 ms。

左键打开主面板。右键或按住 Control 点击打开上下文菜单。

## 主面板

主面板优先使用 `NSPopover`，`behavior` 设为 `applicationDefined`，`animates` 设为 `false`

[`MenuSurfaceDismissMonitor.swift`](../../CodexBar/Controllers/MenuSurfaceDismissMonitor.swift) 监听鼠标、键盘和激活事件，通过 `onDismiss` 请求关闭。[`MenuSurfaceFadeCoordinator.swift`](../../CodexBar/Controllers/MenuSurfaceFadeCoordinator.swift) 执行淡入淡出，`StatusItemController` 通过 `NSPopoverDelegate` 接收 popover 的实际关闭回调。

### 开合状态机

`menuSurfaceState` 有 4 个状态：

```text
hidden -> opening -> shown -> closing -> hidden
```

各状态的操作如下：

- `opening` 或 `shown` 时再次 toggle 进入关闭
- `closing` 时再次 toggle 先完成旧关闭，再打开新表面
- 关闭开始后取消延迟刷新和旧动画
- 非动画关闭直接完成状态清理

`activeMenuSurface` 记录当前容器，取值为 `none`、`popover` 或 `fallbackPanel`。主动关闭容器前先将其设为 `none`

`popoverDidClose` 只处理当前 popover 已关闭的通知，并关闭该宿主的动画许可。当前容器仍为 `popover` 时，它调用 `completeMenuSurfaceClose`，取消待执行任务、收起侧边面板、移除事件监听、结束展示状态并安排辅助窗口焦点恢复。

### 关闭事件监听

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

### 淡入淡出与完成任务

`MenuSurfaceFadeCoordinator` 同时调整活动容器的内容视图和窗口透明度，淡入为 0.24 秒，淡出为 0.18 秒。控制器只保存一个完成任务；新动画开始前取消旧任务，任务等待结束后检查取消状态，再标记已显示或完成关闭。

关闭期间设置和日志窗口暂时拒绝 `makeKey()`，关闭完成后约 120 ms 恢复。完成任务弱引用当次窗口，关闭后恢复内容视图和窗口透明度。

### 内容动画与展示状态

popover 和备用面板分别持有 `MenuSurfaceAnimationState`。展示前将 `allowsAnimations` 设为 `true`，淡出期间保持开启，实际关闭后设为 `false`

`CodexStatusMenuView` 在动画许可关闭时，将根视图事务的 `animation` 设为 `nil`、`disablesAnimations` 设为 `true`。后台数据刷新继续执行。

`MenuSurfaceVisibilityState` 在面板展示后开启，在关闭开始时结束。每次展示递增 `presentationGeneration`，额度和用量区域以该值作为视图身份，重新执行入场动画。

### 活动卡片

`CodexActivityCard` 使用 `primaryActivity`，优先级为等待批准、运行中、最近完成、最近终止。`isActivelyPreventingSleep` 为 `true` 且卡片数据可用时显示青绿色 `sun.max.fill`，通过 `.symbolEffect(.rotate.byLayer, options: .repeat(.continuous))` 持续旋转。tooltip 按 `sleepPreventionSource` 显示来源。

## Fallback panel

全局快捷键触发时，状态栏按钮的屏幕位置可能不可用或不可信。此时 [`FallbackPanelController.swift`](../../CodexBar/Controllers/FallbackPanelController.swift) 在鼠标所在屏幕显示浮动面板。

### 锚点校验

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

热力图悬停请求以动画收起其他侧边面板；重置次数和任务中心的点击请求立即关闭其他侧边面板。

主面板关闭时立即清理侧边面板。热力图详情和共享抽屉在立即关闭或窗口已不可见时，重置抽屉动画、执行 `orderOut` 并移除父子窗口关系。任务中心已结束逻辑展示时，立即关闭请求仍传递给共享抽屉。

热力图按格子的列、行位置错开入场。启用入场动画时，每个格子在自身入场延迟加 0.25 秒后接受悬停；关闭入场动画时立即接受悬停。

热力图详情面板以包含标题、日期范围和方格矩阵的完整热力图区域作为垂直锚点，因此主面板区域重排后仍优先保持两者顶边对齐。如果详情面板从该位置向下会超过主面板底边，则定位逻辑将它整体上移到与主面板底边对齐。

相关控制器包括：

- [`HeatmapDetailPanelController.swift`](../../CodexBar/Controllers/HeatmapDetailPanelController.swift)
- [`ResetCreditsPanelController.swift`](../../CodexBar/Controllers/ResetCreditsPanelController.swift)
- [`ActivityCenterPanelController.swift`](../../CodexBar/Controllers/ActivityCenterPanelController.swift)
- [`SidePanelSupport.swift`](../../CodexBar/Controllers/SidePanelSupport.swift)

## 设置和日志窗口

设置与日志由独立的 `HostingWindowController` 管理 `NSWindow`

打开设置或日志窗口时，`HostingWindowController` 允许目标窗口成为 key 并激活 App。`AuxiliaryHostingWindow` 可以成为 key window，但不能成为 main window。

上下文菜单 action 会延迟到 menu tracking 结束后执行，避免 AppKit 仍在菜单事件循环中时创建或激活窗口。

### 辅助窗口的持有和定位

`HostingWindowController` 懒创建并长期复用单个 window：

- `isReleasedWhenClosed = false`，关闭只隐藏，下次保留窗口对象和 SwiftUI 状态
- `.moveToActiveSpace`，重开时跟随当前 Space，不把用户切回旧桌面
- 优先在 status item 所在屏幕居中，再退到 window screen 或 main screen
- miniaturized 窗口先 deminiaturize 再激活

设置窗口按当前 tab 的完整内容调整高度，固定上边缘，并限制到屏幕可见区域。内容超出屏幕高度时使用 `ScrollView`。

SwiftUI 可能在窗口创建完成前上报高度。`SettingsWindowController` 缓存最近一次有效测量，在 `HostingWindowController.window` 就绪后应用。

主面板布局、通知、自动重置和防睡眠的二级设置面板在首次打开时创建，之后复用内容及必要的高度变化订阅。

这四个设置子面板包含交互控件，因此使用可获得键盘焦点的 `KeyableBorderlessPanel`。主面板的热力图、Reset Credits 和活动中心详情使用不会激活的 `NonactivatingSidePanel`。收起设置子面板时，`SidePanelSupport.orderOut` 只在该子面板仍是 key window 时恢复父窗口焦点；如果焦点已经主动转移到主面板或其他窗口，则不能再抢回，否则新打开的交互表面可能因失焦立即关闭。

自动重置与防睡眠从关闭切换为开启时，`AppSettingsView` 使用 `HelperFeatureConfirmation` 显示统一确认框。确认框按 `KeepAliveController.HelperStatus` 组合 Helper 提示与对应功能说明，用户确认后才调用设置对象写入开启状态。已开启设置行在 `.requiresApproval` 状态显示 `打开系统设置` 按钮。

二级设置入口使用各自的可用性结论：

- 主面板布局入口始终可用
- 通知读取 `NotificationSettings.canShowOptions`
- 自动重置要求 `AutoResetSettings.isEnabled` 且 `KeepAliveController.helperStatus == .enabled`
- 防睡眠读取 `KeepAliveController.canShowOptions`

入口条件失效时设置页发送对应的 `close` 动作，避免不可用的子面板继续显示。主开关关闭时，自动重置和防睡眠设置行不显示状态说明。

`MainPanelSettings` 使用稳定区域标识保存账户、任务中心、额度、Token 用量和底部状态的顺序与显隐。布局归一化会去重、忽略无效值、补齐缺失区域，并保证至少保留一个可见区域。`StatusItemController` 在读取到 Hook 关闭状态后调用 `updateHookEnabled(_:)`，持久化关闭任务中心；如果任务中心原本是唯一可见区域，则同时开启账户区域。从关闭切换到开启时自动显示任务中心，首次恢复开启状态和重复开启通知均保留用户布局。设置面板只禁用任务中心开关，拖拽手柄仍保持可用。其他数据链路的临时可用性只影响当次渲染。

布局排序使用手柄上的自定义 `DragGesture`。拖动项通过悬浮副本跟随指针，其他行在跨过半行距离时按视图内预览顺序实时让位，松手后才调用 `setSectionOrder(_:)` 一次性持久化最终顺序。

`SettingsWindowController` 持有这一窗口组唯一的 `UndoManager`。设置主窗口通过 `AuxiliaryHostingWindow` 暴露它，四个设置子面板展示时从父窗口取得同一实例，因此焦点位于设置主窗口或任一子面板时，`⌘Z` 和 `⌘⇧Z` 都作用于同一份布局历史。Hook 状态变化引起的任务中心自动显隐不进入用户撤销历史。

### 代理配置对话框

`CodexBarAppDelegate` 持有 `CodexProxySettings`，并经窗口控制器注入设置页。`AppSettingsView` 使用 SwiftUI `sheet` 展示 `ProxySettingsView`，打开前关闭侧边设置面板。

未配置时点击整行或开关都会打开配置；已有配置时，行主体打开对话框，开关单独启停。对话框显示时从本机偏好加载草稿，关闭时取消测试并清空内存中的密码草稿。右上角清除菜单按保存记录是否存在显示，即使记录无法解码也可使用。

关于页面的重连按钮紧邻 `Codex 版本` 标题，来源选择器位于行尾。重连及刷新期间两者禁用；没有可用来源时重连按钮禁用。

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

`GlobalHotKeyRegistration` 在显式 invalidate 和 deinit 中清理 Carbon 引用。

## 自动刷新与面板打开

app-server 状态默认每 60 秒检查刷新。主面板打开后约 160 ms 调用 `refreshIfNeeded`，倒计时起点为空或距上次刷新结果提交超过 60 秒时才发起请求。成功和失败的结果提交都会重置倒计时；该检查可能发生在淡入动画结束之前。

主面板显示刷新倒计时，双击账户图标可立即手动刷新。

普通刷新在刷新或重连进行中被忽略。需要在当前请求后补刷的操作通过 `refreshAfterCurrent` 保存一个待执行触发，当前请求结束后再执行。

面板打开时立即对账 Hook 配置，并在 Hook 开启时请求本地统计刷新。延迟任务只检查账户、额度和用量是否需要刷新；面板提前关闭时取消该任务。

## 本地化和格式化

简体中文和英文界面字符串位于 [`Localizable.xcstrings`](../../CodexBar/Resources/Localizable.xcstrings)

百分比、时长和部分时间显示使用系统地区设置。`CodexDateFormat` 的日期键及日期范围固定为 `yyyy-MM-dd`，设置页最后上传时间和重置次数详情固定为本地时间 `yyyy-MM-dd HH:mm:ss`。本地化字符串不参与状态机判定。

## 自动更新

[`AppUpdater.swift`](../../CodexBar/Services/Updates/AppUpdater.swift) 封装 Sparkle：

- appcast URL 来自 App 配置
- 自动检查间隔为 3600 秒
- 更新 UI 由设置页和主面板的新版本提示触发
- CodexBarHelper 变化在更新后单独执行 fingerprint 和注册状态检查

发布脚本需要 Developer ID、签名和公证凭据，不属于日常本地构建流程。

## 手动验证矩阵

- 左键打开主面板，右键和 Control 点击打开上下文菜单
- 菜单栏符号随任务状态切换，最新终态在结束 30 秒后恢复空闲，跨睡眠唤醒后按当前时间显示
- 切换额度圆弧显隐时动画完整，零额度保留底轨，缓存额度变淡
- 防睡眠生效时太阳徽标持续旋转，结束后消失，重开面板后状态正确
- 代理密码显隐切换时淡化正常，输入内容、选区和焦点保留
- 点击主面板外部正确关闭，点击侧边面板不误关闭
- 热力图、Reset Credits 和活动中心保持互斥
- Token 用量区域处于不同排序位置时，热力图详情优先与完整热力图区域顶边对齐；详情高度放不下时与主面板底边对齐
- 全局快捷键在状态栏锚点有效和无效场景都能打开面板
- 从通知点击激活 App 并打开面板
- 设置窗口首次打开、关闭和再次打开时焦点正确
- 冷启动后首次打开设置时通用页直接使用完整内容高度；切换三个 tab 时窗口高度自适应，屏幕空间充足时均不显示滚动条
- 主面板布局、通知、自动重置和防睡眠子面板互斥，顶边对齐对应设置行，内容变化后高度正确
- 设置子面板展开时从菜单栏打开主面板，主面板保持打开，设置子面板收起且不把焦点抢回设置窗口
- 主面板区域拖动时悬浮行跟随指针，跨过半行后其他行实时让位，松手后平滑落位并只保存最终顺序；拖拽和显隐操作可以通过 `⌘Z` 逐步撤销并通过 `⌘⇧Z` 重做，焦点在设置主窗口或任一设置子面板时均有效；重启后保持配置，最后一个可见区域无法关闭；Hook 关闭时任务中心自动关闭、开关置灰但仍可拖动，任务中心为唯一可见区域时账户自动开启；重新开启 Hook 后任务中心自动显示，手动隐藏后重启仍保持隐藏，自动联动不进入用户撤销历史
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
- [`StatusItemIconView.swift`](../../CodexBar/Views/Menu/StatusItemIconView.swift)
- [`CodexActivityCard.swift`](../../CodexBar/Views/Menu/CodexActivityCard.swift)

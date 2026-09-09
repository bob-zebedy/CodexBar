# UI and App Lifecycle

[简体中文](../../DeveloperGuide/ui-and-lifecycle.md) | English

## `LSUIElement` Constraints

CodexBar is configured as an `LSUIElement` in [`Info.plist`](../../../CodexBar/Resources/Info.plist).

It has no Dock icon or conventional main-window lifecycle. The menu bar, popover, floating panel, Settings window, and notification clicks must all manage app activation and focus explicitly.

The UI declares content in SwiftUI and manages windows through AppKit controllers.

## Three Kinds of Focus Under `LSUIElement`

Development must distinguish among:

- Whether the app is active
- Whether a window is key
- Whether the menu surface is logically presented

These states do not synchronize automatically. Command-Space, for example, makes the app resign active while the user briefly opens Spotlight; that should not necessarily close the menu. A Settings window may already be visible, but it must not retake key status during the menu's closing animation and cause a flash.

The code therefore does not treat `NSApp.isActive` as the sole truth for the menu. It maintains explicit menu-surface state and the current container, then lets event monitors coordinate activation.

## Service Assembly

[`CodexBarAppDelegate.swift`](../../../CodexBar/Controllers/CodexBarAppDelegate.swift) is the composition root for normal mode. [`StatusItemController.swift`](../../../CodexBar/Controllers/StatusItemController.swift) is responsible only for the menu bar and related window orchestration.

### Startup Ordering

Normal-mode assembly reflects dependency direction:

```text
Create settings, data services, view models, and updater
  -> Create and install StatusItemController
      -> Set up the status item, observers, and hot key
      -> Reconcile Hook and start periodic refresh
  -> Start notifications and automatic reset
  -> Connect Activity Protection callbacks
  -> Start the activity monitor and keep-alive coordination
```

Notifications and sleep prevention consume only snapshots or transitions already published by the monitor; they do not control readers upstream. Controllers connect these services through closures, keeping AppKit containers out of the service layer.

Shutdown reverses the order, except for helper-owned system state. AppDelegate first confirms asynchronously that the Automatic Reset wake schedule is canceled and the sleep-prevention lease is released, then allows process termination. See [Sleep Prevention System](sleep-prevention.md) for the transaction.

## Status Bar Icon

The status icon combines app-server loading state, the menu bar rate-limit setting, and the task-activity snapshot.

Task-status priority is:

```text
Waiting for approval (orange) > Running (blue) > Within 30 seconds of completion (green)
```

Recent termination, idle state, and expired completion highlights show no task dot. Icon output is cached by input state; inactive or unavailable states use reduced alpha.

### Separating Image State from Tooltip State

`StatusIconState` contains both image and tooltip inputs, but `renderState` retains only fields that change pixels:

- Active-task duration changes every minute and updates only the tooltip
- When expired rate-limit data remains visible from cache, the icon and progress indicator use reduced alpha
- A roughly 0.18-second, 10-frame animation starts only when the indicator dot or rate-limit bar appears or disappears
- A new render state cancels the previous animation; every frame confirms that its target is still current

With no status dot or rate-limit bar, the icon remains a template image so the system colors it for light mode, dark mode, and menu bar state. Adding custom colors or a progress bar switches to explicit color rendering.

The tooltip starts a 60-second timer only when a live task duration exists; it does not retain a permanent timer while idle. The app also sets `NSInitialToolTipDelay` to 500 ms so the status explanation for this small click target is easier to discover.

Left-click opens the main panel. Right-click or Control-click opens the context menu.

## Main Panel

The main panel prefers an `NSPopover` with `behavior` set to `applicationDefined` and `animates` set to `false`.

[`MenuSurfaceDismissMonitor.swift`](../../../CodexBar/Controllers/MenuSurfaceDismissMonitor.swift) observes mouse, keyboard, and activation events and requests dismissal through `onDismiss`. [`MenuSurfaceFadeCoordinator.swift`](../../../CodexBar/Controllers/MenuSurfaceFadeCoordinator.swift) performs fades, and `StatusItemController` receives the popover's actual close callback through `NSPopoverDelegate`.

### Open and Close State Machine

`menuSurfaceState` has four states:

```text
hidden -> opening -> shown -> closing -> hidden
```

Operations follow these rules:

- Toggling in `opening` or `shown` starts closing
- Toggling in `closing` finishes the old close, then opens a new surface
- Starting a close cancels delayed refresh and old animations
- A nonanimated close completes state cleanup immediately

`activeMenuSurface` identifies the current container as `none`, `popover`, or `fallbackPanel`. An explicit container close sets it to `none` before closing the window.

`popoverDidClose` handles notifications only for the owned popover when it is closed and disables that host's animations. If the current container is still `popover`, it calls `completeMenuSurfaceClose` to cancel pending tasks, hide side panels, remove event monitors, end presentation state, and schedule auxiliary-window focus restoration.

### Dismiss Event Monitoring

The allowed click region for the main panel is a set:

```text
Current menu window + status item button + all visible side panels
```

A local monitor handles mouse and keyboard events inside the app, a global monitor handles clicks over other apps, and workspace and window observers handle activation changes. Every path ends in the same `onDismiss` callback.

Special rules include:

- Escape consumes the event and closes the surface
- Command-Tab allows the system switch and closes the surface
- Command-Space temporarily suppresses activation dismissal so opening Spotlight does not close the surface accidentally
- After a click, the code pins `NSVisualEffectView` back to inactive so AppKit background emphasis does not cause a brightness jump
- After first installing observers, `Task.yield()` performs a second window acquisition and focus pass in case the popover window was not attached yet

### Fades and Completion Tasks

`MenuSurfaceFadeCoordinator` animates both the active container’s content view and window opacity, with a 0.24-second fade-in and a 0.18-second fade-out. It stores one completion task, cancels it before starting a new animation, and checks cancellation after waiting before marking the surface shown or completing the close.

Settings and log windows temporarily reject `makeKey()` during closing and regain that ability about 120 ms after completion. The completion task holds a weak reference to that window and restores content and window opacity after closing.

### Content Animations and Presentation State

The popover and fallback panel each hold a separate `MenuSurfaceAnimationState`. `allowsAnimations` is set to `true` before presentation, remains enabled during fade-out, and becomes `false` after the surface closes.

When animations are disabled, `CodexStatusMenuView` sets the root transaction's `animation` to `nil` and `disablesAnimations` to `true`. Background data refresh continues.

`MenuSurfaceVisibilityState` begins after the panel is shown and ends when closing starts. Each presentation increments `presentationGeneration`; the rate-limit and usage sections use that value as their view identity and run their entrance animations again.

## Fallback Panel

The status-bar button's screen position may be unavailable or untrusted when a global shortcut fires. [`FallbackPanelController.swift`](../../../CodexBar/Controllers/FallbackPanelController.swift) then presents a floating panel on the screen under the pointer.

### Anchor Validation

A global shortcut may fire before status-item layout completes, while the menu bar is on another display, or when the system temporarily provides no button window. The code validates more than a non-`nil` button:

- The window and screen exist
- The button is visible and has nonempty bounds
- The converted screen rect is valid and at least 1 point
- The rect intersects the target screen frame within a 1-point tolerance

Only then does it use a popover arrow. Otherwise, the fallback panel appears on the screen under the pointer. This prevents AppKit from placing the popover on the wrong display or completely offscreen.

Before showing, the fallback panel constrains its size from the SwiftUI fitting size and the target screen's visible area. Coordinate calculations live in `ScreenGeometry` because AppKit's bottom-left origin, SwiftUI local layout, and multi-display frames are easy to mix up.

## Side Detail Panels

The main panel can open:

- Activity heatmap details
- Reset Credits details
- Task Center

These panels are mutually exclusive. Opening one closes the others. Each adds its screen region to the main surface's extra hit regions, so moving or clicking between the main and side panels does not dismiss them accidentally.

All detail panels implement `MenuSideDetailPanel` and register in the `sideDetailPanels` array. Mutual exclusion, main-surface closing, and hit testing all iterate over this one registry.

Heatmap hover requests animate the dismissal of other side panels. Click requests for Reset Credits and Task Center close other side panels immediately.

Closing the main panel immediately cleans up its side panels. For an immediate close or an already invisible window, heatmap details and the shared drawer reset drawer animations, call `orderOut`, and remove the parent-child window relationship. Task Center forwards immediate-close requests to the shared drawer even when its logical presentation has ended.

Heatmap squares enter with staggered delays based on their column and row. With entrance animations enabled, each square accepts hover after its own entrance delay plus 0.25 seconds. With entrance animations disabled, squares accept hover immediately.

The heatmap detail panel uses the complete heatmap area, including its heading, date range, and square grid, as its vertical anchor. Reordering main-panel sections therefore still keeps their top edges aligned whenever possible. If the detail panel would extend below the main panel from that position, placement shifts it upward until their bottom edges align.

Related controllers include:

- [`HeatmapDetailPanelController.swift`](../../../CodexBar/Controllers/HeatmapDetailPanelController.swift)
- [`ResetCreditsPanelController.swift`](../../../CodexBar/Controllers/ResetCreditsPanelController.swift)
- [`ActivityCenterPanelController.swift`](../../../CodexBar/Controllers/ActivityCenterPanelController.swift)
- [`SidePanelSupport.swift`](../../../CodexBar/Controllers/SidePanelSupport.swift)

## Settings and Logs Windows

Separate `HostingWindowController` instances manage `NSWindow` for Settings and Logs.

When opening settings or logs, `HostingWindowController` allows the target window to become key and activates the app. `AuxiliaryHostingWindow` can become key but cannot become the main window.

Context-menu actions wait until menu tracking finishes before running, avoiding window creation or activation inside AppKit's menu event loop.

### Auxiliary Window Retention and Placement

`HostingWindowController` lazily creates and reuses one window:

- `isReleasedWhenClosed = false`: closing hides it and preserves the window object and SwiftUI state
- `.moveToActiveSpace`: reopening follows the current Space instead of switching the user back to an old desktop
- Placement prefers centering on the status item's screen, then falls back to the window screen or main screen
- A minimized window is deminiaturized before activation

Settings-window height follows the complete content of the current tab while pinning the top edge and constraining the window to the visible screen frame. When the content fits within that screen limit, the window must contain the entire page without a scrollbar; `ScrollView` is only a safety fallback when the content physically cannot fit in the visible area. The pinned top prevents the entire window from drifting vertically between tabs and keeps the title bar as a stable visual anchor.

During initial construction, SwiftUI may report the page height before `HostingWindowController` stores `window`. `SettingsWindowController` caches the latest valid measurement and applies it once the window is ready. Otherwise, the only height callback can be discarded, leaving the window at its initial size until a tab switch triggers another measurement.

Secondary panels for main-panel layout, notifications, Automatic Reset, and sleep prevention are created on demand. Once created, a controller retains its content and any required content-height subscriptions for its lifetime. Prebuilding every panel at app launch would keep unused UI participating in updates.

These four settings child panels contain interactive controls, so they use a keyable `KeyableBorderlessPanel`. The main panel's Heatmap, Reset Credits, and Task Center details use a nonactivating `NonactivatingSidePanel`. When a settings child panel closes, `SidePanelSupport.orderOut` restores focus to its parent only if that child panel is still the key window. If focus has already moved intentionally to the main panel or another window, it must not be taken back, or the newly opened interaction surface may close immediately after losing focus.

When Automatic Reset or Prevent System Sleep changes from off to on, `AppSettingsView` presents a shared confirmation through `HelperFeatureConfirmation`. It combines guidance from `KeepAliveController.HelperStatus` with the feature description and writes enabled state only after user confirmation. An enabled settings row in `.requiresApproval` shows `Open System Settings`.

Each secondary-settings entry uses its own availability decision:

- Main Panel Layout is always available
- Notifications reads `NotificationSettings.canShowOptions`
- Automatic Reset requires `AutoResetSettings.isEnabled` and `KeepAliveController.helperStatus == .enabled`
- Sleep prevention reads `KeepAliveController.canShowOptions`

When a condition becomes false, Settings sends the corresponding `close` action so an unavailable child panel does not remain visible. Automatic Reset and sleep-prevention rows show no status explanation while their main switches are off.

`MainPanelSettings` stores the order and visibility of Account, Task Center, Quota, Token Usage, and Footer Status with stable section identifiers. Layout normalization removes duplicates, ignores invalid values, appends missing sections, and keeps at least one section visible. After reading a disabled Hook state, `StatusItemController` calls `updateHookEnabled(_:)` to persist Task Center as hidden. If Task Center was the only visible section, Account is enabled at the same time. The settings panel disables only the Task Center switch, so its drag handle remains available. Temporary availability of other data sources affects only the current rendering.

Layout sorting uses a custom `DragGesture` on the handle. A floating copy follows the pointer, other rows move when it crosses half a row, and releasing calls `setSectionOrder(_:)` once to persist the final order.

`SettingsWindowController` owns the only `UndoManager` for this window group. The Settings window exposes it through `AuxiliaryHostingWindow`, and each of the four settings child panels obtains the same instance from its parent when shown. `Command-Z` and `Command-Shift-Z` therefore operate on one layout history while focus is in either the Settings window or any child panel. Automatic Task Center changes caused by Hook state do not enter the user's undo history.

### Proxy Configuration Dialog

`CodexBarAppDelegate` owns `CodexProxySettings` and injects it into Settings through the window controllers. `AppSettingsView` presents `ProxySettingsView` in a SwiftUI `sheet`, closing side settings panels first.

Without a configuration, clicking the row or toggle opens the dialog. With one saved, the row opens the dialog and the toggle independently enables or disables it. Presentation loads the draft from local preferences; dismissal cancels tests and clears the in-memory password draft. The top-right clear menu depends on whether a saved record exists and remains available when decoding fails.

In About, the reconnect button sits immediately after the Codex Versions title, with the source picker at the end of the row. Both are disabled during reconnection and refresh; Reconnect is also disabled when no source is available.

## Global Shortcut

[`GlobalHotKeyController.swift`](../../../CodexBar/Controllers/GlobalHotKeyController.swift) uses the Carbon Hot Key API.

Shortcut constraints:

- At least two modifier keys
- Reject `Command-Space`
- Reject `Command-Tab`
- Roll back to the previous working setting if system registration conflicts
- Reregister immediately after a setting change

The Carbon API fits a menu bar app without a Dock icon and avoids a global keyboard event tap or Input Monitoring permission.

Registration uses try-before-swap:

1. Install a temporary handler and hot key for the candidate shortcut
2. Release the current registration only after the candidate succeeds
3. On failure, clean up candidate resources and restore the previous setting

`GlobalHotKeyRegistration` clears Carbon references on explicit invalidation and deinitialization.

## Automatic Refresh and Panel Opening

App-server state is checked for refresh every 60 seconds by default. About 160 ms after the main panel opens, `refreshIfNeeded` requests data if no countdown origin exists or more than 60 seconds have passed since the last refresh result was committed. Both successful and failed results reset the countdown; this check can occur before fade-in finishes.

The main panel shows a refresh countdown. Double-clicking the account icon requests an immediate manual refresh.

Ordinary refreshes are ignored while a refresh or reconnect is in progress. Operations requiring a follow-up use `refreshAfterCurrent` to retain one pending trigger and run it after the current request finishes.

Opening the panel immediately refreshes local Hook statistics. The delayed task also reconciles installed Hook configuration and is canceled if the panel closes while it waits.

## Localization and Formatting

Simplified Chinese and English interface strings are in [`Localizable.xcstrings`](../../../CodexBar/Resources/Localizable.xcstrings).

Percentages, durations, and some time displays use system regional settings. `CodexDateFormat` fixes date keys and ranges to `yyyy-MM-dd`; the settings page’s last-upload time and reset-credit details use local time in `yyyy-MM-dd HH:mm:ss`. Localized strings do not drive state-machine decisions.

## Automatic Updates

[`AppUpdater.swift`](../../../CodexBar/Services/Updates/AppUpdater.swift) wraps Sparkle:

- The appcast URL comes from app configuration
- Automatic checks run every 3,600 seconds
- Update UI is triggered from settings and the main panel’s new-version notice
- After an update, CodexBar checks CodexBarHelper fingerprint and registration state separately if the helper changed

Release scripts require Developer ID, signing, and notarization credentials and are not part of routine local builds.

## Manual Validation Matrix

- Left-click opens the main panel; right-click and Control-click open the context menu
- Clicking outside the main panel dismisses it; clicking a side panel does not
- Heatmap, Reset Credits, and Task Center panels remain mutually exclusive
- With Token Usage at different positions in the main-panel order, heatmap details align to the complete heatmap area's top edge when possible and fall back to the main panel's bottom edge when the detail height does not fit
- The global shortcut opens the panel with both valid and invalid status-bar anchors
- Clicking a notification activates the app and opens the panel
- Focus is correct when opening Settings for the first time, closing it, and reopening it
- On the first Settings open after a cold launch, General immediately uses its full content height; switching among all three tabs adapts the window height, with no scrollbar when screen space is sufficient
- Main Panel Layout, Notification, Automatic Reset, and sleep-prevention child panels remain mutually exclusive, align their top edges with their setting rows, and resize correctly when content changes
- With a settings child panel open, opening the main panel from the menu bar keeps the main panel open, closes the settings child panel, and does not steal focus back to Settings
- While reordering the main panel, the floating row follows the pointer, other rows make room after the drag crosses half a row, and release settles smoothly while persisting only the final order; reordering and visibility changes can be undone step by step with `Command-Z` and redone with `Command-Shift-Z` while either the Settings window or any settings child panel has focus; the result persists across relaunches; the last visible section cannot be hidden; disabling Hook turns Task Center off and disables its switch without blocking drag, enables Account if Task Center was the only visible section, and does not enter automatic Hook changes into user undo history
- Opening Settings or Logs from the context menu does not lose focus
- On multiple displays and with different menu bar locations, the fallback panel appears on the pointer's screen
- The old shortcut still works after a new shortcut conflicts
- Panel-open refresh does not stall animation or issue duplicate requests

## Key Source Files

- [`CodexBarAppDelegate.swift`](../../../CodexBar/Controllers/CodexBarAppDelegate.swift)
- [`StatusItemController.swift`](../../../CodexBar/Controllers/StatusItemController.swift)
- [`FallbackPanelController.swift`](../../../CodexBar/Controllers/FallbackPanelController.swift)
- [`MenuSurfaceDismissMonitor.swift`](../../../CodexBar/Controllers/MenuSurfaceDismissMonitor.swift)
- [`MenuSurfaceFadeCoordinator.swift`](../../../CodexBar/Controllers/MenuSurfaceFadeCoordinator.swift)
- [`GlobalHotKeyController.swift`](../../../CodexBar/Controllers/GlobalHotKeyController.swift)
- [`SettingsWindowController.swift`](../../../CodexBar/Controllers/SettingsWindowController.swift)
- [`LogWindowController.swift`](../../../CodexBar/Controllers/LogWindowController.swift)
- [`CodexStatusMenuView.swift`](../../../CodexBar/Views/Menu/CodexStatusMenuView.swift)

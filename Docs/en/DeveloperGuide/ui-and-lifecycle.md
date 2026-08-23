# UI and App Lifecycle

[简体中文](../../DeveloperGuide/ui-and-lifecycle.md) | English

## `LSUIElement` Constraints

CodexBar is configured as an `LSUIElement` in [`Info.plist`](../../../CodexBar/Resources/Info.plist).

It has no Dock icon or conventional main-window lifecycle. The menu bar, popover, floating panel, Settings window, and notification clicks must all manage app activation and focus explicitly.

Default SwiftUI `Window` behavior does not cover these cases, so the UI combines SwiftUI content with AppKit controllers.

## UI Responsibilities

SwiftUI declares content; AppKit owns window and event lifecycles:

| Layer | Responsible for | Not responsible for |
| --- | --- | --- |
| SwiftUI view | Layout, data presentation, callbacks for user intent | Creating long-lived services, choosing the key window, installing global event monitors |
| View model and settings | Publishing stable snapshots, saving user settings | Owning windows or evaluating screen coordinates |
| AppKit controller | Popovers, panels, windows, focus, event monitoring | Reimplementing business state machines |
| AppDelegate | Assembling and retaining long-lived objects | Specific view layout |

This boundary allows the same menu content to run in an `NSPopover` or fallback `NSPanel`, while preventing SwiftUI identity changes from destroying monitors, XPC connections, or notification services.

## Three Kinds of Focus Under `LSUIElement`

Development must distinguish among:

- Whether the app is active
- Whether a window is key
- Whether the menu surface is logically presented

These states do not synchronize automatically. Command-Space, for example, makes the app resign active while the user briefly opens Spotlight; that should not necessarily close the menu. A Settings window may already be visible, but it must not retake key status during the menu's closing animation and cause a flash.

The code therefore does not treat `NSApp.isActive` as the sole truth for the menu. It maintains explicit menu-surface state and the current container, then lets event monitors coordinate activation.

## Service Assembly

[`CodexBarAppDelegate.swift`](../../../CodexBar/Controllers/CodexBarAppDelegate.swift) is the composition root for normal mode. [`StatusItemController.swift`](../../../CodexBar/Controllers/StatusItemController.swift) is responsible only for the menu bar and related window orchestration.

AppDelegate:

- Creates long-lived services, view models, and settings
- Connects the monitor to notifications and sleep prevention, and assembles the Automatic Reset state machine
- Starts status refresh and Hook activity reading
- Creates the status-item controller
- Installs the global shortcut
- Configures Sparkle updates
- Coordinates Automatic Reset wake-schedule cancellation and sleep-prevention release during termination

The composition root retains these objects explicitly so SwiftUI view lifecycle cannot destroy long-running services accidentally.

### Why Startup Order Matters

Normal-mode assembly reflects dependency direction:

```text
Create settings and data services
  -> Build view models
  -> Create status item and window controllers
  -> Start notification and Automatic Reset side effects
  -> Start activity monitoring and keep-alive coordination
  -> Start periodic refresh and update services
```

Notifications and sleep prevention consume only snapshots or transitions already published by the monitor; they do not control readers upstream. Controllers connect these services through closures, keeping AppKit containers out of the service layer.

Shutdown reverses the order, except for helper-owned system state. AppDelegate first confirms asynchronously that the Automatic Reset wake schedule is canceled and the sleep-prevention lease is released, then allows process termination. See [Sleep Prevention System](sleep-prevention.md) for the transaction.

## Status Bar Icon

The status icon combines app-server loading state, the menu bar rate-limit setting, and the task-activity snapshot.

Task-status priority is:

```text
Waiting for approval > Running > Recently completed > Recently terminated > Idle
```

Rendered icons are cached by input state to avoid redrawing on every timed refresh. Inactive or unavailable state is expressed through alpha.

### Separating Image State from Tooltip State

`StatusIconState` contains both image and tooltip inputs, but `renderState` retains only fields that change pixels:

- Active-task duration changes every minute and updates only the tooltip
- When expired rate-limit data remains visible from cache, the icon and progress indicator use reduced alpha
- A roughly 0.18-second, 10-frame animation starts only when the indicator dot or rate-limit bar appears or disappears
- A new render state cancels the previous animation; every frame confirms that its target is still current

Redrawing `NSImage` from the complete state would interrupt animations and add menu bar work whenever timer text changes. Explicit render identity is a small but important performance boundary.

With no status dot or rate-limit bar, the icon remains a template image so the system colors it for light mode, dark mode, and menu bar state. Adding custom colors or a progress bar switches to explicit color rendering.

The tooltip starts a 60-second timer only when a live task duration exists; it does not retain a permanent timer while idle. The app also sets `NSInitialToolTipDelay` to 500 ms so the status explanation for this small click target is easier to discover.

Left-click opens the main panel. Right-click or Control-click opens the context menu.

## Main Panel

The main panel prefers an `NSPopover` with `behavior` set to `applicationDefined`.

CodexBar manages dismissal because:

- The main panel can open Settings, Logs, and side detail panels
- `LSUIElement` activation changes cause ordinary transient popovers to close incorrectly
- Side panels must behave as part of one interaction surface
- Closing needs a consistent fade-out

[`MenuSurfaceDismissMonitor.swift`](../../../CodexBar/Controllers/MenuSurfaceDismissMonitor.swift) observes global and local events. [`MenuSurfaceFadeCoordinator.swift`](../../../CodexBar/Controllers/MenuSurfaceFadeCoordinator.swift) coordinates closing animation.

### Why Opening and Closing Need an Explicit State Machine

`menuSurfaceState` has four states:

```text
hidden -> opening -> shown -> closing -> hidden
```

They resolve intermediate states from rapid repeated clicks:

- Toggling in `opening` or `shown` starts closing
- Toggling in `closing` finishes the old close, then opens a new surface
- Starting a close cancels delayed refresh and old animations
- A nonanimated close converges state immediately rather than waiting for an animation completion that will never occur

Checking only `popover.isShown` cannot represent logical opening or fade-out state and cannot cover the fallback panel.

### Why One Monitor Owns Dismissal Rules

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

Change these rules as a single interaction surface. Adding a separate event monitor to one side panel creates monitor-order and duplicate-dismissal problems.

### Fade Content, Not the Window

AppKit owns the popover's system window, so animating its alpha directly can conflict with system presentation state. `MenuSurfaceFadeCoordinator` animates the active container's content view, then calls the shared close operation.

Auxiliary windows temporarily reject `makeKey()` while closing. Otherwise, an already-open Settings or Logs window can jump to the front for a few frames during menu fade-out.

## Fallback Panel

The status-bar button's screen position may be unavailable or untrusted when a global shortcut fires. [`FallbackPanelController.swift`](../../../CodexBar/Controllers/FallbackPanelController.swift) then presents a floating panel on the screen under the pointer.

The popover and fallback panel host identical SwiftUI content and state. Business logic must not depend on the container type.

### Why the Anchor Needs a Trust Check

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

This scales better than encoding every pairwise close relationship. Adding a fourth panel requires one registry entry rather than six new mutual-exclusion pairs.

The hover-driven heatmap panel may fade before another panel opens; click-driven panels normally close the old panel immediately. This avoids two opposing slide animations at the same screen location.

Related controllers include:

- [`HeatmapDetailPanelController.swift`](../../../CodexBar/Controllers/HeatmapDetailPanelController.swift)
- [`ResetCreditsPanelController.swift`](../../../CodexBar/Controllers/ResetCreditsPanelController.swift)
- [`ActivityCenterPanelController.swift`](../../../CodexBar/Controllers/ActivityCenterPanelController.swift)
- [`SidePanelSupport.swift`](../../../CodexBar/Controllers/SidePanelSupport.swift)

## Settings and Logs Windows

Separate `HostingWindowController` instances manage `NSWindow` for Settings and Logs.

When an `LSUIElement` app opens a normal window, it must temporarily allow that window to become key, activate the app, and transfer focus to the target control. Closing restores menu-bar-app foreground behavior.

Focus recovery waits about 120 ms for AppKit to finish window and activation transitions. This delay coordinates system lifecycle and cannot simply become a synchronous call.

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

Layout sorting uses a custom `DragGesture` on each handle. A floating copy follows the pointer, while the other rows make room using a view-local preview order whenever the drag crosses half a row. Only after release does the view call `setSectionOrder(_:)` once to persist the final order. Do not replace this with system `.draggable` and `.dropDestination`, which reorder only after a drop target is hit and cannot provide continuous sorting animation.

`SettingsWindowController` owns the only `UndoManager` for this window group. The Settings window exposes it through `AuxiliaryHostingWindow`, and each of the four settings child panels obtains the same instance from its parent when shown. `Command-Z` and `Command-Shift-Z` therefore operate on one layout history while focus is in either the Settings window or any child panel. Automatic Task Center changes caused by Hook state do not enter the user's undo history.

### The 120 ms Focus Recovery Is Not Business Delay

While the menu closes, `AuxiliaryHostingWindow` temporarily sets `allowsKeyFocus` to false. It waits about 120 ms after closing before restoring it.

This gives AppKit time to complete popover order-out, activation, and key-window recalculation. Removing it may produce an intermittent Settings-window flash only on some machines; treat it as a system event-ordering constraint, not arbitrary wait time.

Right-click menu actions also dispatch on the main queue after `menuDidClose`. Menu tracking is a nested event loop, and creating a window synchronously inside it produces unstable activation order.

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

Unregistering first would leave the user without either shortcut after one conflict. `GlobalHotKeyRegistration` releases Carbon references in both explicit invalidation and `deinit` to avoid leaking handlers during reregistration.

At least two modifiers reduce accidental activation. Command-Space and Command-Tab are rejected because they are core system navigation shortcuts and should not be captured even if the registration API occasionally permits it.

## Automatic Refresh and Panel Opening

app-server state refreshes every 60 seconds by default. Opening the panel schedules a refresh after about 160 ms so animation and focus transitions finish before data updates.

The main panel displays a countdown. A double-click triggers manual refresh, avoiding ambiguity between clicking the status item and invoking a button action.

The refresh coordinator merges concurrent triggers so the timer, panel opening, and user action do not issue duplicate requests.

When the panel opens, Hook metrics refresh immediately from local cache, while the app-server request waits about 160 ms. The former is cheap and fills content quickly; the latter may launch a process or make protocol requests, so deferring it reduces first-frame stalls.

`refreshIfNeeded` still performs freshness coalescing; the 160 ms delay is not a second refresh path that bypasses coordination. If the panel closes while waiting, the task is canceled and no request runs for hidden UI.

## Checklist for UI Lifecycle Changes

1. Decide whether the change belongs to SwiftUI content or AppKit container lifecycle
2. Confirm that the popover and fallback panel behave identically
3. Test intermediate `opening` and `closing` states, not only stable states
4. Determine whether a click region belongs to the extra surface
5. Check whether app-active, key-window, and logical-presentation states can diverge
6. Ensure tasks and timers are canceled on close and uninstall
7. Test multiple displays, multiple Spaces, and an untrusted status-item anchor
8. Open the UI separately from a notification click, global shortcut, and right-click menu

## Localization and Formatting

Simplified Chinese and English interface strings are in [`Localizable.xcstrings`](../../../CodexBar/Resources/Localizable.xcstrings).

Dates, numbers, and percentages follow the system's automatically updating locale. Business models must not hard-code Chinese formatting or consume localized strings as state-machine inputs.

## Automatic Updates

[`AppUpdater.swift`](../../../CodexBar/Services/Updates/AppUpdater.swift) wraps Sparkle:

- The appcast URL comes from app configuration
- Automatic checks run every 3,600 seconds
- Settings and the context menu trigger update UI
- After an update, CodexBar checks CodexBarHelper fingerprint and registration state separately if the helper changed

Release scripts require Developer ID, signing, and notarization credentials and are not part of routine local builds.

## Manual Validation Matrix

- Left-click opens the main panel; right-click and Control-click open the context menu
- Clicking outside the main panel dismisses it; clicking a side panel does not
- Heatmap, Reset Credits, and Task Center panels remain mutually exclusive
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

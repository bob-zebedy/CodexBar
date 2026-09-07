# Architecture

[简体中文](../../DeveloperGuide/architecture.md) | English

## Technical Baseline

CodexBar is a menu bar app for macOS 15 and later, built with Swift 6, SwiftUI, AppKit, and MVVM.

The project has one `CodexBar` scheme with two targets:

| Target | Responsibility |
| --- | --- |
| `CodexBar` | Menu bar UI, Codex data collection, Automatic Reset, notifications, sync, and system-power orchestration |
| `CodexBarHelper` | A root LaunchDaemon that handles fixed system-sleep controls and Automatic Reset wake schedules |

The targets share their XPC protocol through [`CodexBarHelperXPC.swift`](../../../Shared/CodexBarHelperXPC.swift).

The app uses Sparkle for update checks. The project enables `MainActor` isolation by default, and Debug and Release use different app and CodexBarHelper bundle IDs.

## Process and Trust Boundaries

```text
Codex
  | launches a --hook-event subprocess and passes the event through stdin
  v
CodexBar executable
  |-- Hook mode: minimal parsing + flock + JSONL append + exit
  |
  `-- Normal mode
       |-- stdio JSON-RPC <-> codex app-server (account, rate limits, Reset Credits)
       |-- local read-only <-> Hook JSONL / rollout JSONL
       |-- HTTPS <-> Sparkle
       |-- CloudKit private database <-> daily aggregations
       `-- signed XPC lease / wake date <-> root CodexBarHelper
              |-- fixed pmset commands
              `-- fixed IOPM wake event
```

Two points define these boundaries:

- Using the same executable for Hook mode keeps the handler pointed at the current app version without deploying a separate capture tool
- The root helper knows nothing about Codex tasks, accounts, or reset credits; it receives only signature-validated sleep leases and Automatic Reset wake times

### Process Lifecycle Differences

| Process | Lifetime | May do | Must not do |
| --- | --- | --- | --- |
| Hook subprocess | One event, at most a few seconds | Read stdin, extract minimal fields, append local JSONL | Initialize UI, open network connections, or wait for long-running services |
| Main app | Long-running within the user login session | Orchestrate UI, data flows, and side effects | Change system settings directly as root |
| app-server | Rebuilt on the next request after reaching 1 hour | Expose account and configuration capabilities through JSON-RPC | Substitute for Hook history or live task state |
| CodexBarHelper | LaunchDaemon | Run fixed `pmset` operations, manage a `wake` event for a fixed owner, and restore system state | Access accounts, Hook data, rollout files, the network, or arbitrary commands |

## Directory Responsibilities

```text
CodexBar/
  App/             App entry points
  Controllers/     AppKit window, menu bar, and panel controllers
  Models/          DTOs, state snapshots, and presentation models
  Services/        Data access, state machines, settings, notifications, and system services
  Views/           SwiftUI views
  Resources/       Info.plist, entitlements, localization, and sounds
CodexBarHelper/     root LaunchDaemon
Shared/             Cross-target XPC interface
Config/             Version configuration
Scripts/            Build, DMG, appcast, and CodexBarHelper cleanup scripts
```

## Startup Order

[`CodexBarApp.swift`](../../../CodexBar/App/CodexBarApp.swift) branches startup in this order:

```text
Process starts
  -> WorkflowHookEventRecorder.handleIfRequested()
      -> in --hook-event mode, read stdin, write JSONL, and exit immediately
      -> in normal mode, continue
  -> Create CodexBarAppDelegate
  -> AppDelegate assembles long-lived services
  -> Create the menu bar and auxiliary windows
  -> Start refresh, activity monitoring, Automatic Reset, notifications, and power coordination
```

`--hook-event` is the short-lived subprocess mode invoked by Codex. It must finish before any UI, CloudKit, notification, or long-lived service is initialized. Capture failure must not block the main Codex workflow.

In normal mode, `CodexBarAppDelegate` creates and owns long-lived objects, including:

- `CodexStatusService` and `CodexStatusViewModel`
- `CodexProxySettings`
- `WorkflowService` and its view model
- `CodexHookSettings`
- `CodexActivityMonitor`
- `KeepAliveController`
- `AutoResetController`
- `WorkflowSyncSettings` and the sync scheduler
- `CodexNotificationService`
- Menu bar, shortcut, Settings-window, and update services

Before quitting, the app must cancel the Automatic Reset wake schedule and release sleep prevention. If CodexBarHelper has not confirmed that both categories of system state were restored, termination waits or is canceled. Before accepting a new connection at startup, the helper also removes stale wake events for its fixed owner, converging state left by sudden power loss or forced termination.

### Hook Startup Branch

`@NSApplicationDelegateAdaptor` connects the AppKit lifecycle to the SwiftUI app. Once the normal lifecycle begins, it may create menu bar objects, register a notification delegate, or access CloudKit.

The Hook handler runs on Codex's critical path and must behave like a command-line tool. `WorkflowHookEventRecorder.handleIfRequested()` therefore runs at the very beginning of `CodexBarApp.init()` and calls `exit(EXIT_SUCCESS)` immediately when Hook mode matches.

This order also prevents Hook capture failures from contaminating normal-exit diagnostics. `AppProcessDiagnostics.install()` runs only in `applicationDidFinishLaunching`, so a Hook subprocess is not misclassified as a complete app that exited abnormally.

### Termination Coordination

`applicationShouldTerminate` first calls `KeepAliveController.prepareForTermination()` and returns `.terminateLater`.

The app allows termination only after the helper explicitly confirms that the Automatic Reset wake event was canceled and the sleep-prevention release completed. If either cleanup fails, that termination attempt is canceled and the controller returns to normal coordination under the current settings.

Releasing asynchronously in `applicationWillTerminate` is too late because that callback cannot reliably extend process lifetime.

## Three Independent Data Flows

CodexBar does not use a single aggregation service for all state. The three flows have different inputs, freshness needs, and failure semantics:

| Flow | Input | Output | Main consumers |
| --- | --- | --- | --- |
| app-server | `codex app-server` JSON-RPC | Account, rate limits, token usage, Reset Credit use, Hook configuration capabilities | Main panel, menu bar rate limit, Settings, Automatic Reset state machine |
| Hook history | Hook JSONL | Daily event, session, turn, tool, and model aggregations | Activity heatmap, historical metrics, CloudKit |
| Live tasks | Incremental Hook events plus rollout lifecycle | Running, waiting for approval, completed, terminated | Menu bar status, Task Center, notifications, sleep prevention |

### Dependency Direction

```text
CodexStatusService ----------------> CodexStatusViewModel ----------------> UI
CodexStatusViewModel --------------> CodexNotificationService
CodexStatusService ----------------> AutoResetController
CodexStatusViewModel --------------> AutoResetController
AutoResetController ---------------> CodexNotificationService
AutoResetController ---------------> KeepAliveController ---> AutoResetWakeScheduler ---> helper

WorkflowService -------> WorkflowViewModel -----------> UI

Hook + rollout --------> CodexActivityMonitor --------> UI
                              |          |
                              |          +------------> CodexNotificationService
                              `-----------------------> KeepAliveController --> helper
```

Arrows show the direction in which data or read-only state is consumed. A downstream component must not become an upstream source of truth.

### Shared Refresh Triggers

Historical maintenance normally runs after the 60-second rate-limit refresh to reduce resident timers and log noise. The flows share scheduling, not facts.

When changing refresh timing, distinguish among these constraints:

- The trigger source may change
- Maintenance must still be able to run independently when app-server fails
- A lightweight statistics refresh when the UI opens must not implicitly start CloudKit network activity

## Concurrency Boundaries

The project uses Swift 6 strict concurrency with default `MainActor` isolation.

### MainActor Objects

- SwiftUI view models and settings
- AppKit controllers
- `CodexActivityMonitor`
- `KeepAliveController`
- `CodexNotificationService`
- `AutoResetController`
- `AutoResetWakeScheduler`

These objects own observable state and UI coordination. They must not perform blocking I/O directly.

### Actor Services

- `CodexStatusService` manages app-server connections and refreshes
- `WorkflowService` manages historical aggregation
- `HookEventTailReader` manages Hook-file cursors
- `CodexSessionLifecycleReader` manages rollout-file cursors
- `WorkflowSyncService` manages CloudKit state
- `ActivityProtectionStateStore` manages cross-process protection records

DTOs crossing actor boundaries must be immutable value types and declare `Sendable` or `nonisolated` where appropriate.

### Monitor MainActor Boundary

Actors read inputs for `CodexActivityMonitor`, but the state machine itself is closely connected to several Combine consumers.

Keeping the monitor on `MainActor` provides:

- Naturally serialized publication order for `@Published snapshot` and transitions
- Identical state-commit order for notification and sleep-prevention consumers
- Unified ordering of system sleep, wake, Hook-setting changes, and UI lifecycle

The monitor must not perform blocking file reads directly. `HookEventTailReader`, `CodexSessionLifecycleReader`, and `ActivityProtectionStateStore` own those I/O boundaries.

## Model Layers

The project does not reuse one large object directly across app-server DTOs, persistence, and views:

| Model type | Role | Design requirement |
| --- | --- | --- |
| External DTO | Decode app-server, Hook, rollout, or CloudKit data | Tolerate version differences and carry no UI side effects |
| Persistence model | Store recoverable state and schema | Remain compatible with old values and express missing semantics |
| Domain snapshot | Express current trusted state to consumers | Immutable, comparable, and safe across actors |
| Transition | Represent one live state change | Never inferred from historical snapshots; deduplicated upstream |
| Presentation format | Dates, percentages, copy, and colors | Use regional settings or a fixed format for each field; never feed back into business decisions |

For example, `CodexQuotaSnapshot` can carry both a current value and a stale marker. `CodexActivitySnapshot` contains only task fields needed for presentation; raw session IDs do not enter views.

## Lifecycles and Retention

Different states have different lifetimes and cannot share one cache duration:

| State | Lifetime | Reason |
| --- | --- | --- |
| app-server connection | A 1-hour reuse limit checked on requests | Later requests rebuild with the binary on disk |
| app-server supplemental cache | Current account only | Prevents values from leaking across accounts |
| Hook live bootstrap window | 24 hours | Covers long-running tasks that may still be active |
| Completion highlight | 30 seconds | Short menu bar feedback |
| Task Center terminal history | 10 minutes | Provides recent context without occupying the UI indefinitely |
| Terminal deduplication memory | 24 hours | Prevents late Hook or rollout data from reviving old tasks |
| Raw Hook data and daily aggregations | 210 days | Supports long-term metrics and rebuilding |
| Daily-aggregation identity details | 3 days | Balances recent exact deduplication with privacy and file size |
| Activity Protection records | 24 hours after the last progress | Preserves suppression across restarts while limiting identity retention |

Before changing one time window, check for paired invariants. For example, the tail-reader bootstrap window must match the active-task retention window.

## State Ownership

| State | Sole owner | Permissions of other modules |
| --- | --- | --- |
| app-server connection and same-account cache | `CodexStatusService` | Read data, change configuration, or reconnect through service methods |
| Proxy draft, tests, and toggle interaction | `CodexProxySettings` | Settings submits through methods; `CodexStatusService` applies the active connection configuration |
| Main-panel account loading state | `CodexStatusViewModel` | Observe published values |
| Automatic Reset target, deadline, and retries | `AutoResetController` | Settings changes only the switch and lead time |
| Automatic Reset wake-time synchronization | `AutoResetWakeScheduler` | `AutoResetController` submits only the next time; `KeepAliveController` submits only helper readiness |
| Hook installation and validation | `CodexHookSettings` | Read `isOperable` |
| Historical aggregation and maintenance cursor | `WorkflowService` | Request snapshots or rebuilds |
| Live tasks | `CodexActivityMonitor` | Read snapshots or transitions |
| Sync cursors and remote cache | `WorkflowSyncService` | Request merged snapshots |
| Sleep-prevention policy and app assertion | `KeepAliveController` | Read derived state or invoke settings entry points |
| Root sleep ownership | `CodexBarHelper` | Request and query through XPC |
| Root Automatic Reset wake event | `CodexBarHelper` | Replace or cancel one `wake` event for the fixed owner through XPC |
| Notification deduplication | `CodexNotificationService` | Upstream publishes candidate events only |

When adding a consumer, subscribe to an existing snapshot first. If it lacks a field, extend the stable value type at the state owner instead of making the consumer reread raw files.

## Error and Degradation Principles

- On transient network or RPC failure, prefer the last explainable state
- Explicitly represent an unavailable data source; do not disguise it as empty data
- Bootstrap establishes a baseline without sending notifications for historical transitions
- When a reader or data-source generation changes, discard results from the old generation
- Recovery must complete a new read barrier before evaluation continues
- Persistent writes require atomic replacement or file locking to avoid corruption from concurrent Debug and Release processes

### Error Classification

| Error class | Typical handling | Incorrect handling |
| --- | --- | --- |
| Explicitly unsupported capability | Cache method unsupported and show the source as unavailable | Retry every minute or display `0` |
| Transient business failure | Use stale cache scoped to the same account | Clear the entire account snapshot |
| Transport failure | Discard the connection and rebuild it at most once | Continue sending requests over an untrusted pipe |
| Data-source identity change | Start a new generation and rebuild from the raw source | Continue appending from the old offset |
| Late asynchronous result | Discard when generations differ | Overwrite new settings or new reader state |
| Uncertain privileged state | Retain the possible lease or wake event and actively confirm cleanup | Assume the helper did nothing |
| Hook recorder failure | Drop this capture and exit successfully | Block Codex or present UI |

## System Integration

| Capability | System interface |
| --- | --- |
| Menu bar | `NSStatusItem` |
| Main panel | `NSPopover` and a floating fallback panel |
| Global shortcut | Carbon Hot Key API |
| App idle-sleep prevention | IOKit power assertion |
| System-sleep control | CodexBarHelper invokes `/usr/bin/pmset` with fixed arguments |
| Automatic Reset system wake | CodexBarHelper calls `IOPMSchedulePowerEvent` and `IOPMCancelScheduledPowerEvent` |
| CodexBarHelper installation and launch | `SMAppService` |
| App-to-CodexBarHelper communication | XPC |
| Notifications | `UNUserNotificationCenter` |
| Cloud sync | CloudKit private database |
| Automatic updates | Sparkle |

## Key Source Files

- [`CodexBarApp.swift`](../../../CodexBar/App/CodexBarApp.swift) defines the startup entry point
- [`CodexBarAppDelegate.swift`](../../../CodexBar/Controllers/CodexBarAppDelegate.swift) assembles services in normal mode
- [`StatusItemController.swift`](../../../CodexBar/Controllers/StatusItemController.swift) orchestrates the menu bar
- [`CodexStatusService.swift`](../../../CodexBar/Services/CodexStatus/CodexStatusService.swift) manages app-server
- [`WorkflowService.swift`](../../../CodexBar/Services/Workflow/WorkflowService.swift) manages historical Hook aggregation
- [`CodexActivityMonitor.swift`](../../../CodexBar/Services/Workflow/CodexActivityMonitor.swift) manages live tasks
- [`AutoResetController.swift`](../../../CodexBar/Services/CodexStatus/AutoResetController.swift) manages Automatic Reset targets and retries
- [`AutoResetWakeScheduler.swift`](../../../CodexBar/Services/KeepAlive/AutoResetWakeScheduler.swift) synchronizes the next system wake time
- [`KeepAliveController.swift`](../../../CodexBar/Services/KeepAlive/KeepAliveController.swift) manages helper registration, sleep-prevention policy, and wake-scheduler readiness
- [`WorkflowSyncService.swift`](../../../CodexBar/Services/Workflow/WorkflowSyncService.swift) manages CloudKit sync
- [`CodexBarHelperXPC.swift`](../../../Shared/CodexBarHelperXPC.swift) defines the constrained privileged interface
- [`CodexBarHelper/main.swift`](../../../CodexBarHelper/main.swift) executes and validates system sleep and wake operations

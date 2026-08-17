# Architecture

[简体中文](../../DeveloperGuide/architecture.md) | English

## What This Architecture Solves

CodexBar's central challenge is not drawing a menu bar interface. It is coordinating short-lived Hook subprocesses, a local app-server, append-only files, CloudKit, system notifications, and a root helper inside a long-running `LSUIElement` app.

See the [interactive runtime architecture diagram](https://codexbar.zabrian.app/architecture) for the full component relationships, data flows, and source references.

The architecture must continuously satisfy these goals:

- A failure in one data flow must not disable unrelated features
- Short-lived Hook mode and normal app mode share an executable but have completely isolated lifecycles
- The UI observes explainable snapshots and does not own I/O, deduplication, or recovery logic
- Privileged operations expose the smallest possible interface while business policy remains in the unprivileged app process
- Every asynchronous result can prove that it still belongs to the current configuration and data-source generation
- Rebuildable data remains separate from side effects that cannot be replayed

For the broader rationale, see [Design Principles and Key Decisions](design-decisions.md).

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
| app-server | Reused for up to 1 hour | Expose account and configuration capabilities through JSON-RPC | Substitute for Hook history or live task state |
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

The initialization order in [`CodexBarApp.swift`](../../../CodexBar/App/CodexBarApp.swift) is an architectural constraint, not an implementation detail:

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
- `WorkflowService` and its view model
- `CodexHookSettings`
- `CodexActivityMonitor`
- `KeepAliveController`
- `AutoResetController`
- `WorkflowSyncSettings` and the sync scheduler
- `CodexNotificationService`
- Menu bar, shortcut, Settings-window, and update services

Before quitting, the app must cancel the Automatic Reset wake schedule and release sleep prevention. If CodexBarHelper has not confirmed that both categories of system state were restored, termination waits or is canceled. Before accepting a new connection at startup, the helper also removes stale wake events for its fixed owner, converging state left by sudden power loss or forced termination.

### Why Hook Detection Must Run in `App.init`

`@NSApplicationDelegateAdaptor` connects the AppKit lifecycle to the SwiftUI app. Once the normal lifecycle begins, it may create menu bar objects, register a notification delegate, or access CloudKit.

The Hook handler runs on Codex's critical path and must behave like a command-line tool. `WorkflowHookEventRecorder.handleIfRequested()` therefore runs at the very beginning of `CodexBarApp.init()` and calls `exit(EXIT_SUCCESS)` immediately when Hook mode matches.

This order also prevents Hook capture failures from contaminating normal-exit diagnostics. `AppProcessDiagnostics.install()` runs only in `applicationDidFinishLaunching`, so a Hook subprocess is not misclassified as a complete app that exited abnormally.

### Why AppDelegate Owns Long-Lived Objects

SwiftUI may recreate views because of layout, conditional branches, or window reconstruction. If a view owned a service, an ordinary UI change could terminate a reader, app-server, or XPC connection.

`CodexBarAppDelegate` therefore acts as the composition root:

- It is the only place that creates long-lived services, settings, and view models
- It wires callbacks among monitoring, notifications, and keep-alive coordination
- Views receive references that already exist
- Shutdown stops services in reverse order from the same owner

This does not place all logic in AppDelegate. It owns assembly and lifecycle only; business rules remain in their services or controllers.

### Why Termination Can Be Canceled

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

The flows may share infrastructure and models, but they cannot replace one another:

- app-server does not provide complete live task state
- Historical aggregation may be delayed or rebuilt; live tasks cannot wait for aggregation
- Live task snapshots cannot be a persistent source for historical metrics
- If one flow becomes unavailable, the others must remain available

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

For example, the menu bar may draw rate-limit progress and task state in one icon, but whether that icon exists must not decide whether the task monitor runs. The sync scheduler may reuse a historical-maintenance trigger, but CloudKit availability must not decide whether local aggregation runs.

### A Shared Trigger Is Not a Data Dependency

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

### Why the Monitor Still Runs on MainActor

Actors read inputs for `CodexActivityMonitor`, but the state machine itself is closely connected to several Combine consumers.

Keeping the monitor on `MainActor` provides:

- Naturally serialized publication order for `@Published snapshot` and transitions
- Identical state-commit order for notification and sleep-prevention consumers
- Unified ordering of system sleep, wake, Hook-setting changes, and UI lifecycle

The monitor must not perform blocking file reads directly. `HookEventTailReader`, `CodexSessionLifecycleReader`, and `ActivityProtectionStateStore` own those I/O boundaries.

### Why the Nonisolated Pipe Reader Uses a Lock

app-server communicates over stdio, requiring a combination of `FileHandle`, `DispatchSourceRead`, and semaphores. These types are not naturally `Sendable`, and crossing a Swift actor hop for every line is unsuitable.

`PipeReadBuffer` confines the unsafe boundary to one `@unchecked Sendable` type. An `NSLock` protects all mutable state, read events stay on a dedicated queue, and the caller sees only complete lines and closed state.

Here, `@unchecked` is a localized promise backed by encapsulation, not a way to disable concurrency checks for the whole module.

### Why Cross-Process Files Need More Than an Actor

The Hook recorder runs in another process, so the `WorkflowService` actor cannot protect it. `stats.lock` uses `flock` to provide a process-wide exclusive transaction over joint changes to event files and maintenance state.

The same flow therefore uses both an actor and `flock`:

- The actor prevents maintenance operations inside the main app from changing state concurrently
- `flock` prevents the main app and short-lived Hook subprocesses from committing conflicting file changes at the same time

## Model Layers

The project does not reuse one large object directly across app-server DTOs, persistence, and views:

| Model type | Role | Design requirement |
| --- | --- | --- |
| External DTO | Decode app-server, Hook, rollout, or CloudKit data | Tolerate version differences and carry no UI side effects |
| Persistence model | Store recoverable state and schema | Remain compatible with old values and express missing semantics |
| Domain snapshot | Express current trusted state to consumers | Immutable, comparable, and safe across actors |
| Transition | Represent one live state change | Never inferred from historical snapshots; deduplicated upstream |
| Presentation format | Dates, percentages, copy, and colors | Follow the locale and never feed back into business decisions |

For example, `CodexQuotaSnapshot` can carry both a current value and a stale marker. `CodexActivitySnapshot` contains only task fields needed for presentation; raw session IDs do not enter views.

## Lifecycles and Retention

Different states have different lifetimes and cannot share one cache duration:

| State | Lifetime | Reason |
| --- | --- | --- |
| app-server connection | Up to 1 hour | Reuse reduces startup cost; periodic reconstruction picks up on-disk upgrades |
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

Live task state has one authoritative source: [`CodexActivityMonitor.swift`](../../../CodexBar/Services/Workflow/CodexActivityMonitor.swift).

Its snapshot is consumed by:

- The menu bar icon and main-panel task card
- Task Center
- Completion and approval-request notifications
- Sleep-prevention eligibility
- Stalled Task Protection

Consumers may present the snapshot or perform side effects from it, but must not rebuild separate task state machines.

### State Ownership Table

| State | Sole owner | Permissions of other modules |
| --- | --- | --- |
| app-server connection and same-account cache | `CodexStatusService` | Request read-only results |
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

### Error Classification Matters More Than Uniform Retries

| Error class | Typical handling | Incorrect handling |
| --- | --- | --- |
| Explicitly unsupported capability | Cache method unsupported and show the source as unavailable | Retry every minute or display `0` |
| Transient business failure | Use stale cache scoped to the same account | Clear the entire account snapshot |
| Transport failure | Discard the connection and rebuild it at most once | Continue sending requests over an untrusted pipe |
| Data-source identity change | Start a new generation and rebuild from the raw source | Continue appending from the old offset |
| Late asynchronous result | Discard when generations differ | Overwrite new settings or new reader state |
| Uncertain privileged state | Retain the possible lease or wake event and actively confirm cleanup | Assume the helper did nothing |
| Hook recorder failure | Drop this capture and exit successfully | Block Codex or present UI |

### Why Logs Record Stages Instead of User Data

System logs explain control flow with `trigger`, `stage`, `reason`, `counts`, and `elapsed`, without recording rate-limit values, project paths, or task identities.

This structure can distinguish whether:

- Sync failed during zone, device, fetch, upload, or prune
- app-server created or reused a connection
- Aggregation was a no-op, incremental write, or dirty rebuild
- A particular condition blocked sleep prevention

Diagnostics need control-flow evidence, not copies of user data.

## Where to Make a Core-Flow Change

### Adding a Data Source

1. Decide whether it belongs to one of the existing three flows
2. Define source-missing, stale, and failure semantics
3. Perform I/O and caching inside an actor service
4. Cross into MainActor through an immutable snapshot
5. Review network and privacy boundaries separately

### Adding a One-Time Side Effect

1. Find a live transition that proves the event just occurred
2. Do not infer it from a current snapshot or historical list
3. Define in-process and cross-restart deduplication scopes
4. Check immediately before submission that the event is still relevant
5. Define whether side-effect failure may affect primary state

### Adding Persistent State

1. Explain why in-memory state is insufficient
2. Define the schema, atomicity, and concurrent-access boundary
3. Define how old versions read new files and new versions read old files
4. Limit stored fields and retention
5. Confirm the compatibility strategy before changing the format

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

# CodexBar Developer Guide

[简体中文](../../DeveloperGuide/README.md) | English

This guide is for developers who want to understand CodexBar's architecture, debug its data flows, or contribute to the project.

It describes not only what each module does, but also why responsibilities are divided this way, which failure paths are intentionally conservative, and which invariants must survive implementation changes.

For product features and instructions, see the [User Guide](../UserGuide/README.md).

## Goals

The Developer Guide should help readers with four kinds of work:

- Build a system model: understand where data originates, where it becomes state, and which component ultimately consumes it
- Find the right place to make a change: identify the sole owner of a behavior and the boundary of its side effects
- Understand design tradeoffs: avoid simplifying away seemingly redundant generations, stale markers, or recovery steps
- Validate changes: derive acceptance coverage from invariants and failure scenarios

Each topic follows roughly the same structure:

```text
Goals and constraints
  -> Data or control flow
  -> State ownership
  -> Key design rationale
  -> Failure and recovery
  -> Change guide
  -> Validation scenarios
```

## Reading Order

If you are new to the project, read these topics in order:

1. [Architecture](architecture.md)
2. [Design Principles and Key Decisions](design-decisions.md)
3. [app-server Data Flow](app-server.md)
4. [Hook Capture and Historical Aggregation](hook-and-aggregation.md)
5. [Live Task Monitoring](activity-monitor.md)
6. [Sleep Prevention System](sleep-prevention.md)
7. [CloudKit Sync](sync.md)
8. [Notification System](notifications.md)
9. [UI and App Lifecycle](ui-and-lifecycle.md)
10. [Data and Privacy Boundaries](data-and-privacy.md)
11. [Development and Validation](development.md)

## Find by Responsibility

| Document | Contents |
| --- | --- |
| [Architecture](architecture.md) | Processes, modules, lifecycle, actor boundaries, and the three data flows |
| [Design Principles and Key Decisions](design-decisions.md) | Cross-module rationale, system invariants, failure priorities, and subtle implementation details |
| [app-server Data Flow](app-server.md) | CLI discovery, JSON-RPC sessions, account data, rate limits, usage refresh, and the Automatic Reset state machine |
| [Hook Capture and Historical Aggregation](hook-and-aggregation.md) | Hook installation, event persistence, aggregation, retention, and schema evolution |
| [Live Task Monitoring](activity-monitor.md) | Incremental reading, rollout reconciliation, task state machine, and Stalled Task Protection |
| [Sleep Prevention System](sleep-prevention.md) | IOKit assertions, CodexBarHelper, XPC leases, Automatic Reset wake schedules, and recovery |
| [CloudKit Sync](sync.md) | Private database, device pseudonymization, upload, merge, and rebuild |
| [Notification System](notifications.md) | Notification triggers, deduplication, sounds, haptics, and click behavior |
| [UI and App Lifecycle](ui-and-lifecycle.md) | Menu bar, panels, focus, global shortcuts, and service assembly |
| [Data and Privacy Boundaries](data-and-privacy.md) | Local files, network access, cloud fields, and logging boundaries |
| [Development and Validation](development.md) | Project structure, build checks, debugging, and change acceptance |

## Find by Change

| Change | Read first | Also review |
| --- | --- | --- |
| Add an account or usage field | [app-server Data Flow](app-server.md) | [Data and Privacy Boundaries](data-and-privacy.md) |
| Add a Hook event or historical metric | [Hook Capture and Historical Aggregation](hook-and-aggregation.md) | [CloudKit Sync](sync.md) |
| Change task states or terminal-state detection | [Live Task Monitoring](activity-monitor.md) | [Notification System](notifications.md), [Sleep Prevention System](sleep-prevention.md) |
| Change a menu, window, or shortcut | [UI and App Lifecycle](ui-and-lifecycle.md) | [Development and Validation](development.md) |
| Change notification triggers or deduplication | [Notification System](notifications.md) | The guide for the corresponding data source |
| Change sleep-prevention policy or the helper | [Sleep Prevention System](sleep-prevention.md) | [Data and Privacy Boundaries](data-and-privacy.md) |
| Change Automatic Reset scheduling or wake plans | [app-server Data Flow](app-server.md) | [Sleep Prevention System](sleep-prevention.md), [Data and Privacy Boundaries](data-and-privacy.md) |
| Change sync fields or merge rules | [CloudKit Sync](sync.md) | [Hook Capture and Historical Aggregation](hook-and-aggregation.md) |
| Change persistence formats or defaults | [Development and Validation](development.md) | [Design Principles and Key Decisions](design-decisions.md) |

## Core Design Constraints

- Startup must handle `--hook-event` mode first; that mode must not initialize the UI
- app-server rate limits and usage, historical Hook aggregation, and live task monitoring are three independent data flows
- `CodexActivityMonitor` is the sole source of task state
- UI, controllers, view models, and settings run on `MainActor` by default
- Blocking I/O and shared mutable state must stay off the main actor
- CodexBarHelper is limited to fixed sleep controls and Automatic Reset wake schedules; it must not gain network access, arbitrary command execution, or additional file access
- Hook configuration changes must preserve handlers installed by the user and other applications
- Changes to aggregation semantics must increment the aggregation schema and fully rebuild from raw events
- A missing Hook count means the historical source is unavailable; it must not be interpreted as an explicit `0`

## Core Terminology

| Term | Precise meaning in this project |
| --- | --- |
| snapshot | Repeatable current state; it does not imply that an event just occurred |
| transition | A one-time state change from trusted live input that may drive side effects such as notifications |
| bootstrap | Restoring an in-memory baseline from existing local data without replaying historical side effects |
| stale | An old value is available for display, but the source could not confirm it in the current cycle |
| unavailable | No trusted source is currently available; this is not equivalent to empty or `0` |
| generation | The generation of a data source or asynchronous operation, used to reject late results |
| source generation | The source identity of a day's raw Hook file; distinct from a code schema |
| owned | CodexBar changed the system state and is entitled to restore it |
| external | A source outside CodexBar had already set the system state |

## How to Read the Source

Identify the state owner first, then read backward from its consumers.

For example, when changing approval-waiting behavior, use this order:

```text
CodexActivityTask
  -> CodexActivityMonitor
  -> CodexActivitySnapshot / transition
  -> CodexNotificationService
  -> KeepAliveController
  -> SwiftUI View
```

Starting from a view usually reveals only the final display condition and makes it easy to miss bootstrap, deduplication, and recovery semantics.

## Main Entry Points

- App startup: [`CodexBarApp.swift`](../../../CodexBar/App/CodexBarApp.swift)
- Service assembly: [`CodexBarAppDelegate.swift`](../../../CodexBar/Controllers/CodexBarAppDelegate.swift)
- app-server service: [`CodexStatusService.swift`](../../../CodexBar/Services/CodexStatus/CodexStatusService.swift)
- Hook subprocess entry: [`WorkflowHookEventRecorder.swift`](../../../CodexBar/Services/Workflow/WorkflowHookEventRecorder.swift)
- Live task state machine: [`CodexActivityMonitor.swift`](../../../CodexBar/Services/Workflow/CodexActivityMonitor.swift)
- Automatic Reset state machine: [`AutoResetController.swift`](../../../CodexBar/Services/CodexStatus/AutoResetController.swift)
- Automatic Reset wake synchronization: [`AutoResetWakeScheduler.swift`](../../../CodexBar/Services/KeepAlive/AutoResetWakeScheduler.swift)
- Sleep-prevention orchestration: [`KeepAliveController.swift`](../../../CodexBar/Services/KeepAlive/KeepAliveController.swift)
- CodexBarHelper: [`main.swift`](../../../CodexBarHelper/main.swift)

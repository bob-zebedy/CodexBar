# CodexBar Developer Guide

[简体中文](../../DeveloperGuide/README.md) | English

## Find by Responsibility

| Document | Contents |
| --- | --- |
| [Architecture](architecture.md) | Processes, modules, lifecycle, actor boundaries, and the three data flows |
| [Design Principles and Key Decisions](design-decisions.md) | State ownership, concurrent commits, data recovery, and privilege boundaries |
| [app-server Data Flow](app-server.md) | CLI discovery, proxy configuration and tests, JSON-RPC sessions, account data, rate limits, usage refresh, and Automatic Reset |
| [Hook Capture and Historical Aggregation](hook-and-aggregation.md) | Hook installation, event persistence, aggregation, retention, and schema evolution |
| [Live Task Monitoring](activity-monitor.md) | Incremental reading, rollout reconciliation, task state machine, and Stalled Task Protection |
| [Sleep Prevention System](sleep-prevention.md) | IOKit assertions, CodexBarHelper, XPC leases, Automatic Reset wake schedules, and recovery |
| [CloudKit Sync](sync.md) | Private database, device pseudonymization, upload, merge, and rebuild |
| [Notification System](notifications.md) | Notification triggers, deduplication, sounds, haptics, and click behavior |
| [UI and App Lifecycle](ui-and-lifecycle.md) | Menu bar, panels, focus, global shortcuts, and service assembly |
| [Data and Privacy Boundaries](data-and-privacy.md) | Local files, network access, cloud fields, and logging boundaries |
| [Development and Validation](development.md) | Project structure, build checks, debugging, and change acceptance |

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
| owned | CodexBar has persisted responsibility for restoring system sleep |
| external | A source outside CodexBar had already set the system state |

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

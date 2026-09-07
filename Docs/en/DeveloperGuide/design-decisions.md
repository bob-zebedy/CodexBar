# Design Principles and Key Decisions

[简体中文](../../DeveloperGuide/design-decisions.md) | English

## State Ownership

Each data flow has one service owning its facts; consumers read snapshots or transitions:

| Flow | Source of state | Output use |
| --- | --- | --- |
| app-server | Account, quota, and usage responses | Periodic display with same-account stale-cache fallback |
| Hook history | Raw JSONL | Rebuildable daily statistics and cross-device sync |
| Live tasks | Incremental Hook events and rollout lifecycle | Activity snapshots, task alerts, and sleep prevention |

Snapshots can be read repeatedly. Notifications use live transitions; bootstrap establishes a baseline without replaying historical alerts. Historical aggregation shares some refresh triggers with quota, but reads and failure handling remain independent. See [Architecture](architecture.md) for component relationships.

## User Intent and Actual Effects

A saved switch expresses intent, dependencies determine whether execution is possible, and result state expresses a confirmed effect. Temporary dependency failures preserve the user’s switch and reconcile again on recovery.

Sleep prevention represents these layers with `isEnabled`, `sleepBlockReason`, and `isPreventingSleep`. Hook combines `isEnabled` and `isVerified` into `isOperable`; live tasks require operability, while historical aggregation can still process recorded data.

## Missing, Stale, and Untrusted Data

| State | Current handling |
| --- | --- |
| Temporary app-server supplemental failure | Use same-account stale cache with reduced UI opacity; do not trigger quota alerts or automatic redemption |
| Unsupported method | Cache missing capability for the session and probe again after rebuilding the connection |
| Missing historical Hook count | Retain `nil` in persisted and sync models; current display projection still falls back to counts |
| Live reader cannot obtain a stable boundary | Publish degraded health and pause Activity Protection |

The source layer supplies these states; consumers determine whether to display data or perform effects. See [Hook Aggregation](hook-and-aggregation.md) for count projection and [app-server](app-server.md) for account caches.

## Concurrency and Stale Results

| Mechanism | Protected scope |
| --- | --- |
| `MainActor` | UI, controllers, and observable-state commit ordering |
| Actors | Shared service state and I/O coordination within a process |
| `NSLock` and similar locks | Mutable state behind synchronous interfaces such as nonisolated pipe readers |
| `flock` | Shared-file transactions across Hook subprocesses, the main app, Debug, and Release |

Configuration or readers may change while an asynchronous call runs. Noncancelable system callbacks validate their generation before committing. Cancellation controls task lifetime; generation checks establish result ownership.

Menu fade completion commits synchronously after checking cancellation, so it keeps one cancelable task. XPC, reader replacement, and wake recovery still require generations; their fields are documented in the corresponding topics.

Combine’s `@Published` emits during `willSet`. Combined-setting decisions use the new value delivered to the subscription instead of rereading a property that has not changed yet.

## Rebuildable Data and Recovery Records

Raw Hook JSONL is the source for rebuilding history; daily aggregates are derived output. Aggregation-semantic changes increment the schema and rebuild retained history. `sourceGeneration` distinguishes file replacements: same-day, same-source data replaces a contribution, while independent sources add together.

Activity Protection and helper ownership records recover state changes that have already occurred. Protection saves asynchronously and does not wait for disk before hiding a task. The helper persists recovery responsibility before changing system sleep state. See [Live Task Monitoring](activity-monitor.md) and [Sleep Prevention](sleep-prevention.md) for ordering.

## Privileged Operations and Upload Scope

Task identification, Automatic Reset policy, and networking run in the main app. The root helper accepts only fixed sleep-lease and wake operations, validates client signatures, and reads back system results.

CloudKit syncs only daily aggregates. Raw events, session identifiers, account data, and proxy passwords remain local. Project display names are uploaded only after the user enables sync. See [Data and Privacy Boundaries](data-and-privacy.md) for fields and storage scope.

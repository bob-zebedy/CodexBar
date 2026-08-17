# Design Principles and Key Decisions

[简体中文](../../DeveloperGuide/design-decisions.md) | English

This document explains why CodexBar has its current structure and which problems that structure solves.

It is neither a source-tree index nor a feature list. Its purpose is to establish decision criteria: when implementation must change, which mechanisms are replaceable and which system invariants must remain true.

## Deriving the Architecture from Product Goals

CodexBar may look like a simple menu bar app, but it crosses four fundamentally different boundaries:

- Codex's local protocol and configuration
- Continuously changing Hook and rollout files
- macOS windows, notifications, and power management
- Root-privileged control of system sleep and scheduled wake

These boundaries cannot share one failure strategy.

For example, preserving the previous value is usually more useful than clearing it when a rate-limit refresh fails. A failed Hook capture must be abandoned immediately because statistics must never block Codex. A failed sleep-state release, however, must not be ignored during exit because CodexBar may still own system state.

The project therefore avoids one global service that does everything. It separates components first by input source and failure semantics, then combines read-only snapshots at the UI and side-effect layers.

## Decision Priorities

Resolve implementation tradeoffs in this order:

1. Do not block the Codex task the user is running
2. Do not leave behind or incorrectly change system-level state
3. Do not present old, missing, or uncertain data as a current fact
4. Do not let a late asynchronous result overwrite newer user intent
5. Do not broaden the boundaries of privileged processes, network access, or persisted data
6. Only then optimize latency, file size, and UI animation

This order explains several intentionally asymmetric behaviors:

- A Hook recorder drops the current statistic after a lock timeout instead of waiting longer
- App termination may be delayed until the helper confirms release of CodexBar-owned sleep state and cancellation of the Automatic Reset wake schedule
- A failed supplemental app-server request may show stale cached data, but an unsupported method must show that the source is unavailable
- Stalled Task Protection remains paused if wake recovery has not passed a new Hook read barrier

## Facts, Snapshots, and Side Effects

Project state has three layers:

| Layer | Meaning | Examples |
| --- | --- | --- |
| Fact | An input that has occurred in an external system or local log | Hook event, rollout terminal, app-server response |
| Snapshot | Displayable state derived from facts under current rules | `CodexQuotaSnapshot`, `WorkflowSnapshot`, `CodexActivitySnapshot` |
| Side effect | A one-time action caused by a trusted state change | Notification, haptic feedback, XPC lease, CloudKit upload |

Views intentionally do not execute side effects from raw facts.

For example, the notification service does not scan Task Center and guess which task just completed; it consumes transitions published by the monitor. The sleep-prevention controller does not parse Hook data; it consumes running and waiting tasks in the activity snapshot.

This has two benefits:

- A snapshot may be read repeatedly, while a transition must be consumed at most once
- One state machine handles bootstrap, deduplication, late events, and rollout reconciliation consistently, so consumers do not implement similar but divergent rules

## Why the Three Data Flows Must Remain Independent

### app-server Flow

app-server provides periodic snapshots of account, rate-limit, and token usage data. Minute-level refreshes are appropriate, and transient failures may fall back to a same-account cache.

### Historical Hook Flow

The historical flow converts append-only raw events into daily aggregations. It may be delayed and rebuilt from raw JSONL; long-term consistency is its primary goal.

### Live Task Flow

The live flow tracks task states and one-time transitions on a seconds-level timescale. It combines Hook and rollout data, cannot wait for daily aggregation, and must not treat a terminal state from ten minutes ago as a new notification.

Combining the three produces incorrect coupling:

- A transient app-server failure would erase local task state that remains readable
- An aggregation rebuild would block live task updates
- Terminal deduplication designed for notifications would contaminate historical counts
- CloudKit or network failures would affect local Hook presentation

The UI may combine the flows, but they must never become sources of fact for one another. This is one of CodexBar's most important architectural boundaries.

## User Intent, Dependency Availability, and Actual Effect

Settings-driven features usually have three distinct states:

```text
User intent -> Dependency availability -> Actual effect
```

Sleep prevention is the clearest example:

- `isEnabled` means the user allows CodexBar to manage sleep
- Hook, helper, battery, and duration state determine whether execution is currently possible
- `isPreventingSleep` means the app and helper have confirmed the actual effect

A temporarily unavailable dependency must not write `false` back to `isEnabled`. Otherwise, one RPC failure would permanently change a user preference and prevent automatic recovery.

Hook settings make a similar distinction:

- `isEnabled` means the handler is installed in the configuration file
- `isVerified` means app-server most recently returned an explicit usable result
- `isOperable` is the state downstream dependencies should consume

This three-layer model has more states than one Boolean but avoids merging configuration, diagnostics, and effect into an unexplained switch.

## Uncertainty Must Appear in Types and UI

Several parts of the project preserve `nil`, stale, or degraded state instead of converting everything to zero or an empty array.

### Missing Is Not Zero

When old Hook data lacks a count field, `nil` means the capture capability did not exist at that time. Only `0` means the source explicitly confirms that nothing occurred.

Merging them would draw unknown history as real zeroes and make the interpretation impossible to repair later.

### Stale Is Not Failure

If a supplemental app-server method fails temporarily for the same account, old rate-limit or usage values remain useful. The snapshot marks them with `isRateLimitsStale` and `isUsageStale`; the UI uses opacity to show reduced confidence, while notifications skip stale rate limits entirely.

### Degraded Bootstrap Is Not Idle

If the live reader cannot obtain a stable file boundary, it moves to the end of the file while also publishing degraded state and an unhealthy data source. This means “existing tasks cannot be recovered reliably,” not “there are definitely no tasks.”

## Why Generations Are Used Extensively

Most CodexBar I/O shares this race:

1. Request A begins
2. The user changes a setting or the reader is replaced
3. Request B begins and finishes first
4. Request A returns last

Canceling a `Task` is not enough. Some system APIs and synchronous bridges cannot truly cancel, so old callbacks may still arrive.

Critical asynchronous paths therefore maintain monotonically increasing generations:

- The refresh coordinator allows only the current generation to commit
- Hook settings allow only the latest operation to update UI
- Replacing a tail reader invalidates batches from the old reader
- Wake recovery validates both reader and recovery generations
- XPC lease requests use generations so a late acquire cannot overwrite a release
- Helper-state requests and CloudKit availability checks also discard old results by generation

The value of a generation is not easier cancellation. It turns permission to commit into an explicit, verifiable condition.

## Why the Project Uses Actors, MainActor, and Locks

Each mechanism covers a different boundary:

| Mechanism | Scope | Typical objects |
| --- | --- | --- |
| `MainActor` | UI-observable state and AppKit lifecycle | Controllers, view models, settings, monitor |
| Swift actor | Asynchronous mutable state within one process | app-server, aggregation, readers, CloudKit service |
| `flock` | Transactions over files shared across processes | Hook recorder and main-app statistics files |

An actor cannot protect another CodexBar Hook subprocess. `flock` is unsuitable for UI state. Choose the concurrency tool based on where contention occurs rather than forcing every synchronization problem into actors because the project already uses them.

Default `MainActor` isolation makes UI types safer, but every blocking file or pipe wait must explicitly move off the main actor. `AppServerSession` and its pipe reader use locked nonisolated boundaries, while the higher-level `CodexStatusService` actor serializes connection management.

## Why Raw Logs and Derived Caches Are Separate

Raw Hook JSONL is an auditable fact source; `daily.jsonl` is a cache generated by the current algorithm.

This structure provides three long-term benefits:

- Historical data can be rebuilt after an aggregation fix without designing a migration for every old field
- The write-critical path appends one line instead of reading and rewriting all statistics during the few seconds Codex is waiting
- CloudKit sync can upload only aggregations, leaving raw identities and paths on the Mac

The cost is explicit management of schemas, offsets, and source replacement. Maintenance state therefore stores `sourceGeneration`, inode, size, boundary hash, and dirty/pending state.

## `sourceGeneration` Is Not a Version Number

An event file for a given day may be replaced, truncated, or rebuilt by the user. The same date does not prove that it is the same fact source.

`sourceGeneration` gives “which generation of raw file produced this day's data” a stable identity:

- Normal appends preserve the generation
- An inode change, file shrink, or rewrite before the consumed boundary creates a new generation
- CloudKit record names can distinguish generations
- The presentation layer adds clearly independent contributions and treats same-source results as replacements

If date alone were the identity, a rebuilt value would be added to the old cloud value and create permanent double counting.

## Why Live Tasks Read Both Hook and Rollout Data

Each source solves only half of the problem:

| Source | Strength | Gap |
| --- | --- | --- |
| Hook | Low latency, clear event types, suitable for live UI | `Stop` cannot always distinguish completion from interruption; some context fields may be missing |
| rollout | More authoritative terminal, effort, and reviewer fields | Slower file discovery and parsing; unsuitable as the only low-latency signal |

The monitor first establishes active state from Hook data, then fills in lifecycle details from rollout files. `Stop` creates a completion candidate. `SessionEnd` or a new prompt moves the task into a short terminal-confirmation window, and rollout provides accurate classification during the grace period.

This is not a simple two-source merge. Conflicts require semantic authority rules, and late events must not revive a task that already completed.

## Why the Privileged Helper Accepts Only Constrained Power Operations

The app needs root privileges to change `pmset disablesleep` and schedule system `wake` events. Task identification, Automatic Reset policy, network access, and file parsing do not require root.

Putting policy in the helper would greatly expand its attack surface and recovery scope. The current boundary keeps it a small executor:

- Inputs are limited to sleep leases, generations, state queries, update-recovery markers, and bounded Unix wake timestamps
- Sleep commands are fixed argument combinations for `/usr/bin/pmset`; wake schedules use a fixed CodexBar owner and `wake` type
- Clients are validated through code-signing requirements
- The helper does not read Codex files, access the network, or accept arbitrary paths or commands

The app decides what should happen; the helper executes and verifies it with constrained privileges.

## Why Leases Still Need Ownership Records

A lease answers whether an active app still requests the effect. Ownership answers whether CodexBar changed the current system value.

Neither can replace the other:

- When no lease remains, the helper should revoke its own effect
- If `SleepDisabled=1` was originally set by the user or another app, CodexBar has no right to restore it to `0`
- If CodexBar completed `0 -> 1`, the helper must persist owned state first so it can recover after a crash

The release condition is therefore “the last lease ended and ownership is owned,” not simply “there are no clients, so write `0`.”

## Why CloudKit Syncs Aggregations Instead of Raw Events

Cross-device presentation needs only daily metrics. Uploading raw events would expose more identity data, increase volume, and complicate deduplication without enabling a current product capability.

Benefits of syncing aggregations include:

- Session, turn, and agent IDs remain local
- Network and CloudKit operations scale with days rather than events
- Each Mac can still rebuild independently, while the cloud stores only per-device contributions
- Cross-device merge rules can be defined around `deviceId + date + sourceGeneration`

Project display names may still be sensitive, so sync must be explicitly enabled. Signing in to iCloud must never upload them by default.

## Subtle but Important Details

### `@Published` Callback Arguments Are More Reliable Than Immediate Reads

Combine publishes during `willSet`. When a subscriber closure runs, the property itself may still contain the old value.

Subscriptions for Hook availability, sync activation, and sleep-prevention dependencies therefore calculate from closure arguments instead of immediately reading the object property again. This explains several seemingly redundant state mirrors.

### The Boundary Hash Covers Only the Consumed Tail

Historical aggregation does not hash every file in full on every cycle. It stores a boundary hash for the 4 KB before the offset and uses mtime to decide whether to recompute it.

Normal appends occur after the offset and do not change this boundary. This detects in-place rewrites of consumed content without holding `stats.lock` for long, letting Hook subprocesses persist events quickly.

### State Sorting Uses UUID as a Tie-Breaker

Several tasks may share a timestamp, and Swift sorting is unstable. Snapshots break timestamp ties with the UUID string so SwiftUI diffing does not repeatedly refresh because of meaningless order changes.

### Notifications Recheck Relevance Before Submission

An asynchronous window exists between deciding to notify about an approval request or stalled task and the system actually accepting it. The task may already have resumed.

Before every submission or retry, the notification service calls `isStillRelevant`. If it is false, pending and delivered notifications are withdrawn. This is more reliable than attempting removal only when state changes.

### An XPC Timeout Cannot Clear a “Possible Lease”

A timeout proves only that the reply did not arrive; it does not prove that the helper failed to acquire the lease. `mayHaveHelperLease` therefore remains true until an explicitly successful release.

Clearing it on timeout could make app termination skip release and leave the helper waiting for its watchdog before restoring system state.

### External Sleep Sources Need Continuous Observation

If the system already has `SleepDisabled=1` when a task starts, the helper marks the source external. That source may remove its setting while the task is still running.

The helper periodically reads the actual value. If the external effect disappears while a lease remains valid, CodexBar can safely perform its own `0 -> 1` transition, take ownership, and keep sleep prevention from silently ending.

### Menu Bar Anchors Must Be Validated

When a global shortcut fires, the `NSStatusBarButton` may temporarily lack a valid window or be on another display. Showing a popover directly may position it incorrectly or not display it at all.

The controller first validates the anchor size and screen intersection. If it is untrusted, it uses a fallback panel on the screen under the pointer. Both containers share the same SwiftUI content, so the business layer does not need to know which one is active.

### Schedule Only the Nearest Real Deadline

Task expiration, completion highlighting, terminal grace, and stalled-task silence are not scanned by a high-frequency UI timer. The monitor gathers all deadlines, creates one `Task` for the nearest, then recalculates and schedules the next deadline when it fires.

This reduces meaningless wakeups while the menu bar app is resident and gives every retention period an explicit source in code.

## How to Review a Design Change

Before adding a feature or changing core semantics, answer these questions in order:

1. Which flow supplies the new data, and what is its authoritative source?
2. Are missing data, old values, explicit zeroes, and failures distinct?
3. Is this repeatable state or a transition that may execute at most once?
4. When an asynchronous result returns, how does it prove that it still belongs to the current generation?
5. Does the change broaden network, persistence, CloudKit, or root-helper boundaries?
6. Does it affect old UserDefaults, local schemas, CloudKit records, or Debug and Release coexistence?
7. How does it recover from crashes, forced exits, system sleep, and file replacement?
8. Which logs distinguish expected degradation from real failure without exposing user data?
9. Which manual scenarios validate design invariants, not only the ideal path?

If any answer remains unclear, the implementation does not yet have a complete lifecycle design.

## Invariants That Should Not Change Lightly

- Hook subprocess failure must not block Codex
- The three data flows remain independent
- `CodexActivityMonitor` is the sole source of live task state
- Bootstrap does not publish historical transitions
- `drainNow()` guarantees a new read barrier after the request
- Missing count fields are not interpreted as `0`
- Raw events are the rebuild source for aggregation caches
- Changes to aggregation semantics increment the schema and trigger a full rebuild
- The root helper gains no network access, arbitrary command execution, or additional file-read capability
- CodexBar may restore only sleep state it acquired itself
- Automatic Reset replaces or cancels only the `wake` event for CodexBar's fixed owner; it does not change other scheduled events
- Notifications that describe a system effect are sent only after the effect is confirmed
- Anonymous tasks do not participate in notifications, sleep prevention, or Stalled Task Protection
- Compatibility changes require a migration and degradation strategy before implementation

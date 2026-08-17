# Development and Validation

[简体中文](../../DeveloperGuide/development.md) | English

## Requirements

- macOS 15 or later
- Xcode and the macOS SDK
- Swift 6 toolchain
- `swiftformat`
- `swiftlint`
- A working local Codex CLI or an app with bundled Codex

The project uses the `CodexBar` scheme. Routine builds do not require a Developer ID or notarization credentials.

## Project Structure

| Directory | Responsibility |
| --- | --- |
| `CodexBar/App` | App startup entry points |
| `CodexBar/Controllers` | AppKit lifecycle, menu bar, and window control |
| `CodexBar/Models` | Business DTOs, snapshots, and presentation models |
| `CodexBar/Services` | app-server, Hook, task, sync, notification, and system services |
| `CodexBar/Views` | SwiftUI interface |
| `CodexBar/Resources` | Plists, entitlements, localization, and resources |
| `CodexBarHelper` | Root LaunchDaemon |
| `Shared` | Shared XPC interface |
| `Config` | Version configuration |
| `Scripts` | Release and maintenance scripts |

## Recommended Order for Reading the Code

Do not infer business state backward from a view. Follow the facts:

1. Start in [`CodexBarApp.swift`](../../../CodexBar/App/CodexBarApp.swift) to see Hook subprocess branching
2. Read [`CodexBarAppDelegate.swift`](../../../CodexBar/Controllers/CodexBarAppDelegate.swift) for the normal-mode composition root
3. Read [`StatusItemController.swift`](../../../CodexBar/Controllers/StatusItemController.swift) for menu bar and window orchestration
4. Choose one flow and follow its source, service, snapshot, and view model
5. Then see how notifications or sleep prevention subscribe to upstream results
6. Finally, inspect how SwiftUI presents state and reports user intent

For live tasks:

```text
WorkflowHookEventRecorder
  -> HookEventTailReader
  -> CodexActivityMonitor
  -> CodexActivitySnapshot / CodexActivityTransition
  -> StatusItemController assembly
      -> UI
      -> CodexNotificationService
      -> KeepAliveController
```

Finding authoritative state first prevents mistaking a UI cache, notification deduplication set, or controller intermediate state for a business fact.

## Define Five Things Before a Change

Before implementing anything beyond a purely visual change, answer at least these questions in design or development notes:

| Question | Example |
| --- | --- |
| Target fact | “The task is waiting for user approval,” not “show an orange dot” |
| Authoritative source | Hook event after reviewer confirmation |
| Derived consumers | Activity card, notifications, sleep prevention |
| Failure semantics | Pause evaluation while the reader is unavailable |
| Acceptance evidence | One transition, no bootstrap replay, reconciliation after recovery |

This step is not process for its own sake. It reveals when three side-effect consumers have assigned different meanings to one field.

## Where Common Changes Belong

| Change | Preferred location | Avoid |
| --- | --- | --- |
| app-server protocol method | `CodexStatus/` service and DTO | SwiftUI view |
| Raw Hook field | Recorder model and aggregation projection | Reading stdin directly into a CloudKit record |
| Live task transition | `CodexActivityMonitor` | Notification service inferring from history |
| Daily metrics presentation | `WorkflowViewModel` projection | View remerging raw events |
| System notification | `CodexNotificationService` | Button action or view lifecycle |
| Sleep-prevention condition | `KeepAliveController.sleepBlockReason` | Several UI computed properties |
| Window behavior | AppKit controller | Service or model |
| User default | Corresponding settings type | Scattered `UserDefaults.standard` calls |

Prefer extending an existing responsibility for a small change. Create a service only when a capability has its own lifecycle, state ownership, or failure boundary.

## Routine Checks

### Build

```bash
xcodebuild \
  -project CodexBar.xcodeproj \
  -scheme CodexBar \
  -destination 'generic/platform=macOS' \
  build
```

### Format

```bash
swiftformat .
```

The project uses Swift 6 and four-space indentation configured in `.swiftformat`.

### Static Analysis

```bash
swiftlint
```

Rules are in `.swiftlint.yml`.

The repository currently has no XCTest target or coverage gate. Build, formatting, and lint do not replace manual validation of affected workflows.

### Recommended Check Order

```text
Inspect worktree scope
  -> Complete the smallest implementation
  -> swiftformat
  -> Review formatting diff
  -> swiftlint
  -> xcodebuild
  -> Targeted manual validation
  -> git diff --check
```

Formatting before build ensures final validation covers the actual code intended for submission. If the repository already contains uncommitted user changes, do not format everything indiscriminately. Check scope first with `git status --short` and `git diff --name-only`, and format only touched Swift files when necessary.

`xcodebuild` checks Swift 6 concurrency, target membership, entitlements, and resource references. `swiftlint` checks style and some static rules. Neither validates AppKit focus, XPC crash recovery, or notification relevance.

Even documentation-only changes follow the repository convention of formatting, linting, and building. Those checks do not validate documentation, so also check Markdown relative links, `git diff --check`, and the repository's Chinese-punctuation rules.

### Reading Build Failures

Find the first real `error:` rather than the final `BUILD FAILED`.

- An actor-isolation error usually indicates unclear state ownership; do not first suppress it with `nonisolated(unsafe)`
- For a missing file or resource, check target membership and Xcode project references
- A helper protocol error requires checking the app target, helper target, and `Shared` interface together
- For entitlement or signing errors, confirm whether the current identity is Debug or Release

Fix the first root cause and rebuild. Many later generic or module errors are cascading failures.

## Logging

View Release system logs with:

```bash
/usr/bin/log stream \
  --predicate 'subsystem == "app.zabrian.codexbar"' \
  --style compact
```

The Debug subsystem has a `.debug` suffix.

The in-app Logs window shows the latest 500 app-server interactions in the current process and helps diagnose CLI discovery, handshake, method unsupported, and retries.

### What a Log Should Answer

A useful state-machine log should identify:

- What triggered the operation
- Which state it intended to reach
- Which stage failed
- Which degradation or retry action followed
- Duration and processing scale

The repository uses `LogTrigger`, `LogDuration`, and `LogFields.joined` for consistent fields. High-frequency polling logs only state transitions or result changes so no-op messages do not obscure real faults.

Prefer stable English keys with controlled values, for example:

```text
trigger=wake want=0 reason=lowBattery elapsed=0.183s
```

Do not log notification bodies, full paths, identities, or tokens. If an error's `localizedDescription` may contain sensitive request data, classify the error before logging it.

### Troubleshooting by Subsystem and Stage

| Symptom | First logs and state to inspect |
| --- | --- |
| Rate limits do not refresh | app-server handshake, method, retry, stale |
| Hook has no metrics | Hook configuration, recorder timeout, maintenance counts |
| Live task is stuck | Tail-reader generation, rollout reconciliation, data-source availability |
| Sync data is missing | Sync stage, local and confirmed counts, replacement dates |
| Notification does not appear | Authorization, kind, duplicate, or obsolete |
| Sleep prevention does not engage | Block reason, helper registration, XPC generation, source |
| Automatic Reset did not run | Target, threshold, retry window, helper registration, wake schedule |

## Debug and Release

The configurations use separate identities:

| Configuration | App bundle ID | CodexBarHelper bundle ID |
| --- | --- | --- |
| Release | `app.zabrian.codexbar` | `app.zabrian.codexbar.helper` |
| Debug | `app.zabrian.codexbar.debug` | `app.zabrian.codexbar.debug.helper` |

Do not mix configurations while diagnosing CodexBarHelper installation, LaunchDaemon state, or system approval.

The Hook handler binds to the current app executable path. When switching between Debug and Release, confirm that the installed handler points to the intended build.

### Why the Builds Still Share Some State

Separating bundle IDs prevents app, helper registration, and system approval from overwriting one another. Raw Hook data and Activity Protection must observe the same Codex work facts, however, and deliberately share files.

Shared state means:

- Writes require `flock`; actors protect only one process
- Schemas must remain interpretable while two versions coexist
- A changed identity-hash algorithm affects both builds
- Diagnosis must record which app writes and which helper controls the system

Do not temporarily isolate Debug by renaming its directory. That changes the product definition of its data source and hides real coexistence problems.

## Architecture Rules

### Startup Entry

`WorkflowHookEventRecorder.handleIfRequested()` must be the first work in app initialization.

`--hook-event` mode reads stdin, writes JSONL under a lock, and exits immediately. It initializes no UI, notifications, CloudKit, or long-lived services.

### MainActor

UI, controllers, view models, and settings use default isolation. Blocking file, subprocess, and network I/O belongs in actors or asynchronous services.

Shared mutable state belongs in an actor. Add concurrency declarations to DTOs and cross-actor value types where needed rather than disabling Swift 6 checks.

#### MainActor Is Not an I/O Queue

Default isolation clarifies UI state mutation; it does not permit synchronous file and subprocess work on the main thread.

Use this pattern:

```text
MainActor captures immutable input
  -> Actor or async API performs I/O
  -> Return a Sendable result
  -> MainActor validates generation
  -> Commit snapshot
```

Do not pass a mutable controller or non-Sendable AppKit object into a background closure. A cross-actor DTO should generally be a small value type. Use `nonisolated` to express that the type itself does not depend on an actor, not to bypass one access error.

#### Actors and `flock` Solve Different Problems

- An actor serializes tasks within one process
- `flock` coordinates the app, Hook subprocesses, Debug, Release, and other processes

An actor-safe read-modify-write can still be interrupted by another process. Conversely, `flock` alone does not protect in-memory state across actor reentrancy before and after `await`.

#### `@Published` Uses `willSet`

When a Combine sink receives a new value, the property on its publisher may still be old. For decisions based on the combined post-change state:

- Use the sink argument for the changing value
- Read other unchanged dependencies from the object
- Or publish one snapshot containing the complete new state

Sync activation and low-rate-limit threshold reevaluation depend on this rule. Replacing callback arguments with immediate property reads creates a one-frame inverted decision.

### Data Flows

Keep these flows independent:

- app-server account, rate limits, and usage
- Historical Hook aggregation
- Live tasks from `CodexActivityMonitor`

New UI may combine snapshots from all three, but one flow must not become an implicit prerequisite of another.

Combination belongs only in presentation or explicit business policy. A menu bar icon may show both a rate-limit bar and activity dot, but app-server failure must not stop activity monitoring, and Hook maintenance must not wait for CloudKit before publishing local metrics.

Write a truth table for any new cross-flow behavior. Sleep prevention is a legitimate example: it explicitly requires an operational Hook and a non-anonymous live task rather than acquiring the dependency simply because both objects happen to share a controller.

### Hook

- Preserve existing user and third-party configuration when changing handlers
- Enabling and validation require actual app-server version `0.145.0` or later
- Hook subprocess failure must not block Codex
- `SessionEnd` times out after 3 seconds; other events after 5 seconds
- `drainNow()` must preserve read-barrier semantics
- An unavailable source must not reuse an old snapshot for evaluation

When adding a Hook event, review:

1. Handler group and timeout in Codex configuration
2. Recorder allowlist fields and fail-open path
3. Forward and backward compatibility of raw JSONL decoding
4. Aggregation counts and missing semantics
5. Whether the live monitor consumes it
6. Whether CloudKit projection needs a field
7. Privacy documentation and logging fields

Not every event belongs in every layer. An explicit “not consumed” is easier to maintain than reliance on default decoder behavior.

### Aggregation

When the raw-event-to-aggregate algorithm, output fields, meanings, or deduplication rules change:

1. Increment `WorkflowMaintenanceState.currentAggregationSchema`
2. Fully rebuild from raw JSONL inside retention
3. Do not add field-level historical migration
4. Preserve the difference between missing and `0`
5. Mark current-device replacement dates in CloudKit

Increment schema when the same raw event produces semantically different output, not only when Codable can no longer decode. Even a deduplication fix requires rebuilding because old daily files already contain the incorrect result.

Full rebuild is preferable because raw JSONL is the fact source. Field-level migration must guess information lost by old algorithms and accumulates historical branches that cannot compose.

### System Power Control

- CodexBarHelper controls only fixed sleep state and Automatic Reset `wake` events
- CodexBarHelper gains no network or arbitrary-command capability
- CodexBar must neither claim nor restore external `SleepDisabled=1`
- Leases, watchdog, and owned persistence must all remain in place
- The Automatic Reset wake interface accepts only bounded timestamps; owner and event type are fixed by the helper
- Before exit, the app confirms sleep restoration and Automatic Reset wake-schedule cancellation

Before changing sleep prevention, write five sequences: acquire, release, timeout, crash, and external owner. Testing only normal toggling does not prove global system state is recoverable.

Before changing Automatic Reset wake scheduling, write six sequences: schedule, replace, cancel, connection loss, helper startup, and unregister. System read-back must prove that the fixed owner has exactly one matching event or none.

Every new helper method requires proof that root execution is necessary. Reads, network operations, and file work possible in the regular app must not enter the helper merely for reuse.

### Compatibility

Compatibility concerns include:

- Renamed or restructured persistence keys
- Local schema changes
- CloudKit record or field changes
- CodexBarHelper ownership format changes
- Automatic Reset wake-event owner or type changes
- Debug/Release shared identity-calculation changes
- Minimum system-version or API-availability changes

These affect old data, old apps, or Debug/Release coexistence and require migration and degradation design.

By repository policy, an implementer must not choose a compatibility outcome silently. Before changing anything, explain to the user:

- Affected versions and data scope
- Options to preserve old format, migrate once, rebuild fully, or discard explicitly
- Failure modes and future maintenance costs of each choice
- Whether old and new apps may run together
- How upgrade and, if necessary, downgrade will be validated

Implement only after the user chooses. Documentation should record the resulting invariant, not merely the migration steps.

## Common Change Recipes

### Adding a Setting

1. Define one key and its missing-value default in the corresponding settings type or controller
2. Define the value for upgrading users instead of relying on a coincidentally matching Swift property default
3. Connect changes to one reconciliation entry point
4. Do not let views write `UserDefaults` directly
5. Test first install, existing install, and immediate effect after toggling

### Adding a State Field

1. Classify it as fact, derived state, or presentation format
2. Put it in the model nearest the authoritative source
3. Define `nil`, empty, zero, and stale
4. Decide whether it changes Equatable snapshots
5. Check whether notifications, sleep prevention, and UI consume it
6. If persistence or sync is required, perform compatibility and privacy review first

### Adding an Asynchronous Refresh

1. Define trigger and freshness rules
2. Coalesce identical requests with single-flight or a coordinator
3. Add a generation for connection or source replacement
4. Revalidate current eligibility after every `await`
5. Define cancellation, timeout, and last-usable-snapshot behavior
6. Log only state change or final result

### Adding a Window or Side Panel

1. Decide whether it belongs to the menu interaction surface or is an independent auxiliary window
2. Reuse `HostingWindowController` or `MenuSideDetailPanel`
3. Add it to mutual-exclusion registration and extra hit regions
4. Handle multi-display visible frames and Spaces
5. Validate key focus, activation, and closing-animation intermediate states

## Validation by Change Type

### Menus and Windows

- Left-click, right-click, and Control-click behavior
- Dismissal after clicking outside the popover
- Side-panel hit regions and mutual exclusion
- Settings and Logs window focus
- Global shortcut and fallback panel
- Multiple displays and menu bar locations

### Hook and Aggregation

- Preserve existing handlers
- Reject enable when the version is insufficient
- Persist every event within its timeout
- File replacement, truncation, and cross-day reads
- Full rebuild after schema upgrade
- Missing fields do not display as `0`

### Live Tasks

- Running, waiting, completion, and termination transitions
- Automatic review does not enter waiting state
- Subagents belong to parent tasks
- Bootstrap sends no notifications
- Wake reconciles only after a new successful read
- Reader replacement discards old results

### Sync

- Initial backfill
- Multi-device merge without duplicating current-device contribution
- Rebuild replaces only dates for the current device
- iCloud offline, account switching, and recovery
- Retention pruning

### Notifications

- System permission allowed and denied
- Threshold crossing and persistent deduplication
- Foreground presentation and click activation
- Missing custom sound fallback
- TUI and app notifications remain independent

### System Power and Helper

- CodexBarHelper and plist locations inside the app bundle
- App and CodexBarHelper signatures
- First-time system approval
- Running and waiting-for-approval transitions
- Low-battery and maximum-duration stops
- Coexistence with external `SleepDisabled`
- Recovery after normal and abnormal exit
- Confirmation every time Automatic Reset or sleep prevention is enabled, and remaining off after cancellation
- Confirmation copy for unregistered, awaiting-approval, and approved Helper states
- Automatic Reset options appear only while enabled and the Helper is approved
- Helper registration and system approval with Automatic Reset enabled
- Automatic Reset threshold and retry retain only the nearest `wake` event for the fixed owner
- Wake-event cleanup after Automatic Reset disable, target change, normal exit, disconnect, and helper restart
- The fixed-owner wake event is confirmed empty before helper unregister
- Debug and Release remain separated

## Recording Reviewable Manual Evidence

For every affected workflow, record at least:

- Whether the build is Debug or Release
- Initial settings and data state
- Action sequence
- Expected and actual UI
- Relevant log fields
- Whether restart, failure, and recovery paths were checked

For example, Hook wake recovery can record:

```text
Precondition: 1 non-anonymous running task, sleep prevention enabled
Action: Put the Mac to sleep and wake it after rollout writes terminal during sleep
Expected: Task ends after a new drainNow cycle succeeds, no bootstrap notification, helper lease released
Logs: trigger=wake, reader generation advanced, rollout reconciliation completed
```

This is easier to reproduce during a future regression than “manual test passed.”

## Definition of Done

A change is complete only when:

- Code lives in the correct state owner without duplicating a second rule
- Normal, missing, stale, failure, and recovery semantics are explicit
- Concurrent requests have cancellation or generation boundaries
- Compatibility and privacy impact are confirmed
- Formatting, lint, and build pass for the change scope
- Affected workflows receive manual validation
- DeveloperGuide matches actual constants, schemas, and behavior
- `git diff` contains no unrelated user changes or accidental formatting

## Release Scripts

These scripts require Developer ID, signing, notarization, or appcast credentials and are not for routine validation:

- `Scripts/build.sh`
- `Scripts/dmg.sh`
- `Scripts/appcast.sh`

The version comes from [`Version.xcconfig`](../../../Config/Version.xcconfig).

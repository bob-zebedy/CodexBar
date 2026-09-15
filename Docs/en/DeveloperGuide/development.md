# Development and Validation

[简体中文](../../DeveloperGuide/development.md) | English

## Environment and Build

Requires macOS 15+, Xcode, Swift 6, `swiftformat`, and `swiftlint`. The only scheme is `CodexBar`, containing the app, `CodexBarHelper`, and `CodexBarTests` targets.

```bash
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'generic/platform=macOS' build
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -destination 'platform=macOS' test
swiftformat .
swiftlint
```

`.swiftformat` configures Swift 6 and 4-space indentation. `swiftlint` checks `CodexBar/` and `CodexBarTests/`, excluding `Shared/`, `CodexBarHelper/`, and `Scripts/`.

Check `git status --short` before editing. With existing uncommitted work, format only Swift files touched by the change, or check with `swiftformat --lint . --cache ignore`. `swiftlint --no-cache` avoids cache writes.

Daily builds do not need Developer ID or notarization credentials. See [AGENTS.md](../../../AGENTS.md) for writing, Git, and compatibility rules.

## Unit Tests

`CodexBarTests` uses Swift Testing and belongs to the shared `CodexBar` scheme. Run it with Xcode’s Test action or the command above.

The test target has no app host. It compiles the production sources in `CodexBar/` and `Shared/` with the same Swift 6, `MainActor`, and concurrency settings. The test-only `CODEXBAR_TESTING` condition removes `@main`; tests do not instantiate the app or start Codex, CloudKit sync, or the helper. This avoids extracting production modules solely for testing, at the cost of compiling the app sources again for tests.

| Test area | Key constraints |
| --- | --- |
| Hook and JSONL | Name normalization, corrupt-line isolation, metadata read budget, partial lines, bootstrap/live separation, file replacement |
| Live tasks | Anonymous identity, duration, out-of-order progress, subagent counts, approvals scoped to each execution |
| Rollout lifecycle | Completion and progress, read coverage, corrupt lines, missing/replaced files, archived sessions |
| Aggregation and sync models | Identifier deduplication, paired events, missing counts, incremental/replay equivalence, same-device generation deduplication |
| Persistence and settings | Protection expiry, merging across store instances, conditional removal, legacy defaults, corrupt configuration and draft restoration |
| Quota, proxy, and presentation | Credit filtering, stable UUIDs, actual running versions, proxy validation and environment, dates and heatmap states |
| Asynchronous refresh | Cancellation and stale generations cannot commit results or finish newer refreshes |

Each file test creates and removes its own temporary directory. Each preferences test uses and cleans up a unique `UserDefaults` suite. Tests use fixed dates, explicit calendars, and controlled asynchronous checkpoints; follow these isolation patterns when adding tests.

Unit tests do not cover live CloudKit, app-server, system notifications, window focus, or helper power behavior. Validate those flows with the manual scenarios below.

## Implementation Entry Points

| Feature | Main location | Implementation guide |
| --- | --- | --- |
| app-server, proxy, Automatic Reset | `Services/CodexStatus` and corresponding Settings | [app-server Data Flow](app-server.md) |
| Hook installation and statistics | `CodexHookSettings`, `WorkflowService`, aggregate models | [Hook Collection and Aggregation](hook-and-aggregation.md) |
| Live tasks and protection | `CodexActivityMonitor` and readers | [Live Task Monitoring](activity-monitor.md) |
| Sleep prevention and system wakes | `KeepAliveController`, `AutoResetWakeScheduler`, helper | [Sleep Prevention](sleep-prevention.md) |
| Notifications and sound | `CodexNotificationService`, notification Settings | [Notifications](notifications.md) |
| Sync | `WorkflowSyncService` and scheduler | [CloudKit Sync](sync.md) |
| Menus, windows, hot keys | `Controllers` and corresponding views | [UI and Lifecycle](ui-and-lifecycle.md) |

`CodexBarAppDelegate` assembles long-lived objects. Add state to its existing owner where possible; views consume snapshots and emit action intents. See [Architecture](architecture.md) for source entry points.

## Change Review

Changes to persisted keys, schemas, identity computation, minimum OS versions, or version coexistence require explaining the impact and compatibility options, then waiting for the user’s choice. Review [Data and Privacy Boundaries](data-and-privacy.md) before adding networking, log fields, or CloudKit fields.

Changes to aggregation algorithms, output semantics, or deduplication increment `WorkflowMaintenanceState.currentAggregationSchema` and rebuild from retained raw JSONL instead of adding field-level historical migrations.

For asynchronous changes, check cancellation, commit eligibility, and generation. Cross-process files still need `flock`; actors protect only one process. `@Published` subscriptions use the closure’s new value rather than rereading old state during `willSet`.

## Validation Workflow

1. Review the change scope and preserve existing work
2. Format and run `swiftlint`
3. Build the app and helper, and run unit tests
4. Manually verify affected normal, failure, and recovery flows
5. Review documentation and run `git diff --check`

For build failures, find the first actual `error:`. Check Debug/Release identity for signing or entitlement errors, and both targets plus `Shared` for helper protocol changes. Compilation and static checks do not cover window focus, system authorization, or hardware power behavior.

Documentation-only changes run format checks, lint, and build, plus relative-link and bilingual-content checks.

### Manual Scenarios

| Change area | Key scenarios |
| --- | --- |
| Menus and windows | Rapid toggles, reopen during fade-out, popover/fallback, displays and Spaces, settings/log focus, notification clicks and hot keys |
| Hook and aggregation | Preserve handlers, minimum version, concurrent append, partial/corrupt lines, replacement/truncation, full rebuild |
| Live tasks | Bootstrap without replayed alerts, approval waits, late terminals, anonymous tasks, wake read-barrier failure and recovery |
| Notifications | Authorization denial/recovery, threshold crossing, cycle deduplication, withdrawal after progress, missing sounds |
| Proxy | First configuration, enable/disable, disable invalid data, delete corrupt records, cancel tests, rapid actions and failure rollback |
| Sync | First upload, multiple devices, offline recovery, partial upload failure, rebuild replacement, iCloud account changes |
| Power and helper | First approval, running/waiting transitions, low battery, duration limit, external sleep sources, abnormal exit and restart |
| Automatic Reset wakes | Replace schedules, disable/exit cleanup, connection loss, helper restart, clear before unregistering, fresh reads when due |

Helper changes also require checking executable and plist placement inside the app, signatures, and registration fingerprints. Each feature guide lists more detailed state-transition scenarios.

Record the build, initial settings, action sequence, actual results, and relevant logs so validation can be reproduced.

### Performance Validation

View CPU, memory, wakeups, disk activity, and the recording environment in the [Performance Report](https://codexbar.zabrian.app/performance). Results apply to the build and workload recorded in the report.

For collection, report generation, and baseline comparisons, see the [performance tool guide (Chinese)](../../../Scripts/performance/README.md).

## Debug and Release

| Configuration | App bundle ID | Helper bundle ID |
| --- | --- | --- |
| Debug | `app.zabrian.codexbar.debug` | `app.zabrian.codexbar.debug.helper` |
| Release | `app.zabrian.codexbar` | `app.zabrian.codexbar.helper` |

Preferences and system approval are isolated by identity; Hook data and Activity Protection files are shared. Identify the running app, helper, and installed Hook executable path when debugging.

## Logs

Release system logs:

```bash
/usr/bin/log stream --predicate 'subsystem == "app.zabrian.codexbar"' --style compact
```

Debug uses `app.zabrian.codexbar.debug`; the helper subsystem uses its corresponding bundle ID.

The app’s Logs window retains the latest 500 app-server interactions. Proxy configuration errors use the system-log `settings` category; temporary proxy tests do not write interaction logs.

| Problem | Inspect |
| --- | --- |
| Quota did not refresh | Handshake, method, retry, stale |
| Hook not working | Configuration, version, trust, completeness |
| Task did not finish | Reader generation, rollout reconciliation, source health |
| Missing sync data | Zone, fetch, upload, replacement, prune stages |
| Missing notification | Authorization, kind, duplicate, obsolete |
| Sleep prevention inactive | Block reason, helper registration, XPC generation, source |
| Automatic Reset did not run | Target, threshold, retry window, wake schedule |

Logs use `LogTrigger`, `LogDuration`, and `LogFields.joined` for stages, classifications, counts, and elapsed time. See [Data and Privacy Boundaries](data-and-privacy.md) for request-content and identity restrictions.

## Release and Cleanup Scripts

| Script | Purpose |
| --- | --- |
| `Scripts/build.sh` | Release archive, Developer ID export, notarization, stapling, and Gatekeeper checks |
| `Scripts/dmg.sh` | Package a DMG |
| `Scripts/appcast.sh` | Sign updates and generate the appcast |
| `Scripts/cleanup.swift` | Unregister helpers after all CodexBar instances exit; `--check` checks only, and `--debug` or `--release` limits scope |

Release scripts require signing and notarization credentials and are not daily validation tools. The version comes from [`Version.xcconfig`](../../../Config/Version.xcconfig).

Helper cleanup cancels and verifies an empty system wake schedule before unregistering; failure stops cleanup. See [Sleep Prevention](sleep-prevention.md).

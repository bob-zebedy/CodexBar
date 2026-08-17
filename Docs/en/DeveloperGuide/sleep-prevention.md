# Sleep Prevention System

[简体中文](../../DeveloperGuide/sleep-prevention.md) | English

## Design Goals

Sleep prevention must satisfy three goals at once:

- Prevent idle sleep while an eligible Codex task exists
- Restore system settings reliably after app exit, crash, or disconnection
- Never overwrite a system sleep setting already owned by the user or another app

The regular app process owns policy and UI. CodexBarHelper executes only constrained system sleep and wake operations:

```text
CodexActivityMonitor
  -> KeepAliveController
      -> App IOKit assertion
      -> XPC lease
          -> CodexBarHelper
              -> /usr/bin/pmset

AutoResetController
  -> AutoResetWakeScheduler
      -> XPC wake date
          -> CodexBarHelper
              -> IOPMSchedulePowerEvent
```

## Why This Is Not an Assertion Switch

Sleep prevention looks like one Boolean setting but spans user intent, live tasks, power state, app lifecycle, and root system state. Any layer can change before another, so `isEnabled` cannot mean that system sleep is already disabled.

State is split into four layers:

| Layer | Representative field | Question answered |
| --- | --- | --- |
| User intent | `isEnabled` | Does the user want the feature? |
| Decision condition | `sleepBlockReason` | Are activation conditions currently met? |
| Request state | `appliedSleepPreventionRequested` and `requestInFlight` | What did the app most recently request from the helper? |
| Confirmed effect | `isPreventingSleep` and `sleepPreventionSource` | Has the app received evidence that system state matches? |

This distinction resolves two issues often hidden by UI:

- Temporary helper unavailability preserves the user's switch, allowing automatic recovery without requiring them to enable it again
- UI does not claim success after an XPC request but before confirmation, avoiding disagreement with actual system state

`sleepBlockReason` is the sole decision output for all conditions. Derived UI state, condition logging, and actual switching read the same result. Every new condition must use a finite `switch` to state whether the settings entry remains available. This intentionally prevents omissions.

## Why App Assertions and System Settings Coexist

The mechanisms have different scopes:

| Mechanism | Lifetime | Effect | How it ends |
| --- | --- | --- | --- |
| IOKit assertion | App process | Prevents idle system sleep and optionally display sleep | Reclaimed automatically after app exit |
| `pmset disablesleep` | System-wide | Covers system-sleep paths not guaranteed by assertions | Requires explicit restoration, ownership, and a watchdog |

Assertions are cheap to recover but incomplete. `pmset` is stronger but can leave global state after a crash. CodexBar uses both and delegates high-risk global state to a least-privileged helper.

The app assertion is established before XPC acquisition begins so there is no idle-sleep gap while the helper switches state. A shared cleanup path releases it after helper failure, preventing a half-success known only to the app.

## Acquisition and Release Are Confirmed Transactions

Acquisition does not optimistically change UI and patch system state later. It is verified:

```text
Conditions allow activation
  -> Establish app idle assertion
  -> Mark that helper may have received a lease
  -> Send generation-tagged XPC request
  -> Helper reads current SleepDisabled
  -> Write and read back when needed
  -> App validates source and measured value
  -> Publish active state and begin duration accumulation
```

Release converges in the opposite direction:

```text
Conditions block activation
  -> Ask helper to revoke lease
  -> Helper restores system value only when owned and no leases remain
  -> App receives measured result
  -> Publish inactive state and release display assertion
  -> Stop duration accumulation
  -> Submit low-battery or duration-limit notification
  -> Release app idle assertion
  -> Compensate for lid-close sleep if needed
```

Notifications come after the helper confirms `SleepDisabled=0`, ensuring that “sleep prevention stopped” describes fact rather than pending intent.

The app idle assertion remains until notification submission ends. A closed-lid Mac may sleep immediately after global restoration; releasing the last assertion first could prevent the request from reaching the notification system. CodexBar then releases it immediately and compensates for the lid edge without reclaiming system ownership.

## Why `mayHaveHelperLease` Survives a Timeout

An XPC timeout proves only that the app received no reply, not that the helper did not execute the request. The helper may hold the lease while its reply was lost during disconnect.

`mayHaveHelperLease` therefore uses conservative semantics:

- Set `true` immediately when requesting acquisition
- Remain `true` after timeout or connection invalidation
- Change to `false` only after an explicitly confirmed release

This may add one idempotent release during exit, but that is far cheaper than leaving global `SleepDisabled=1`.

## The Race Solved by Generation

The user may turn off the switch, a task may finish, and retry may start before an earlier XPC reply returns. Applying replies by arrival order could let old acquisition success overwrite newer release success.

Both app and helper use monotonically increasing generations:

- The app accepts callbacks only for current `requestGeneration`
- The helper ignores requests older than a lease's current generation
- Invalidating a connection advances app generation so in-flight callbacks become stale

Generation is not a logging sequence number. It proves eligibility to commit asynchronous state.

## Activation Conditions

[`KeepAliveController.swift`](../../../CodexBar/Services/KeepAlive/KeepAliveController.swift) establishes sleep prevention only when all conditions hold:

- Prevent System Sleep is enabled
- Hook is enabled and validated
- At least one live task qualifies under settings
- CodexBarHelper is installed and connectable
- The low-battery threshold is not active
- The per-period maximum duration has not been reached
- The app is not terminating

Waiting-for-approval tasks do not count by default but can be enabled separately. Tasks suppressed by Activity Protection no longer maintain sleep prevention.

`KeepAliveController` first removes `isAnonymous` tasks from running and waiting snapshots. Only non-anonymous tasks can enter active sets, begin a new duration period, or keep sleep prevention alive.

The controller publishes an explicit blocking reason:

| Reason | Meaning |
| --- | --- |
| `notStarted` | Service has not started |
| `userOff` | User turned off the master switch |
| `hookDisabled` | Hook is not operational |
| `noTasks` | No task qualifies |
| `helperUnavailable` | CodexBarHelper is not installed or connectable |
| `helperRefreshing` | CodexBarHelper state is recovering or being confirmed |
| `terminating` | App is quitting |
| `lowBattery` | Battery is below the threshold |
| `limitReached` | Per-period duration limit was reached |

## App-Side Assertions

[`SystemSleepService.swift`](../../../CodexBar/Services/KeepAlive/SystemSleepService.swift) creates an IOKit `PreventUserIdleSystemSleep` assertion.

If Keep Display Awake is enabled, it also creates `NoDisplaySleep` and declares user activity every 30 seconds so display idle timing does not activate early.

App assertions cover only the current process. CodexBarHelper manages system-level `SleepDisabled` to cover sleep paths assertions cannot guarantee.

## CodexBarHelper Installation and Communication

CodexBarHelper registers as a LaunchDaemon through `SMAppService`. The app and helper use the XPC interface in [`CodexBarHelperXPC.swift`](../../../Shared/CodexBarHelperXPC.swift).

The interface exposes only four capability classes:

- Set or revoke an app lease
- Query helper runtime and ownership state
- Reset helper state after an app update
- Set or cancel the next Automatic Reset `wake` event for CodexBar's fixed owner

Automatic Reset and sleep prevention share helper registration and macOS approval but use separate XPC connections. Enabling Automatic Reset attempts helper registration even when Prevent System Sleep is off; while approval is pending, its setting row shows the same state and `Open System Settings` entry.

Settings separates user confirmation, helper registration, and navigation to Helper authorization:

- `HelperFeatureConfirmation` presents one shared dialog whenever Automatic Reset or Prevent System Sleep changes from off to on
- `.notRegistered` and `.notFound` explain that background installation and authorization are required; `.requiresApproval` explains that installation succeeded but authorization is pending; `.enabled` shows only the feature description
- Only user confirmation calls `AutoResetSettings.setEnabled(true)` or `KeepAliveController.setEnabled(true)`; cancellation does not write enabled state
- `ensureHelperRegistration()` handles registration, refresh, and coordination only; it does not open authorization settings
- `AppSettingsView` shows `Open System Settings` only for an enabled row in `.requiresApproval`; the button calls `KeepAliveController.openSystemSettings()`
- Automatic Reset options require its switch on and `helperStatus == .enabled`; losing that condition closes an open panel
- Sleep-prevention options read `KeepAliveController.canShowOptions`; settings remain adjustable with no task, low-battery block, limit reached, or helper refresh
- Automatic Reset and sleep-prevention rows show no status explanation while their switches are off

Wake schedules converge from actual system state rather than depending only on normal-exit cleanup:

- Before opening the XPC listener on every startup, the helper removes stale events for its fixed owner; after reconnect, the app reschedules from the latest target
- Set succeeds only after read-back finds exactly one time-matching event; cancel succeeds only after read-back finds none
- A corresponding XPC disconnect abandons the in-memory owner immediately; failed cancellation enters pending cleanup and retries on a short helper cycle
- App exit waits separately for wake-schedule and sleep-lease release; helper update freezes wake synchronization first and explicitly cancels when the current process has a wake connection or applied time
- Before unregistering the helper, `Scripts/cleanup.swift` checks the fixed owner and stops if it cannot cancel and confirm an empty schedule, avoiding removal of the last process able to clean it; after successful unregister it turns off both sleep prevention and Automatic Reset so the next app launch does not reregister

Each app process creates a stable `clientSessionID` that survives XPC reconnection. Every lease change carries a monotonically increasing generation, and CodexBarHelper accepts only newer requests:

- One XPC request times out after 10 seconds
- Lost connections have a 15-second watchdog grace period
- CodexBarHelper checks leases and system state every 5 seconds
- Abnormal state retries recovery every 60 seconds

## CodexBarHelper Privilege Boundary

[`CodexBarHelper/main.swift`](../../../CodexBarHelper/main.swift) runs as root but is intentionally constrained:

- System sleep switching invokes only fixed `/usr/bin/pmset`
- It uses only fixed arguments to read or toggle `disablesleep`
- It sets or cancels one system wake event with a fixed owner and fixed `wake` type
- The wake interface accepts only bounded timestamps, never arbitrary owners, event types, or commands
- It accepts no arbitrary command or arguments
- It does not access Hook, rollout, account, or log data
- It performs no network access
- It does not determine Codex task state

CodexBarHelper derives the client code-signing requirement from its own signature and applies it to the XPC listener. A client that fails the signing requirement cannot establish a control connection.

## System-State Ownership

CodexBarHelper first reads the current value with:

```bash
/usr/bin/pmset -g
```

When system-level prevention is needed, it runs only:

```bash
/usr/bin/pmset -a disablesleep 1
```

On release it runs:

```bash
/usr/bin/pmset -a disablesleep 0
```

Ownership rules prevent damage to external state:

- If the initial observed value is already `1`, the helper marks it external
- CodexBar does not claim external state
- CodexBar records owned only after personally completing `0 -> 1`
- Only owned state may restore to `0` when leases end

Thus, `SleepDisabled=1` set earlier by a user or another tool remains on after CodexBar exits.

### How the Ownership File Forms a Recovery Transaction

Persistence deliberately favors recoverability:

```text
Acquire: persist owned -> pmset 1 -> read back 1
Release: persist restoring -> pmset 0 -> read back 0 -> persist idle
```

Acquisition persists owned first. A crash after file write but before `pmset 1` causes one extra idempotent `pmset 0` at next start rather than leaving global sleep disabled. Writing the system value first could crash before recording restoration responsibility.

Release persists restoring first. A crash before `pmset 0` or final idle commit still leaves a known incomplete restoration. Idle may persist only after read-back confirms system value `0`.

### Taking Over After an External Source Disappears

`external` is not a permanent decision. While eligible tasks remain, CodexBar periodically reads system state cached by the helper:

- Continue borrowing `SleepDisabled=1` without writing while the external source remains
- If it disappears while a task remains, reacquire a lease and let the helper perform a new `0 -> 1`
- If another valid client already made helper state owned, update source presentation without restarting the duration period

This avoids a subtle gap: another tool disables sleep first, so CodexBar reports external; that tool later restores sleep while the task still runs. Without observation, the UI would continue claiming prevention while the system could sleep.

## CodexBarHelper State Persistence

CodexBarHelper stores ownership at:

```text
/Library/Application Support/CodexBar/helper-state.json
```

Security and reliability requirements are:

- Current schema is `1`
- Directory is root-owned with `0755` permissions
- Directory is not group- or world-writable
- File is root-owned with `0600` permissions
- Commits use a temporary file, full sync, and atomic rename
- If a trusted owned record cannot be read at startup, recover to `disablesleep 0`

The file records CodexBar's ownership of system sleep settings.

Automatic Reset wake events are not stored there. macOS power management persists them under an identity formed from the current Debug or Release helper mach service plus `.auto-reset`, with fixed type `wake`.

## Leases and Failure Recovery

While the app has eligible tasks, it holds an identified XPC lease. CodexBarHelper does not interpret one request as permanent authorization detached from its connection:

```text
Lease valid -> Keep owned state
Connection briefly lost -> Wait 15-second watchdog
Reconnect within grace -> Continue with the same clientSessionID
Grace expires -> Revoke lease and restore owned state
```

After abnormal exit, connection invalidation, the watchdog, and persisted ownership together restore system settings.

Normal app exit first cancels the Automatic Reset wake schedule, then revokes the lease and IOKit assertion. If the helper has not confirmed both root-state categories clean, app termination waits instead of leaving under uncertainty.

### Why Normal Exit Can Be Canceled

`applicationShouldTerminate` cannot approve exit before confirmed release. `prepareForTermination()` stops new retries, cancels a possible Automatic Reset wake schedule, requests release of a possible lease, and waits for helper read-back:

- Continue termination after successful release
- Cancel this termination and resume normal condition evaluation and retries after failure

Canceling exit is stricter than simply closing, but it is part of recoverability. Normal exit is the app's only opportunity to confirm root global state actively and should not discard it. Forced exit still falls back to the helper's 15-second watchdog.

### Helper Self-Check Is More Than Process Liveness

The helper checks leases, ownership records, and measured `SleepDisabled` independently:

- While owned with leases, reestablish `1` if another source changes the system value to `0`
- While owned without leases, restore `0`
- While external, observe only and never persist external state as owned
- On an untrusted persistence record, fail safe by restoring rather than treating corruption as permission to remain active
- If Automatic Reset cancellation failed and no connection owner remains, reread and clean the fixed owner every 5 seconds

Periodic checks supplement event-driven XPC by repairing drift after another process changes settings, a callback is lost, or a process restarts.

## Duration and Battery Policy

The per-period duration counts only time when sleep prevention is actually active:

- Pause or reset when no task exists
- A new task period can receive a fresh budget
- Default limit is 12 hours
- Choices are 1, 2, 4, 8, 12, or 24 hours, or unlimited

Low-battery stopping applies only on battery power:

- Threshold options are 5%, 10%, 15%, 20%, and 25%
- Off by default
- Recovery uses 5 percentage points of hysteresis to prevent toggling near the threshold

When low battery or duration limit stops prevention, notification must follow confirmed sleep restoration.

### Defining a Duration Period

“Maximum per-period duration” is accumulated time that CodexBar actually blocks system sleep, not wall time from task appearance to disappearance.

`KeepAliveDurationLimiter` uses `SuspendingClock`:

- The clock pauses in system sleep, so sleeping time does not count as prevention
- Accumulation pauses while helper is unavailable, low battery blocks, or another condition prevents activation
- A new running task begins a new period
- A waiting task resuming running begins a new period
- Refreshing snapshots for the same task set across running and observation does not reset repeatedly

`hasReached` is sticky for the current period. An ordinary snapshot refresh cannot immediately reactivate after the limit; only a clearly new task period or a settings change reevaluates it.

The task set uses stable task IDs to detect “new task” and “resumed from waiting,” not count alone. If one task ends as another starts, count remains one, but the new task deserves a full budget.

### Why Battery Reading Has Three States

Battery reads use `unavailable`, `unreadable`, and `present` rather than one optional value:

| State | Meaning | Policy |
| --- | --- | --- |
| `unavailable` | Confirmed no built-in battery | Hide low-battery settings and clear the block |
| `unreadable` | IOKit read failed this cycle | Preserve the previous decision |
| `present` | Trusted level and power source | Evaluate the threshold normally |

Preserving state through one read failure prevents the row from flickering and avoids transiently disabling active low-battery protection. Once a machine has reported a battery, a later empty list is `unreadable` because hardware cannot disappear at runtime.

Battery use comes from power-source state, not `isCharging`. A connected Mac that has stopped charging also reports `isCharging == false`, but tasks are not draining its battery.

### Low-Battery Latch and Hysteresis

For threshold `T`, protection enters while on battery at or below `T` and exits only at or above `T + 5`.

The five points are state-machine hysteresis, not a display adjustment. Without it, measurement noise near the threshold would repeatedly cause root writes, assertion switches, and notification checks.

Low-battery notification has a per-period latch:

- Queue it only if CodexBar previously prevented sleep
- Record it as notified only after successful restoration
- Connecting power clears the current block, but only crossing the recovery threshold ends the latch period
- Changing the threshold starts a new period so notification state under the old threshold cannot contaminate the new setting

## Display Awake Is a Supplemental Effect

Keeping the display awake depends on confirmed sleep prevention plus the user option; it does not independently maintain system sleep.

`NoDisplaySleep` prevents display sleep but not the screen saver or idle lock, so the app also declares user activity every 30 seconds. It reuses one assertion ID; otherwise `pmset -g assertions` would accumulate same-named entries.

A failed display assertion records its own error without overriding primary sleep-prevention success. This intentionally separates core and supplemental effects so Settings does not report “sleep prevention completely failed” when only the display did not stay awake.

Assertion names use ASCII. On some system versions, Chinese names appear empty in `pmset -g assertions` and lose diagnostic identity.

## Lid-Close Edge Compensation

Lid-close sleep is an edge event. If `SleepDisabled=1` at lid close, later restoring it to `0` does not necessarily make the system reevaluate the missed edge.

After confirming restoration of CodexBar-owned state, CodexBar reads clamshell state. If the lid remains closed and that hardware mode should sleep on close, it explicitly requests system sleep once.

Compensation applies only to `.codexBar` source:

- External state was not changed by CodexBar, so it cannot decide sleep timing for its owner
- It must not request sleep while `SleepDisabled` remains `1`
- It does not guess when clamshell state is unreadable

This repairs an edge event and cannot be replaced by merely reaching the correct final value.

## Failure and Retry

Sleep prevention uses bounded retries because each attempt reconstructs a privileged connection and may launch a root process:

- A 10-second request timeout precedes the 15-second helper watchdog; the app abandons the untrusted connection first, then the helper can clean its lease
- Recompare desired state before each retry so acquisition stops after the user disables the feature
- Preserve an explicit error after exhaustion instead of looping forever and consuming resources
- Release the app assertion immediately on connection invalidation so a degraded UI does not coexist with indefinite process-level idle prevention
- Invalidate old requests by generation rather than relying on every cancellation path to retract the underlying message

Diagnostics distinguish registration from operation errors. Registration means the helper is missing, awaiting approval, or failed to update. Operation error means an installed helper did not produce a trusted result for one transition.

Automatic Reset wake scheduling uses a separate bounded synchronization policy:

- After set or replace failure, retry at `2s, 4s, 8s, 16s, 32s, 64s`; preserve the error on the Automatic Reset row after exhaustion
- Before normal exit or helper update, cancel and read back immediately, then after `250ms`, then after `1s`
- Do not register a system event within 5 seconds of now; the in-app task proceeds directly to deadline execution
- After XPC loss, clear app-side applied state and recoordinate; the helper simultaneously cancels the fixed event owned by that connection

## CodexBarHelper Updates

An app update may change the bundled helper's signature or content. The app records a CodexBarHelper fingerprint and refreshes installation through `SMAppService` and the reset interface after detecting change.

Validation must cover:

- CodexBarHelper is in the correct app-bundle location
- LaunchDaemon plist matches the Debug or Release bundle ID
- App and helper signatures match expectations
- First-time system authorization completes
- Old owned state restores safely after update
- Automatic Reset wake schedules are canceled before update and recreated from the current target after the new helper is ready

## Manual Validation Matrix

- App assertion and CodexBarHelper lease switch together when a running task starts and ends
- Eligible-task decisions are correct with Keep Awake While Waiting off and on
- If an external source sets `disablesleep 1` first, CodexBar neither claims ownership nor restores `0`
- Normal app exit restores owned state
- Forced exit or XPC disconnect lets the watchdog restore owned state
- Automatic Reset and sleep prevention show confirmation every time they are enabled and remain off after cancellation
- Confirmation text and feature descriptions are correct for unregistered, awaiting-approval, and approved helper states
- Enabling only triggers helper registration; authorization settings opens solely from `Open System Settings` on the row
- Automatic Reset options appear only when enabled and approved and close when that condition fails
- Automatic Reset can register and gain approval while sleep prevention remains off
- Future thresholds and retries retain one `wake` event for the fixed owner and do not affect other owners when replaced
- Disabling Automatic Reset, changing its target, and normal exit each confirm the schedule is empty by read-back
- An Automatic Reset XPC disconnect or helper restart cleans stale schedules
- `Scripts/cleanup.swift` unregisters the helper only after the fixed-owner schedule is confirmed empty
- Reaching the duration limit restores sleep before notifying
- Low-battery triggering and 5% hysteresis recovery work correctly
- Hiding a task through Activity Protection releases sleep prevention
- Debug and Release CodexBarHelper instances are never mixed

## Key Source Files

- [`KeepAliveController.swift`](../../../CodexBar/Services/KeepAlive/KeepAliveController.swift)
- [`SystemSleepService.swift`](../../../CodexBar/Services/KeepAlive/SystemSleepService.swift)
- [`HelperRuntimeStatusMonitor.swift`](../../../CodexBar/Services/KeepAlive/HelperRuntimeStatusMonitor.swift)
- [`AutoResetWakeScheduler.swift`](../../../CodexBar/Services/KeepAlive/AutoResetWakeScheduler.swift)
- [`KeepAliveDurationLimiter.swift`](../../../CodexBar/Services/KeepAlive/KeepAliveDurationLimiter.swift)
- [`PowerSourceMonitor.swift`](../../../CodexBar/Services/KeepAlive/PowerSourceMonitor.swift)
- [`CodexBarHelperXPC.swift`](../../../Shared/CodexBarHelperXPC.swift)
- [`CodexBarHelper/main.swift`](../../../CodexBarHelper/main.swift)

# Notification System

[简体中文](../../DeveloperGuide/notifications.md) | English

## Responsibility

[`CodexNotificationService.swift`](../../../CodexBar/Services/Notifications/CodexNotificationService.swift) is the single entry point for notification side effects.

It consumes four kinds of state:

- App-server account and quota snapshots
- `CodexActivityMonitor` task transitions and Activity Protection candidates
- `KeepAliveController` sleep-prevention restoration results
- `AutoResetController` confirmed redemption results or reportable failures

## Settings and System Authorization

`NotificationSettings` stores in-app intent separately from macOS authorization:

| State | Meaning |
| --- | --- |
| `isEnabled` | The user enabled the master switch in CodexBar |
| `authorizationStatus` | Whether macOS permits notifications |
| `canDeliver` | Effective eligibility when both allow delivery |

The main switch defaults to off; system authorization is requested when the user enables it.

The app rereads system state on app activation, when the settings window regains focus, and when settings are explicitly opened. A `denied` result preserves the in-app switch and displays a secondary-color permission message with an Open System Settings button. An actual `notDetermined` result turns the in-app switch off; enabling it again requests authorization. The initial placeholder status does not modify the saved switch.

While an authorization request is pending, duplicate requests are suppressed and focus changes do not cancel the request awaiting the user's response. The permission message remains visible whenever the in-app switch is on and system authorization is missing. If the system still returns `notDetermined` after the request, the switch returns to off so the user can enable it again to retry.

After the authorization request finishes, permission reads use the normal refresh flow. If another focus refresh arrives during a query, the new query replaces the old one so stale results cannot overwrite the latest permission state.

Haptic feedback does not depend on `UNUserNotificationCenter` authorization but still follows the in-app master switch.

## Notification Switches

The master switch is off by default. The eight configurable category switches default to on, and haptic feedback defaults to off.

While the master switch is off, CodexBar neither requests system notification permission nor sends category notifications. Once it is on, category settings select specific types:

| Category | Data source | Control |
| --- | --- | --- |
| Rate-limit reset | app-server rate-limit window | Independent category switch |
| Low rate limit | app-server remaining allowance | Independent category switch and threshold |
| Reset Credits expiration | app-server reset-credit details | Independent category switch |
| Automatic Reset | Confirmed redemption result or user-facing failure | Automatic Reset, category, and master switches |
| Task completion | Live-task terminal transition | Independent category switch and minimum duration |
| Waiting for approval | Live-task waiting transition | Independent category switch |
| Stalled Task Protection | Activity Protection | Prevent System Sleep and notification master switches |
| Low-battery stop | KeepAlive restoration result | Independent category switch, enabled only when protection is available |
| Keep-awake limit | KeepAlive restoration result | Independent category switch, enabled only for a finite duration |

Stalled Task Protection follows Prevent System Sleep. Its notifications require the master switch and system authorization, with no separate category switch. Low-battery and duration-limit notification preferences are retained while their controls appear off and disabled when the corresponding protection is unavailable.

## Rate-Limit Reset

A rate-limit reset notification requires observing a consumed window first and then a new window restored to an unconsumed state.

Observation state is isolated by account and rate-limit window. An account change does not carry the previous account's consumption state into the new account.

Each window also has an in-session lifecycle token. A window that disappears from trusted snapshots and later returns receives a new token. If a failed submission callback for the old window arrives late, it restores `hasObservedConsumption` only if the token still matches.

Reset state is not persisted. After each launch, the app observes consumption and a return to zero again; it does not replay resets that occurred while offline.

## Automatic Reset

An automatic reset operation and a rate-limit-window reset are separate events, so they retain separate notifications:

- “Automatic Reset” means CodexBar's automatic action returned `reset` or `alreadyRedeemed`
- “Rate Limit Reset” means a normal rate-limit snapshot first showed consumption and later returned to zero

One automatic reset can satisfy both conditions, so one device may receive both notifications, each controlled by its own switch.

The success body prefers a fresh post-redemption read of remaining reset credits, including an explicit `0`. If that read fails, the explicit success still stands and CodexBar sends a title-only notification.

`alreadyRedeemed` means the same idempotency key succeeded previously and must not be retried. When several devices call concurrently, every device that explicitly receives `reset` or `alreadyRedeemed` may send its local success notification. A device that only sees the credit disappear during refresh cannot distinguish manual use, use by another device, or expiration, so it stops silently.

Failure notifications use “Automatic Reset Failed” and currently cover:

- Still signed out after one authentication refresh: pause the current credit until a trusted snapshot proves recovery
- Parameter, protocol, or method error: stop retrying the current credit
- This Mac explicitly observes that the target expired: stop retrying the current credit

Transient network and service failures enter backoff without bothering the user on every attempt. The same failure reason notifies at most once per credit. Authentication, permanent error, and locally observed expiration use different deduplication keys, so one credit may produce different failure notifications over time. When the target disappears from server details, its cause is unknown and the state machine stops silently without adding an expiration notification.

Success and failure share the Automatic Reset Notifications switch and sound, enabled by default with the system default sound. When Automatic Reset is off, the setting row is disabled without overwriting saved notification or sound choices; re-enabling restores them.

## Low Rate Limit

Available thresholds are 5%, 10%, and 25%; the default is 10%.

The persisted deduplication key contains the second-level reset time returned by app-server. For the same account and rate-limit window, a reset time within 60 seconds of the recorded value belongs to the same cycle; only a difference greater than 60 seconds creates a new cycle.

Returning above the threshold rearms crossing detection, but one reset cycle still notifies only once. After a new reset cycle begins, the next downward crossing may notify again.

### Threshold Crossing

For each `account + limit + window`, the service stores the previous remaining percentage and applies these notification rules:

- Notify when the previous value was above the threshold and the current value is not
- Notify once when the first in-session value is already at or below the threshold
- Do not notify while remaining continuously in the low region
- When the threshold setting changes, clear the observation and reevaluate immediately against the new threshold

The settings subscription uses the new value passed to its callback. Combine publishes `@Published` during `willSet`, when rereading the settings property would still return the old value. This detail ensures that changing the threshold from 5% to 25% evaluates immediately at 25%.

A stale app-server snapshot neither advances the previous value nor triggers low-rate-limit or reset notifications. Old cache data supports display continuity but cannot prove a new side effect.

### Reset Cycle Matching

After rebuilding an app-server connection, the same window's `resetsAt` may receive a seconds-level correction. Absolute equality would treat it as a new cycle and notify twice.

Within the same account, limit, and window, the service finds sent or in-flight keys within a 60-second tolerance and reuses the original key. This tolerance normalizes identity only; the UI still displays the actual time returned by the service.

## Reset Credits Expiration

When the number of Reset Credits is greater than `0` and an expiration date is available, the notification service sends daily reminders from 7 days to 1 day before expiration.

The deduplication key includes account, expiration date, and days remaining. Multiple refreshes on one day do not repeat the notification.

The service schedules only the nearest future checkpoint, then recalculates from the current snapshot and schedules the next one.

This handles:

- app-server changes to the number or expiration time of Reset Credits
- Notification settings being disabled midway
- A Mac sleeping past the deadline and rechecking through the wake observer
- Combining multiple credits with the same expiration second into one notification

Date classification uses seconds remaining until expiration, with separate deduplication keys for 7 through 1 day. The scheduler only wakes the check; the current snapshot makes the final eligibility decision.

## Task Completion

Task notifications respond only to new terminal transitions published by the monitor and never infer them by scanning historical lists:

- Tasks established during bootstrap do not notify
- The activity monitor retains terminal IDs for 24-hour deduplication
- The notification service also tracks its own sent keys
- `Stop` and rollout terminal data for the same turn reconcile into one notification

Anonymous tasks are not published to task-notification consumers. The notification service filters `isAnonymous` again at the transition boundary, so anonymous tasks cannot send completion or approval notifications or trigger task haptics.

Minimum completion duration is 30, 60, 120, or 300 seconds; the default is 60 seconds. A shorter completed task does not notify but may still appear briefly in the UI.

Haptics start for every task transition. A new transition cancels the previous sequence of 10 pulses and begins again. Settings are rechecked before each pulse, so disabling haptics stops an old sequence immediately.

## Waiting for Approval

A waiting notification is sent only when the `PermissionRequest` reviewer is confirmed to be the user:

- Automatic review does not notify
- One waiting item notifies only once
- Leaving waiting state removes the item from the relevant set
- Waiting state found during bootstrap does not replay historical notifications

Whether waiting maintains sleep prevention is an independent setting and does not affect notification eligibility.

The notification uses stable task ID as its system identifier. The service also observes activity snapshots:

- Skip submission if the task has already left waiting state
- If state changes after `UNUserNotificationCenter.add` succeeds, withdraw immediately
- When a later snapshot no longer contains the task, remove both delivered and pending notifications
- On submission failure, remove it from the in-memory relevance set so a genuinely new wait may try again later

Relevance checks both before and after submission cover the asynchronous window. Checking only before submission could leave a stale reminder in Notification Center after approval.

## Stalled Task Protection

When a non-anonymous running task reaches its silence threshold, Activity Protection updates its in-memory record and schedules an asynchronous save, then starts notification submission and a 3-second grace period together. After notification handling returns or grace expires, the monitor revalidates the candidate before hiding it. Hiding waits for neither disk commit nor notification success.

The notification identifier uses `taskID + attemptID`. Checks before and after submission compare progress generation and silence duration. New progress invalidates the protection attempt and withdraws its notification.

Protection notifications use the system default sound and a `retryCount` of `0` to avoid retrying an obsolete candidate.

## Sleep Prevention Stopped

When low battery or the duration limit stops sleep prevention, `KeepAliveController` first releases its helper lease. It submits the notification only if the reply reports source `.codexBar` and `SleepDisabled=0`; other results clear the pending notice for that cycle.

The app idle assertion remains until notification submission finishes, then is released before any compensating lid-close sleep.

## Sounds

[`NotificationSoundOption.swift`](../../../CodexBar/Services/Notifications/NotificationSoundOption.swift) provides these sound choices:

- System default notification sound
- Silence
- System sounds available on macOS
- Sounds bundled with the app

Bundled sounds are under [`NotificationSounds`](../../../CodexBar/Resources/NotificationSounds).

If a saved sound name does not exist on a new system or app version, CodexBar falls back to the default sound without blocking the notification.

Each notification category stores its own sound setting.

Sound options persist stable IDs rather than absolute file paths:

- Bundled sounds resolve through bundle resources
- On first access, system sounds are scanned from User, Local, and System sound directories
- `/Network/Library/Sounds` is intentionally excluded because probing automounted paths may block the UI
- Duplicate names choose the earlier directory in system search order
- Bundled IDs are reserved in advance so a same-named local file cannot change the meaning of a saved choice after restart
- An unresolvable saved ID falls back to system default

System default and silent choices cannot be previewed. Preview is available for system and built-in sounds with a concrete audio file.

## Haptic Feedback

Haptic feedback is off by default. When enabled, it uses 10 pulses roughly 100 ms apart.

Haptics are a separate local feedback channel from system notifications. They respond to completion or waiting transitions for non-anonymous tasks and follow the notification master switch and haptics switch, but do not depend on system authorization, a category switch, or the completion-duration threshold.

## Submission and Deduplication

Notifications are submitted through `UNUserNotificationCenter`:

- Ordinary failed submissions retry at most once; Activity Protection notifications do not retry
- Sent deduplication keys persist in UserDefaults
- No more than 300 keys are retained
- Keys include enough account or task scope to avoid suppressing different objects
- Expired or irrelevant waiting keys are removed

Persistent deduplication prevents immediate repeats after restart but does not replace upstream terminal deduplication.

### In-Flight and Sent Deduplication

`submittingDedupKeys` and `sentDedupKeys` cannot be merged:

| Set | Lifetime | Prevents |
| --- | --- | --- |
| `submittingDedupKeys` | Current asynchronous submission | Two synchronous calls passing the check before the first `await` |
| `sentDedupKeys` | UserDefaults, up to 300 entries | Repeating the same business cycle after an app restart |

The deduplication check and `submitting` insertion happen synchronously before creating a `Task`, so correctness does not depend on Swift task scheduling order.

A key enters the sent set only after `UNUserNotificationCenter.add` succeeds and the event is still relevant afterward. Recording it earlier would permanently consume an alert after one system submission failure.

### Shared Delivery Semantics

All notification content eventually passes through the same `send` and `deliver` flow:

```text
Synchronously check deduplication
  -> Build an immediate notification request
  -> Check relevance before submission
  -> Call the system notification center
  -> Check relevance again after submission
  -> Persist deduplication after success
  -> Retry failures according to retryCount and perform classified cleanup (default 1, Activity Protection 0)
```

Logs record only `kind` and the failure reason, never title or body. Notification bodies may contain project names or task information and must not be copied into logs even when those logs remain local.

## Foreground Presentation and Clicks

CodexBar is an `LSUIElement`, so its notification-center delegate explicitly allows banners and sounds while the app is in the foreground.

Click handling calls `openMenuSurface` instead of constructing a new window. This reuses the popover when its anchor is valid, uses the fallback panel otherwise, and preserves the same focus and dismissal rules.

## Codex TUI Notifications

Codex TUI notifications are Codex settings, read through app-server `config/read` and written through `config/batchWrite`.

It is completely independent of CodexBar system notifications:

- Turning off CodexBar notifications does not turn off TUI notifications
- A failed TUI setting does not affect app notification state
- The UI must distinguish the scope of both switches clearly

## Manual Validation Matrix

- Enabling the master switch for the first time requests system permission correctly
- Settings presents an understandable state when permission is denied
- Low-quota alerts fire on a first reading at or below the threshold or a downward threshold crossing, with deduplication within each reset cycle
- An initial 100% rate limit does not produce a false reset alert
- Explicit Automatic Reset `reset` sends “Automatic Reset”; a later return to zero can independently send “Rate Limit Reset”
- Explicit `alreadyRedeemed` is treated as success and stops retries
- Merely observing the target credit disappear does not send an Automatic Reset notification
- Network retries do not send failure alerts, and one credit reports the same failure reason at most once
- Turning off Automatic Reset disables its notification option; re-enabling restores the prior switch and sound
- Success and failure notifications use the sound selected for Automatic Reset Notifications; both are silent when no sound is selected
- Behavior is correct for completed tasks below and above the duration threshold
- `Stop` and rollout terminal arriving together produce one notification
- Automatic approval does not send a waiting notification
- Allowed notifications still appear while the app is foregrounded
- Clicking a notification activates the `LSUIElement` app and opens the main panel
- A missing saved sound resource falls back correctly
- Restarting the app does not repeat persisted events

## Key Source Files

- [`CodexNotificationService.swift`](../../../CodexBar/Services/Notifications/CodexNotificationService.swift)
- [`NotificationSettings.swift`](../../../CodexBar/Services/Settings/NotificationSettings.swift)
- [`NotificationSoundOption.swift`](../../../CodexBar/Services/Notifications/NotificationSoundOption.swift)
- [`CodexCLINotificationSettings.swift`](../../../CodexBar/Services/Settings/CodexCLINotificationSettings.swift)
- [`CodexActivityMonitor.swift`](../../../CodexBar/Services/Workflow/CodexActivityMonitor.swift)
- [`KeepAliveController.swift`](../../../CodexBar/Services/KeepAlive/KeepAliveController.swift)

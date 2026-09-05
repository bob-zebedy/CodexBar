# Notification System

[简体中文](../../DeveloperGuide/notifications.md) | English

## Responsibility

[`CodexNotificationService.swift`](../../../CodexBar/Services/Notifications/CodexNotificationService.swift) is the single entry point for notification side effects.

It consumes three kinds of state:

- app-server account, rate-limit, and Reset Credits snapshots
- Task transitions and sleep-restoration events from `CodexActivityMonitor`
- Confirmed redemption results or user-facing failures from `AutoResetController`

Views and other services do not create system notifications directly. They publish state changes; the notification service handles eligibility, deduplication, sound, and click behavior.

## Design Principles

A notification is not state. It is an external side effect triggered by a state change. A reliable notification requires all four conditions:

```text
The event occurred
  + The user allows this category
  + The event is still relevant
  + It has not been sent in this lifecycle or persistence cycle
```

Centralizing these checks serves two purposes:

- Upstream components publish facts and transitions without knowing about system permission, sounds, or deduplication storage
- Every submission follows the same relevance checks, retry rules, and privacy-preserving logging

Direct notification delivery from a view could repeat after SwiftUI reconstruction, repeated panel openings, or snapshot republication. Views may change settings or display state, but cannot own notification side effects.

## Snapshots and Transitions Are Not Interchangeable

Different notifications require different evidence:

| Notification | Input | Reason |
| --- | --- | --- |
| Low rate limit | Consecutive trusted snapshots | Must compare values on both sides of a threshold |
| Rate-limit reset | Consecutive trusted snapshots | Must observe consumption before observing a return to zero |
| Reset Credits expiration | Current snapshot plus time scheduling | A future deadline triggers the reminder |
| Automatic Reset | app-server mutation result | Only an explicit result proves that this Mac performed the automatic action |
| Task completion | Monitor transition | Historical terminal snapshots must not replay |
| Waiting for approval | Monitor transition plus current snapshot | Notify on new waiting state, then withdraw stale notifications |
| Stalled Task Protection | A relevant candidate that has reached the silence threshold | Revalidate before notification submission and before hiding |
| Sleep prevention stopped | Confirmed system-restoration result | Must not announce success before restoration |

Inferring task completion from a current snapshot looks simpler, but every app launch would treat historical completed tasks as new events. Conversely, one transition alone cannot identify a low-rate-limit case when the app starts after the threshold was crossed.

## App Settings and System Authorization Are Separate Gates

`NotificationSettings` stores in-app intent separately from macOS authorization:

| State | Meaning |
| --- | --- |
| `isEnabled` | The user enabled the master switch in CodexBar |
| `authorizationStatus` | Whether macOS permits notifications |
| `canDeliver` | Effective eligibility when both allow delivery |

The master switch is off by default, so first launch does not present an unexplained permission request. CodexBar invokes the authorization API only after the user enables it.

The app rereads system state on activation because permission may have changed in System Settings. If the app switch is on but system state remains `notDetermined`, it requests again, covering a quit before the first dialog finished.

Haptic feedback does not depend on `UNUserNotificationCenter` authorization but still follows the in-app master switch. This is a capability boundary, not a way around user intent.

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

This prevents a notification merely because the first value seen after launch is 100%.

Observation state is isolated by account and rate-limit window. An account change does not carry the previous account's consumption state into the new account.

Each window also has an in-session lifecycle token. A window that disappears from trusted snapshots and later returns receives a new token. If a failed submission callback for the old window arrives late, it restores `hasObservedConsumption` only if the token still matches.

This prevents a race in which app-server switches account or window while an old notification is submitting, then the late failure callback incorrectly marks the new window as previously consumed.

Reset observation is not persisted. After launch, the app must observe consumption again before notifying. It deliberately accepts missing an offline reset in exchange for never misreporting 0% usage as a reset at startup.

## Automatic Reset

An automatic reset operation and a rate-limit-window reset are separate events, so they retain separate notifications:

- “Automatic Reset” means CodexBar's automatic action returned `reset` or `alreadyRedeemed`
- “Rate Limit Reset” means a normal rate-limit snapshot first showed consumption and later returned to zero

One automatic reset may satisfy both, so the same Mac can receive both notifications. Similar wording is not a reason to merge them: one proves an automation action, the other represents the rate-limit lifecycle, and their sources and settings differ.

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

A notification is sent only when remaining allowance moves from above the threshold to the threshold or below. Remaining in the low region does not repeat on each refresh.

The first trusted snapshot being below the threshold also counts as a downward crossing, covering app startup after the actual crossing.

The persisted deduplication key contains the second-level reset time returned by app-server. For the same account and rate-limit window, a reset time within 60 seconds of the recorded value belongs to the same cycle; only a difference greater than 60 seconds creates a new cycle.

Returning above the threshold rearms crossing detection, but one reset cycle still notifies only once. After a new reset cycle begins, the next downward crossing may notify again.

### Why Detection Uses a Downward Crossing

“Currently below 10%” is a persistent state. “Just dropped below 10%” is the notification event. For each `account + limit + window`, the service stores the previous remaining percentage:

- Notify when the previous value was above the threshold and the current value is not
- Notify once when the first in-session value is already at or below the threshold
- Do not notify while remaining continuously in the low region
- When the threshold setting changes, clear the observation and reevaluate immediately against the new threshold

The settings subscription uses the new value passed to its callback. Combine publishes `@Published` during `willSet`, when rereading the settings property would still return the old value. This detail ensures that changing the threshold from 5% to 25% evaluates immediately at 25%.

A stale app-server snapshot neither advances the previous value nor triggers low-rate-limit or reset notifications. Old cache data supports display continuity but cannot prove a new side effect.

### Why Reset Time Allows 60 Seconds of Drift

After rebuilding an app-server connection, the same window's `resetsAt` may receive a seconds-level correction. Absolute equality would treat it as a new cycle and notify twice.

Within the same account, limit, and window, the service finds sent or in-flight keys within a 60-second tolerance and reuses the original key. This tolerance normalizes identity only; the UI still displays the actual time returned by the service.

## Reset Credits Expiration

When the number of Reset Credits is greater than `0` and an expiration date is available, the notification service sends daily reminders from 7 days to 1 day before expiration.

The deduplication key includes account, expiration date, and days remaining. Multiple refreshes on one day do not repeat the notification.

The service does not create seven long-lived system pending requests. It schedules only the nearest future checkpoint, then recalculates from the current snapshot and schedules the next one when that point arrives.

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

Filtering anonymous tasks again is defense in depth at the side-effect boundary, even though the monitor already omits their transitions. If a future upstream refactor or new transition type changes that guarantee, a task without a session ID still cannot produce a system notification or haptic effect accidentally.

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

When a non-anonymous running task reaches its silence threshold, Activity Protection records the candidate and starts notification submission alongside a 3-second grace period. When notification handling returns or the grace period expires, the monitor revalidates the candidate and hides the task if it remains relevant. Protection proceeds even if notification submission fails.

The notification identifier uses `taskID + attemptID`. Checks before and after submission compare progress generation and silence duration. New progress invalidates the protection attempt and withdraws its notification.

Protection notifications use the system default sound and a `retryCount` of `0` to avoid retrying an obsolete candidate.

## Sleep Prevention Stopped

When low battery or the duration limit stops sleep prevention, `KeepAliveController` first revokes the CodexBarHelper lease and waits for a read-back confirmation of `SleepDisabled=0`.

It submits the notification only after confirmation. The app idle assertion remains until notification submission completes, preventing a closed-lid Mac from sleeping before the notification reaches the system. The controller then releases the assertion and, if needed, issues a compensating lid-close sleep.

This ensures the copy describes a completed system-level restoration while giving asynchronous submission time to converge.

## Sounds

[`NotificationSoundOption.swift`](../../../CodexBar/Services/Notifications/NotificationSoundOption.swift) combines three option groups:

- No sound
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

System default and silent choices cannot be previewed. Playing a system alert as a substitute for Notification Center's default sound creates a false expectation, so previews support only system and bundled sounds backed by explicit files.

## Haptic Feedback

Haptic feedback is off by default. When enabled, it uses 10 pulses roughly 100 ms apart.

Haptics are a separate local feedback channel from system notifications. They respond to completion or waiting transitions for non-anonymous tasks and follow the notification master switch and haptics switch, but do not depend on system authorization, a category switch, or the completion-duration threshold.

This separation lets a user disable banners while keeping consistent task haptics. The upstream transition must still be valid; bootstrap history and anonymous tasks never trigger it.

## Submission and Deduplication

Notifications are submitted through `UNUserNotificationCenter`:

- One failed submission retries at most once
- Sent deduplication keys persist in UserDefaults
- No more than 300 keys are retained
- Keys include enough account or task scope to avoid suppressing different objects
- Expired or irrelevant waiting keys are removed

Persistent deduplication prevents immediate repeats after restart but does not replace upstream terminal deduplication.

### Two Deduplication Layers Solve Different Problems

`submittingDedupKeys` and `sentDedupKeys` cannot be merged:

| Set | Lifetime | Prevents |
| --- | --- | --- |
| `submittingDedupKeys` | Current asynchronous submission | Two synchronous calls passing the check before the first `await` |
| `sentDedupKeys` | UserDefaults, up to 300 entries | Repeating the same business cycle after an app restart |

The deduplication check and `submitting` insertion happen synchronously before creating a `Task`, so correctness does not depend on Swift task scheduling order.

A key enters the sent set only after `UNUserNotificationCenter.add` succeeds and the event is still relevant afterward. Recording it earlier would permanently consume an alert after one system submission failure.

The 300-entry cap prevents UserDefaults from becoming an unbounded event log. An old event could theoretically recur after eviction; that is accepted because upstream cycle identity and live-transition deduplication remain the first boundary.

### Shared Delivery Semantics

All notification content eventually passes through the same `send` and `deliver` flow:

```text
Synchronously check deduplication
  -> Build an immediate notification request
  -> Check relevance before submission
  -> Call the system notification center
  -> Check relevance again after submission
  -> Persist deduplication after success
  -> On failure, retry at most once and run category cleanup
```

Logs record only `kind` and the failure reason, never title or body. Notification bodies may contain project names or task information and must not be copied into logs even when those logs remain local.

## Foreground Presentation and Clicks

CodexBar is an `LSUIElement`, so its notification-center delegate explicitly allows banners and sounds while the app is in the foreground.

Clicking a notification opens the main panel. The status-bar controller performs the action and reuses existing popover or fallback-panel logic.

The delegate explicitly returns banner, list, and sound for foreground presentation. An `LSUIElement` app often remains foregrounded or in unusual activation states; relying on default foreground policy would make notifications appear to disappear unpredictably.

Click handling calls `openMenuSurface` instead of constructing a new window. This reuses the popover when its anchor is valid, uses the fallback panel otherwise, and preserves the same focus and dismissal rules.

## Checklist for a New Notification Type

1. Identify whether its input is a snapshot, transition, or confirmed side-effect result
2. Define identity scoped to account, window, task, or attempt
3. Decide whether it needs session deduplication, persistent deduplication, and relevance checks
4. Define whether bootstrap, stale data, and anonymous tasks may trigger it
5. Choose sound and failure-retry semantics
6. Ensure sensitive fields from the body cannot enter logs
7. Define defaults and behavior for missing old UserDefaults values
8. Validate foreground display, click activation, and withdrawal after invalidation

## Codex TUI Notifications

The Codex TUI Notifications setting belongs to Codex itself and is read and written through app-server `config/batchWrite`.

It is completely independent of CodexBar system notifications:

- Turning off CodexBar notifications does not turn off TUI notifications
- A failed TUI setting does not affect app notification state
- The UI must distinguish the scope of both switches clearly

## Manual Validation Matrix

- Enabling the master switch for the first time requests system permission correctly
- Settings presents an understandable state when permission is denied
- Low-rate-limit alerts occur only on downward threshold crossings
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

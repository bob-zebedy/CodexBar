# Notifications and Alerts

[简体中文](../../UserGuide/notifications.md) | English

## Enabling Notifications

1. Open `Settings > Advanced`
2. Enable `System Notifications`
3. Allow notifications in the macOS permission dialog
4. Click the slider button on the right to configure individual notification types

If system permission is denied, Settings shows an `Open System Settings` button.

System Notifications is off by default. Turning it off disables all CodexBar system notifications and task haptic feedback.

## Notification Types

| Notification | Trigger | Default option | Additional requirement |
| --- | --- | --- | --- |
| Task completed | A task finishes after running for at least the selected duration | On, 1 minute | CodexBar Hook |
| Waiting for approval | A task starts waiting for user approval | On | CodexBar Hook |
| Low rate limit | A trusted rate limit reaches or crosses the threshold for the first time | On, 10% | None |
| Rate limit reset | A rate-limit window previously observed as consumed returns to an unconsumed state | On | None |
| Banked resets expiring | Banked resets enter the 7-day expiration window | On | Available banked resets |
| Automatic Reset | An automatic reset explicitly returns success or reports that it already succeeded | On | Automatic Reset, its notification option, and System Notifications |
| Automatic Reset failed | Authentication failure pauses the task, a protocol error stops it, or this Mac explicitly observes expiration | Shares the success-notification setting | Automatic Reset, its notification option, and System Notifications |
| Low Battery Protection | Low Battery Protection successfully restores system sleep | On | Sleep prevention and Low Battery Protection |
| Keep-awake limit | The time limit is reached and system sleep is successfully restored | On | Sleep prevention and a finite time limit |
| Stalled Task Protection | A running task exceeds the silence threshold and the candidate is still valid | Fixed behavior | CodexBar Hook and Prevent System Sleep |

Stalled Task Protection has no separate notification option and uses the default system sound.

Even if its notification cannot be delivered, a confirmed stalled task is still hidden and stops participating in sleep prevention.

Anonymous tasks do not trigger completion, approval, or Stalled Task Protection notifications or task haptic feedback, but remain visible in the activity card and Task Center.

## Thresholds

| Setting | Options |
| --- | --- |
| Minimum duration for completed tasks | 30 seconds, 1 minute, 2 minutes, 5 minutes |
| Low rate-limit threshold | 5%, 10%, 25% |

A low-rate-limit alert fires only when the remaining percentage moves from above the threshold to the threshold or below. It does not repeat on every 60-second refresh.

Restarting CodexBar does not repeat the alert within the same rate-limit reset cycle.

Banked resets are checked for reminders at 7, 6, 5, 4, 3, 2, and 1 day before expiration.

## Automatic Reset Notifications

“Automatic Reset” and “Rate Limit Reset” represent two independent facts:

- “Automatic Reset” means this Mac's automatic call returned `reset` or `alreadyRedeemed`
- “Rate Limit Reset” means a rate-limit window changed from consumed to unconsumed

One automatic reset can therefore produce both notifications. Neither replaces the other, and each follows its own trigger rules.

When several devices try at the same time, each device that receives an explicit success result sends its own success notification. A device that only sees the credit disappear during refresh does not notify because it cannot tell whether the credit was used manually, used by another device, or expired.

Network errors, timeouts, and temporary service errors retry silently in the background. If authentication still fails, the current task pauses and resumes after a later trusted snapshot confirms recovery. A definitive protocol error stops the current task. If this Mac explicitly observes expiration, the task stops and notifies. If the credit simply disappears from server details, the task stops silently because the cause is unknown.

The same failure reason is reported at most once for a given credit; different reasons may be reported separately. Success and failure notifications share the `Automatic Reset Notification` option and sound. When Automatic Reset is off, this option is unavailable. Re-enabling the feature restores the previous notification and sound choices.

## Notification Sounds

Each configurable notification can use:

- Default notification sound
- No sound
- Any system alert sound available on the current Mac
- CodexBar's built-in Modern and Material sounds

You can preview any sound other than the default or silent options in Settings.

If a saved sound is unavailable on the current Mac, CodexBar falls back to the default notification sound.

## Haptic Feedback

When `Task Haptic Feedback` is enabled, the trackpad provides haptic feedback when a task finishes or starts waiting for approval.

Haptic feedback does not require macOS notification permission, but it still follows CodexBar's System Notifications switch and CodexBar Hook status.

## Codex TUI Notifications

`Codex TUI Notifications` changes `tui.notifications` in the Codex user configuration.

It is independent of CodexBar's local notifications. Enabling one does not enable the other.

## Notification Interaction

- Banners, Notification Center entries, and sounds still appear while CodexBar is in the foreground
- Clicking any CodexBar notification opens the main panel
- When a task is no longer waiting for approval, its waiting notification is removed from Notification Center
- When a stalled task resumes progress or its candidate becomes invalid, its protection notification is removed from Notification Center

Back to the [User Guide](README.md)

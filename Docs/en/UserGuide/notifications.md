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
| Low rate limit | Remaining quota reaches the alert threshold | On, 10% | None |
| Rate limit reset | A rate-limit window previously observed as consumed returns to an unconsumed state | On | None |
| Banked resets expiring | Banked resets enter the 7-day expiration window | On | Available banked resets |
| Automatic Reset | An automatic reset explicitly returns success or reports that it already succeeded | On | Automatic Reset, its notification option, and System Notifications |
| Automatic Reset failed | Authentication failure pauses the task, a protocol error stops it, or this Mac explicitly observes expiration | Shares the success-notification setting | Automatic Reset, its notification option, and System Notifications |
| Low Battery Protection | Low Battery Protection successfully restores system sleep | On | Sleep prevention and Low Battery Protection |
| Keep-awake limit | The time limit is reached and system sleep is successfully restored | On | Sleep prevention and a finite time limit |
| Stalled Task Protection | A running task makes no progress for the selected protection interval | Fixed behavior | CodexBar Hook and Prevent System Sleep |

Stalled Task Protection has no separate notification option and uses the default system sound.

Even if its notification cannot be delivered, a confirmed stalled task is still hidden and stops participating in sleep prevention.

Anonymous tasks do not trigger completion, approval, or Stalled Task Protection notifications or task haptic feedback, but remain visible in the activity card and Task Center.

## Thresholds

| Setting | Options |
| --- | --- |
| Minimum duration for completed tasks | 30 seconds, 1 minute, 2 minutes, 5 minutes |
| Low rate-limit threshold | 5%, 10%, 25% |

A low-quota alert fires when remaining quota drops to or below the threshold, including when the first reading after startup is already low. A known reset time is required, and each reset cycle is notified only once.

Banked resets are checked for reminders at 7, 6, 5, 4, 3, 2, and 1 day before expiration.

## Automatic Reset Notifications

Automatic Reset sends alerts, subject to notification settings, when it succeeds or stops because of sign-in, configuration, or expiration issues. Temporary network failures retry in the background.

One reset may produce both “Automatic Reset” and “Quota Reset” notifications: one reports the operation result, the other the quota change. Success and failure share the Automatic Reset Notifications switch and sound.

When multiple Macs try a reset, each device receiving success confirmation may notify. Devices that only discover the reset has disappeared do not notify. Each failure reason is reported at most once per banked reset.

## Notification Sounds

Each configurable notification can use:

- Default notification sound
- No sound
- Any system alert sound available on the current Mac
- CodexBar's built-in Modern and Material sounds

You can preview any sound other than the default or silent options in Settings.

If a saved sound is unavailable on the current Mac, CodexBar falls back to the default notification sound.

## Haptic Feedback

`Task Haptic Feedback` is off by default. When enabled, the trackpad vibrates when a task finishes or starts waiting for approval.

Haptic feedback does not require macOS notification permission, but it still follows CodexBar's System Notifications switch and CodexBar Hook status.

## Codex TUI Notifications

This option controls Codex’s own notifications independently of CodexBar notifications.

## Notification Interaction

- Banners, Notification Center entries, and sounds still appear while CodexBar is in the foreground
- Clicking any CodexBar notification opens the main panel
- When a task is no longer waiting for approval, its waiting notification is removed from Notification Center
- When a task resumes progress or no longer meets the Stalled Task Protection conditions, its notification is removed from Notification Center

Back to the [User Guide](README.md)

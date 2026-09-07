# Prevent System Sleep

[简体中文](../../UserGuide/sleep-prevention.md) | English

CodexBar can keep your Mac awake while tasks run and restore sleep when tasks finish or a protection condition takes effect.

## Enable and Activate

1. Enable CodexBar Hook in `Settings > Advanced`
2. Enable `Prevent System Sleep` and confirm
3. If background approval is required, click `Open System Settings` and allow CodexBar to run in the background

Sleep prevention requires CodexBar to be running, Hook and its background service to be available, and an eligible task to exist. Low battery or the duration limit stops it; when conditions recover, task state determines whether it resumes. The coffee cup in the main panel indicates that sleep prevention is active.

Anonymous tasks and tasks hidden by Stalled Task Protection do not prevent sleep.

## Options

Click the options button beside the sleep-prevention setting:

| Option | Purpose | Default | Choices |
| --- | --- | --- | --- |
| Keep Awake While Waiting | Remain awake while waiting for your approval | Off | On or off |
| Keep Display Awake | Prevent display sleep, screen saver, and idle locking | Off | On or off |
| Keep-Awake Limit | Limit cumulative sleep prevention in one cycle | 12 hours | 1, 2, 4, 8, 12, or 24 hours; unlimited |
| Stalled Task Protection | Hide running tasks that stop making progress | 1 hour | 30 minutes; 1, 2, or 4 hours |
| Low Battery Protection | Restore sleep at low charge while on battery | Off | Off; 5%, 10%, 15%, 20%, or 25% |

Low Battery Protection is hidden on Macs without a built-in battery.

## Waiting and Display Wake

By default, only running tasks prevent sleep. Enabling the waiting option keeps the Mac awake while approval requests are unattended, until the duration limit is reached or task state changes.

Keep Display Awake works only while sleep prevention is active and may leave the screen unlocked after you step away.

## Keep-Awake Limit

Only time actually preventing sleep is counted; pauses and system sleep are excluded. A new running task or a waiting task returning to running starts a new cycle. No active tasks resets the timer. Reaching the limit restores sleep until the next task cycle.

## Stalled Task Protection

A running task with no progress for the selected duration is hidden from the activity card and Task Center and stops preventing sleep. New progress restores it. Increasing the threshold also restores tasks that no longer exceed it.

Protection follows the main sleep-prevention switch and evaluates only non-anonymous running tasks, not tasks waiting for approval. Evaluation pauses during startup recovery, system sleep, and temporary task-data unavailability.

If notifications are enabled and authorized, CodexBar attempts an alert. Notification failure does not block protection.

## Low Battery Protection

On battery power, sleep prevention stops when charge reaches the threshold or lower. It resumes with eligible tasks after charge rises 5 percentage points above the threshold or power is connected.

For example, a 10% threshold stops sleep prevention at 10% and resumes it at 15%.

## Background Service and Other Apps

CodexBarHelper is the background service included with the app that controls system sleep. Settings provides guidance when approval is missing or the service fails; see [Troubleshooting](troubleshooting.md#codexbarhelper-cannot-be-registered).

If another app has already disabled system sleep, Settings identifies an external source. CodexBar preserves that setting when its tasks finish. If the external source stops while tasks remain, CodexBar takes over as needed.

Before a normal exit, CodexBar restores sleep state it manages and cancels Automatic Reset wake schedules. If exit does not complete, check Settings for background-service errors.

Back to the [User Guide](README.md).

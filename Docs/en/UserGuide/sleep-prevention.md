# Preventing System Sleep

[简体中文](../../UserGuide/sleep-prevention.md) | English

## Purpose

When macOS enters system sleep, Codex tasks running on that Mac may be suspended.

CodexBar manages system sleep automatically based on live task state, allowing long tasks to continue unattended and restoring normal system behavior when tasks finish or a protection rule is triggered.

This feature is not a general-purpose switch that keeps your Mac awake indefinitely.

Enabling it only allows CodexBar to manage sleep automatically. CodexBar does not change system sleep when no eligible task exists.

## Activation Conditions

CodexBar prevents system sleep only when all of the following are true:

1. CodexBar is running and is not quitting
2. `Prevent System Sleep` is enabled
3. CodexBar Hook is installed and passed the latest explicit validation
4. At least one non-anonymous task is running, or `Keep Awake While Waiting` is enabled and a non-anonymous task is waiting
5. CodexBarHelper is registered and approved by macOS
6. CodexBarHelper is not being updated
7. Low Battery Protection is not active
8. The current keep-awake period has not reached its limit

If any condition becomes false, CodexBar stops its own sleep prevention.

If the conditions recover while an eligible task still exists, sleep prevention resumes automatically.

Anonymous tasks do not count as eligible, even when shown as running or waiting for approval.

## Options

| Option | Effect | Default | Choices |
| --- | --- | --- | --- |
| Keep Awake While Waiting | Tasks waiting for your approval continue to prevent sleep | Off | On or off |
| Keep Display Awake | Also prevents display sleep, the screen saver, and idle screen locking | Off | On or off |
| Keep-Awake Limit | Limits accumulated time that sleep is actively prevented in one period | 12 hours | 1, 2, 4, 8, 12, or 24 hours; unlimited |
| Stalled Task Protection | Hides tasks with no progress for an extended period and removes their contribution to sleep prevention | 1 hour | 30 minutes; 1, 2, or 4 hours |
| Low Battery Protection | Restores system sleep when running on low battery | Off | Off; 5%, 10%, 15%, 20%, or 25% |

Low Battery Protection does not appear on Macs without a built-in battery.

## Keep Awake While Waiting

When this option is off, a task stops supporting sleep prevention after it moves from Running to Waiting for Approval.

When it is on, sleep prevention continues while the task waits for approval.

Approval requests have no natural timeout, so an unattended Mac may stay awake for a long time. The Keep-Awake Limit still applies.

Stalled Task Protection evaluates only running tasks, not tasks waiting for approval.

## Keep Display Awake

This option takes effect only while CodexBar is already preventing system sleep.

CodexBar also prevents display sleep and periodically declares user activity to suppress the screen saver and idle screen locking.

It releases these effects when tasks finish, Low Battery Protection activates, the time limit is reached, or sleep prevention fails.

Because this may leave the screen unlocked while you are away, the option is off by default.

## Keep-Awake Limit

- Counts only time during which system sleep is actively prevented
- Excludes time paused because of low battery, unavailable CodexBarHelper, or another condition
- Does not count time spent in system sleep or changes to the system clock
- Resets when there are no active tasks
- Starts a new period when a new running task appears or a waiting task resumes running
- Restores system sleep when the limit is reached, until the next task period begins

## Stalled Task Protection

Stalled Task Protection handles tasks that have stopped making real progress but still appear as running because no reliable terminal state is available:

- Follows the Prevent System Sleep switch and has no separate on/off switch
- Evaluates only non-anonymous running tasks
- Uses Hook events, subagent events, and local session lifecycle as progress signals
- Saves a protection record, attempts a notification, and hides the task when the threshold is reached
- Removes hidden tasks from the activity card and Task Center and excludes them from sleep prevention
- Restores a task automatically and withdraws any active notification when new progress appears
- Restores hidden tasks that no longer exceed the threshold after you select a longer threshold
- Pauses evaluation during Hook history replay, system sleep, wake reconciliation, or Hook data-source outages
- Keeps protection records for no more than 24 hours after the last progress

Protection records contain only hashed task identifiers and timestamps. They do not contain raw `session` or `turn` IDs, project names, or task content.

## Low Battery Protection

- Applies only while the Mac is running on battery power
- Restores system sleep when the battery first reaches or falls below the selected threshold
- Remains active until the battery rises 5 percentage points above the threshold
- Clears immediately when the Mac is connected to power
- Resumes sleep prevention automatically if an eligible task remains
- Sends a low-battery notification only after CodexBar successfully stops its own sleep prevention

The 5-point recovery margin prevents repeated toggling near the selected threshold.

## Authorizing CodexBarHelper

Sleep prevention requires the bundled CodexBarHelper to change system-level sleep settings. Automatic Reset shares the same background-service registration and approval state to install a fixed system wake schedule:

- Every transition from off to on shows an `Enable System Sleep Prevention?` confirmation dialog
- If CodexBarHelper is unregistered or missing, the dialog says `CodexBar Helper must be installed and authorized to run in the background`
- If CodexBarHelper is installed but awaiting approval, the dialog says `CodexBar Helper is installed but still needs authorization to run in the background`
- If CodexBarHelper is approved, the dialog shows only `When enabled, CodexBar prevents system sleep while Codex tasks are running and restores normal sleep afterward.`
- Selecting `Enable` saves the switch state and attempts to register the background service; selecting `Cancel` leaves it off
- When macOS requires approval for the background item, the enabled settings row shows `Open System Settings`; use it to open Login Items & Extensions
- No status explanation appears while the main switch is off; when the switch and Hook are available, the current blocking reason determines whether the sleep-prevention options are shown
- Sleep prevention does not run if CodexBarHelper is missing or registration fails
- If an app update changes CodexBarHelper, CodexBar refreshes its registration and validates the sleep state
- Before a normal app exit, CodexBar cancels the Automatic Reset wake schedule, releases the CodexBarHelper lease, and restores any state it changed
- If a CodexBarHelper connection ends unexpectedly, the helper releases that client's lease after a grace period
- Automatic Reset uses a separate connection; if it disconnects, the helper immediately cancels the wake schedule owned by that connection

## Coexisting with Other Sleep-Prevention Sources

If system sleep was already disabled by another app or by the user before a task started, CodexBar marks the source as external:

- CodexBar does not claim ownership of the external setting
- It does not restore or overwrite that setting when the task finishes
- If the external setting is restored while the task is still running, CodexBar checks again and takes over when needed
- The main panel still shows the coffee cup, while Settings explains that system sleep is disabled by another source

Back to the [User Guide](README.md)

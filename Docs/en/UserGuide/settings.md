# Settings Reference

[简体中文](../../UserGuide/settings.md) | English

Right-click or Control-click the menu bar icon and select `Settings`, or press `⌘,` to open the Settings window.

Settings contains three pages: `General`, `Advanced`, and `About`.

## General Settings

| Setting | Effect | Default or initial state |
| --- | --- | --- |
| Main Panel Layout | Reorders and shows or hides the five main-panel sections | Account, Tasks, Quota, Usage, and Status; the Tasks section is off while Hook is disabled |
| Animation Effects | Animates the rate-limit bars and usage heatmap whenever the main panel opens | On |
| Launch at Login | Starts CodexBar automatically through macOS Login Items | Follows the current system Login Item state |
| Automatically Check for Updates | Lets Sparkle check periodically for updates | Follows the current Sparkle setting |
| Menu Bar Quota Indicator | Shows the remaining percentage for a selected rate-limit window beside the menu bar icon | Primary rate limit |
| Global Shortcut | Opens or closes the CodexBar main panel from any app | `⌘⇧W` |

### Menu Bar Quota Indicator

- Choose from the rate-limit windows returned by the current Codex installation
- CodexBar remembers the last selected window when you turn the indicator off
- Turning it on again restores the previous selection
- Cached rate-limit data is shown with reduced opacity

### Main Panel Layout

Click the options button on the settings row to configure the `Account`, `Tasks`, `Quota`, `Usage`, and `Status` sections:

- Drag sections to change their display order
- Use each switch to show or hide a section
- Keep at least one section visible
- Press `Command-Z` to undo section reordering or visibility changes in order, and `Command-Shift-Z` to redo them

The `Tasks` section follows CodexBar Hook. When Hook is disabled, this section turns off automatically and its switch is disabled, but the row remains draggable. After Hook is enabled again, the section remains off until you turn it on manually.

Hiding a section affects only the main-panel presentation. It does not stop rate-limit refreshes, Hook metrics, notifications, sleep prevention, or sync.

### Global Shortcut

- A recorded shortcut must contain at least two modifier keys
- System-reserved combinations such as `Command-Space` and `Command-Tab` cannot be used
- CodexBar reports combinations already used by another app as conflicts
- You can clear the shortcut
- You can restore the default `⌘⇧W`

## Advanced Settings

| Setting | Effect | Default |
| --- | --- | --- |
| CodexBar Hook | Installs and validates the Codex event handler | Off when not installed |
| System Notifications | Controls CodexBar local notifications and task haptic feedback | Off |
| Automatic Reset | Uses unredeemed reset credits at the selected lead time before expiration | Off; 30 minutes early |
| Prevent System Sleep | Manages system sleep automatically based on live Codex tasks | Off |
| Sync Across Devices | Syncs daily Hook aggregations through iCloud | Off |
| Rebuild Data | Regenerates aggregations from local raw events for selected dates | Manual action |

### CodexBar Hook

Enabling the Hook unlocks live tasks, task notifications, Hook metrics, sleep prevention, and cross-device sync.

Enabling and validating it requires the current app-server to be `0.145.0` or later.

See [Live Tasks and CodexBar Hook](activity-and-hook.md) for details.

### System Notification Options

| Option | Default | Other choices or notes |
| --- | --- | --- |
| Task Completion | On, 1 minute | Minimum duration: 30 seconds or 1, 2, or 5 minutes |
| Approval Requests | On | Requires CodexBar Hook |
| Low Quota | On, 10% | Threshold: 5%, 10%, or 25% |
| Quota Reset | On | Recognized only after consumption has been observed |
| Reset Expiration | On | Alerts for reset credits expiring within 7 days |
| Automatic Reset Notifications | On | Available only while Automatic Reset is enabled; success and failure share one sound |
| Low Battery Alert | On | Applies only when Low Battery Protection is available |
| Keep-Awake Limit | On | Applies only when the maximum duration is not unlimited |
| Task Haptics | Off | Provides trackpad feedback when a task finishes or waits for approval |
| Codex TUI Notifications | Follows the Codex configuration | Independent of CodexBar notifications |

Each system notification can use the default sound, no sound, a system sound, or a built-in app sound.

See [Notifications and Alerts](notifications.md) for details.

### Confirmation for Automatic Reset and Sleep Prevention

Every transition of `Automatic Reset` or `Prevent System Sleep` from off to on shows a confirmation dialog. The dialog first shows guidance based on the current CodexBarHelper state, then explains the selected feature:

| CodexBarHelper state | Confirmation message |
| --- | --- |
| Not registered or file missing | `CodexBar Helper must be installed and authorized to run in the background` |
| Installed but awaiting macOS approval | `CodexBar Helper is installed but still needs authorization to run in the background` |
| Installed and approved | Shows only the feature description |

Feature descriptions are:

| Feature | Confirmation title | Description |
| --- | --- | --- |
| Automatic Reset | `Enable Automatic Reset?` | `When enabled, CodexBar automatically uses a manual reset credit at the configured time before it expires and may briefly wake your Mac.` |
| Prevent System Sleep | `Enable System Sleep Prevention?` | `When enabled, CodexBar prevents system sleep while Codex tasks are running and restores normal sleep afterward.` |

Selecting `Enable` saves your intent and attempts to register CodexBarHelper. Selecting `Cancel` leaves the switch off. System Settings for Helper approval opens only through the `Open System Settings` button below an enabled settings row; the button appears while CodexBarHelper is awaiting approval. No status explanation appears below either row while its switch is off.

### Automatic Reset

When Automatic Reset is enabled and CodexBarHelper is installed and approved, an options button appears on the right side of the main row. Open it to choose a `Time Before Expiration` of `15 Minutes`, `30 Minutes`, `1 Hour`, `2 Hours`, `4 Hours`, or `6 Hours`; the default is `30 Minutes`. The entry is hidden if the Helper state no longer qualifies, and any open Automatic Reset side panel closes.

- Processes only available reset credits explicitly listed in the latest app-server response
- Revalidates the account, credit state, and expiration time before every use
- Processes only the earliest-expiring credit at a time
- Attempts to register CodexBarHelper after confirmation; even if Prevent System Sleep is off, CodexBar may need approval to run in the background under Login Items & Extensions
- Shows CodexBarHelper approval, registration, registration-failure, or wake-schedule synchronization status on the Automatic Reset row
- If a future task exists, CodexBarHelper registers one system wake event for the nearest threshold or retry; the schedule is canceled when the task changes, the feature is disabled, or the app exits, and a schedule left by an abnormal exit is removed the next time the helper starts
- At the scheduled time, prevents idle system sleep only while it rereads and uses the credit; it does not wake the display or enable Prevent System Sleep
- Rechecks immediately after a natural system wake or the next app launch; it retries if the credit is still inside its lead-time window and has not expired, otherwise it reschedules for that window
- Schedules a retry wake only after reading a specific credit and expiration time; continuous retries last no more than 5 minutes per round, while later normal rate-limit refreshes can try again
- Does not consume anything when no reset is currently available, and reuses the same idempotency key throughout that 5-minute round
- Preserves the credit's idempotent identity and reschedules when the server changes its expiration time
- Pauses or stops the current task on authentication failure or a definitive protocol error, with a system notification when notification settings permit

When several Macs enable Automatic Reset, each schedules independently but derives the same idempotency key for the same `creditId`. The first device to succeed consumes the credit. Other devices stop after receiving an already-successful result, or stop silently after a refresh shows that the credit disappeared.

After success, CodexBar sends an “Automatic Reset” notification. A regular “Quota Reset” notification comes from a change in the rate-limit window, so both may appear. Automatic Reset itself does not depend on System Notifications; it still runs when notifications are off but does not show a result notification.

The `Automatic Reset Notifications` side-panel option controls both success and failure notifications and configures one sound for both. When Automatic Reset is off, the option appears off and disabled without overwriting your saved notification and sound choices.

This setting is stored only on the current Mac and is not synced through CloudKit.

### Prevent System Sleep Options

When Prevent System Sleep is enabled and CodexBar Hook is available, an options button can appear on the right side of the main row. The entry remains visible when there is no eligible task, CodexBarHelper is refreshing, Low Battery Protection is active, or the maximum duration has been reached. It is hidden when an eligible task exists but CodexBarHelper is unavailable.

| Option | Default | Choices |
| --- | --- | --- |
| Keep Awake While Waiting | Off | On or off |
| Keep Display Awake | Off | On or off |
| Keep-Awake Limit | 12 hours | 1, 2, 4, 8, 12, or 24 hours; unlimited |
| Stalled Task Protection | 1 hour | 30 minutes; 1, 2, or 4 hours |
| Low Battery Protection | Off | Off; 5%, 10%, 15%, 20%, or 25% |

Low Battery Protection does not appear on Macs without a built-in battery.

See [Preventing System Sleep](sleep-prevention.md) for details.

### Sync Across Devices

- Can be enabled only when CodexBar Hook is on and iCloud is available
- On first enable, uploads daily local Hook aggregations within the retention period
- Settings shows sync status and the most recent successful upload time
- Turning it off stops network sync but keeps local Hook data

See [Data, Sync, and Privacy](sync-data-privacy.md) for details.

### Rebuild Data

- The date picker allows only dates within the raw Hook-data retention period
- Dates with raw events are marked
- Rebuild becomes available only after a complete range is selected
- A confirmation appears before rebuilding
- The result shows the number of rebuilt days, parsed events, and skipped invalid lines
- Incomplete dates retry automatically when the Hook is available

## About

| Item | Purpose |
| --- | --- |
| Codex CLI | Shows the on-disk version and path of the global Codex CLI |
| Codex APP | Shows the on-disk version and path of the CLI bundled with ChatGPT App or Codex App |
| In Use | Identifies the Codex source and running app-server version currently in use |
| CodexBar Version | Shows the current version, update status, and any available update |
| GitHub Project | Opens the CodexBar project page |
| Check for Updates | Runs a manual Sparkle update check |
| Quit CodexBar | Completes required cleanup before quitting the app |

If Codex has been updated on disk but the current app-server has not reconnected, About shows the newly installed version as well.

Click an executable path to copy the full path.

Back to the [User Guide](README.md)

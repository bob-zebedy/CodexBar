# Settings Reference

[简体中文](../../UserGuide/settings.md) | English

Right-click or Control-click the menu bar icon and choose `Settings`, or press `⌘,`.

## General Settings

| Setting | Purpose | Default or initial state |
| --- | --- | --- |
| Main Panel Layout | Reorder and show or hide Account, Tasks, Quota, Usage, and Status | All visible; Tasks is off when Hook is disabled |
| Animation Effects | Animate quota bars and the heatmap when opening the panel | On |
| Launch at Login | Start CodexBar when you sign in to your Mac | Follows the system login-item state |
| Automatically Check for Updates | Periodically check for CodexBar updates | Follows the current update setting |
| Menu Bar Quota Indicator | Show the remaining allowance in a selected window | Primary quota |
| Global Shortcut | Toggle the main panel from any app | `⌘⇧W` |

### Main Panel Layout

Click the options button to drag sections into order or toggle visibility, keeping at least one section visible. Use `⌘Z` to undo and `⌘⇧Z` to redo. Hiding a section does not stop its features.

Disabling Hook turns off Tasks; enable it manually after re-enabling Hook. If Tasks was the only visible section, Account is enabled automatically.

### Menu Bar Quota Indicator

Choose the quota window to display. Turning the indicator off and back on restores the last choice. Faded data indicates cached quota.

### Global Shortcut

A shortcut needs at least two modifier keys and cannot use `Command-Space` or `Command-Tab`. Conflicting combinations produce a warning. You can clear the shortcut or restore the default.

## Advanced Settings

| Setting | Purpose | Default |
| --- | --- | --- |
| Proxy | Configure the proxy for CodexBar’s Codex service connection | Off |
| [CodexBar Hook](activity-and-hook.md) | Enable live tasks and daily activity statistics | Off if not installed |
| [System Notifications](notifications.md) | Configure notification types, thresholds, sounds, and haptics | Main switch off |
| Automatic Reset | Use banked resets shortly before expiration | Off, 30-minute lead time |
| [Prevent System Sleep](sleep-prevention.md) | Keep your Mac awake while eligible tasks run | Off |
| [Cross-Device Sync](sync-data-privacy.md) | Combine daily Hook statistics through iCloud | Off |
| [Rebuild Data](sync-data-privacy.md#rebuild-data) | Recalculate Hook statistics for selected dates | Manual |

### Proxy

Click the setting row and enter a server address and port. HTTP, HTTPS, hostnames, IPv4, and IPv6 are supported; ports must be within `1–65535`. Authentication requires a username; the password may be empty.

An HTTP proxy can forward HTTPS requests. Select HTTPS only if the proxy port itself supports TLS with a valid certificate.

- `Test Connection` checks unsaved settings and can be canceled; it does not save or enable the proxy
- `Save` applies the configuration; after the first save, enable the switch on the setting row
- `Cancel` discards this edit
- `⋯ > Delete Configuration` removes the configuration and password and disables the proxy, even if the saved configuration is damaged
- Turning off the row’s switch retains the configuration for later use

Passwords are hidden until you hover over the field. The proxy affects only CodexBar’s Codex service connection, and its password is stored locally in plain text. See [Data, Sync, and Privacy](sync-data-privacy.md).

### Automatic Reset

Automatic Reset uses banked resets shortly before expiration. Every enable action requires confirmation. If the background service needs approval, click `Open System Settings` below the row and allow CodexBar to run in the background.

Once enabled and CodexBarHelper is approved, use the options button to choose a lead time of `15 Minutes`, `30 Minutes`, `1 Hour`, `2 Hours`, `4 Hours`, or `6 Hours`. The default is `30 Minutes`.

- Processes the earliest-expiring available reset first, rechecking sign-in and availability before use
- May briefly wake your Mac without lighting the display or enabling Prevent System Sleep
- Retries temporary failures for up to 5 minutes per round; later refreshes may try again
- Rechecks unexpired resets when the Mac wakes or the app restarts
- Cancels scheduled wakes when disabled or when the app quits
- Multiple Macs trying the same banked reset do not consume it multiple times

Automatic Reset runs independently of notifications. Configure result alerts in [Notification Options](notifications.md#automatic-reset-notifications). Its settings apply only to the current Mac.

## About

| Item | Action or meaning |
| --- | --- |
| Source | Automatic selection prefers Codex CLI, then Codex bundled with ChatGPT App or Codex App; manual selection is also available |
| Reconnect | Reconnect using the selected source; use after upgrading Codex to switch immediately to the new version |
| Codex CLI / Codex APP | View detected versions; click a path to copy it |
| Currently Using | Source and version used by the current connection |
| Unavailable (Codex source) | A previously used or selected source can no longer be found |
| CodexBar Helper | View the background component's installation and authorization status |
| CodexBar Version / Check for Updates | View the version and check for updates |
| GitHub Project | Open the project page |
| Quit CodexBar | Exit the app |

Source selection is temporarily disabled while connecting. Connection failure reasons appear below the version area to help you troubleshoot or choose another source.

CodexBar Helper status always appears in About, regardless of the Automatic Reset and sleep prevention switches:

| Status | Meaning |
| --- | --- |
| Not Installed | Not yet registered, with no detected component or installation issue; normal on first use |
| Not Authorized | Registered, but still needs permission to run in the background |
| Authorized | Background execution is approved and no component issue is currently detected; individual operations can still fail |
| Unavailable | Components are missing, configuration or signatures are invalid, or installation failed while unregistered |

A detected component issue displays Unavailable even if authorization was previously granted. See [CodexBarHelper Cannot Be Registered](troubleshooting.md#codexbarhelper-cannot-be-registered).

Back to the [User Guide](README.md).

# Troubleshooting

[简体中文](../../UserGuide/troubleshooting.md) | English

## CodexBar Is Missing from the Menu Bar

- CodexBar is a menu bar app and does not show a Dock icon
- Check Control Center settings in macOS to make sure the menu bar item is not hidden
- Launching CodexBar again from Applications does not create a second instance
- If it is still missing, check Activity Monitor to confirm that CodexBar is running

## The Main Panel Says “Not Signed In”

1. Open the Codex CLI, ChatGPT App, or Codex App currently in use
2. Sign in to Codex
3. Double-click the account icon in the CodexBar main panel to refresh
4. If it still says you are not signed in, quit and reopen CodexBar

Automatic mode prefers the global Codex CLI. The `In Use` indicator on the About page identifies the actual source, which you can change with the Source selector.

## The Main Panel Says “Initialization Failed”

Check the connection error in `Settings > About`, confirm Codex is installed at an available path, and review proxy settings. Click `Reconnect` after fixing the issue. If it persists, open Logs for details.

## Proxy Configuration or Connection Failures

Open `Settings > Advanced > Proxy` and use `Test Connection` to check the draft. Server and port are required; authentication also requires a username. Invalid fields are outlined in red with a short reason beside the test button.

- If About reports an invalid server or username, correct and save the settings, or turn the proxy off
- If the configuration cannot be read, use `⋯ > Delete Configuration` at the top right of the dialog
- A correctly formatted but unreachable proxy can still be saved and enabled; use Test Connection to check connectivity
- HTTPS requires the proxy endpoint itself to support TLS and present a valid certificate

## Rate Limits or Tokens Appear Dimmed

A dimmed value means that the current read failed and CodexBar fell back to cached data for the same account.

Double-click the account icon to retry. If data remains faded, check the connection error in About or open Logs.

## CodexBar Hook Cannot Be Enabled or Validated

| Message | Action |
| --- | --- |
| A newer Codex version is required | Update Codex, then click `Reconnect` in About |
| Codex Hook is globally disabled | Re-enable `features.hooks` in Codex configuration |
| CodexBar Hook is incomplete | Reopen Settings for automatic repair; if needed, turn Hook off and back on |
| CodexBar Hook is untrusted | Re-enable Hook and review Codex’s trust prompts |
| Unexpected CodexBar Hook source | Verify the selected Codex source and the location of `CODEX_HOME` |
| Invalid `hooks.json` format | Repair the file’s JSON format and retry |
| Cannot validate Codex Hook | Reopen Settings after the Codex connection recovers |

The default configuration file is `~/.codex/hooks.json`. If `CODEX_HOME` is set, use `hooks.json` in that directory.

## Live Tasks Do Not Appear

1. Confirm that CodexBar Hook is enabled with no error
2. Confirm that `Tasks` is enabled under `General > Main Panel Layout`
3. Start a new Codex task to generate live events
4. Open Settings to trigger Hook validation again

Restarting CodexBar does not replay old task notifications.

## System Notifications Do Not Arrive

Check in this order:

1. `System Notifications` is enabled
2. macOS allows notifications from CodexBar
3. The relevant notification option is enabled
4. CodexBar Hook is valid for task notifications
5. The completed task reached the selected duration threshold
6. The notification sound is not set to silent

Haptic feedback does not require macOS notification permission, but it does require CodexBar's System Notifications switch.

## Sleep Prevention Does Not Engage

Check in this order:

1. CodexBar Hook is valid
2. `Prevent System Sleep` is enabled
3. A task is currently running
4. If only waiting tasks exist, `Keep Awake While Waiting` is enabled
5. Settings does not report that CodexBar needs approval to run in the background
6. Low Battery Protection is not active
7. The Keep-Awake Limit has not been reached

The coffee cup indicates that system sleep is actually being prevented. An enabled switch without a coffee cup is not necessarily an error.

If Settings says `System sleep is disabled by another source`, CodexBar does not overwrite that source.

## CodexBarHelper Cannot Be Registered

- Confirm that `Automatic Reset` or `Prevent System Sleep` is enabled; Helper status is hidden while both are off
- If the Helper is awaiting approval, click `Open System Settings` below the settings row and allow CodexBar to run in the background
- Confirm that CodexBar is in Applications and that the app bundle is complete
- If the service is reported as unhealthy or the CodexBarHelper file is missing, reinstall the complete CodexBar app
- If failures continue after an update, quit CodexBar, reopen it, and check authorization again

## Automatic Reset Did Not Run on Time

Check in this order:

1. `Automatic Reset` is enabled and its lead time is what you expect
2. The Automatic Reset row does not report pending CodexBarHelper approval, missing registration, or wake-schedule failure; the lead-time options appear only after the Helper is approved
3. The main panel shows an available banked reset and its expiration time
4. Network access and Codex sign-in were available at the scheduled time
5. `Automatic Reset Notifications` is enabled if you expected a notification; disabling notifications does not stop Automatic Reset itself

Temporary failures retry for up to 5 minutes per round; later refreshes may try again. Disabling Automatic Reset or quitting CodexBar cancels its wake schedule.

## Cross-Device Sync Is Unavailable

- Confirm that the Mac is signed in to iCloud
- Confirm that iCloud Drive and CloudKit are available
- Confirm that CodexBar Hook is enabled
- Confirm that `Sync Across Devices` is enabled
- Hover over the iCloud icon at the bottom of the main panel for the detailed status

A sync failure does not delete local Hook data. A later maintenance run retries it.

## CodexBar Still Shows the Old Version After Updating Codex

Click `Reconnect` in About to use the updated Codex.

## Using the Logs Window

Open it by either:

- Right-clicking the menu bar icon and selecting `Log`
- Pressing `⌘L` while the main panel is open

The Logs window retains the latest 500 Codex interactions from the current run.

Each entry includes request time, method, status, and response time. Expand it to inspect a request, response, or error preview.

You can view or copy the full content in a separate window. It cannot be recovered after you clear the log or quit the app.

## Report a Problem

Include reproduction steps, CodexBar and Codex versions, and visible errors. Interaction logs may contain account and request content; review private information before sharing.

Back to the [User Guide](README.md).

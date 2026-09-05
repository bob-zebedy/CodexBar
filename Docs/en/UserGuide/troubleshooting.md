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

Common causes include:

- No executable Codex installation was found
- Codex app-server failed to start
- app-server did not respond before the timeout
- app-server returned a response that could not be parsed

Open the Logs window for the latest failed request and error details, then check the Codex path and version on the About page.

## Rate Limits or Tokens Appear Dimmed

A dimmed value means that the current read failed and CodexBar fell back to cached data for the same account.

The cache preserves the last available information; it does not mean that the data refreshed successfully.

Double-click the account icon to retry. If the values remain dimmed, check `account/rateLimits/read` and `account/usage/read` in the Logs window.

## CodexBar Hook Cannot Be Enabled or Validated

| Message | Meaning | Recommended action |
| --- | --- | --- |
| A newer Codex version is required | The current app-server version is too old | Update Codex, then click Refresh Connection on the About page |
| Codex Hook is disabled globally | `features.hooks` is disabled | Re-enable Hooks in the Codex configuration |
| CodexBar Hook is incomplete | At least one required event is missing the current handler | Reopen Settings to trigger automatic repair; if it still fails, turn Hook off and on again |
| CodexBar Hook is not trusted | Codex still considers the handler untrusted or modified | Re-enable the Hook and inspect the Codex configuration |
| Unexpected CodexBar Hook source | app-server reported a source other than the active configuration file | Check `CODEX_HOME` and the active Codex source |
| Invalid `hooks.json` format | The top-level value or `hooks` structure is not valid JSON | Repair the JSON, then try again |
| Unable to validate Codex Hook | app-server is temporarily unavailable or validation failed | Check the logs and reopen Settings after Codex becomes available |

The Hook configuration is at `$CODEX_HOME/hooks.json`, or `~/.codex/hooks.json` when `CODEX_HOME` is unset.

CodexBar automatically restores required events and trust data missing from an enabled Hook at launch, when the menu opens, and after each quota refresh. If a transient error prevents automatic repair, turning Hook off and on still rebuilds the complete configuration.

## Live Tasks Do Not Appear

1. Confirm that CodexBar Hook is enabled with no error
2. Confirm that `Tasks` is enabled under `General > Main Panel Layout`
3. Start a new Codex task to generate live events
4. Open Settings to trigger Hook validation again

CodexBar does not send notifications for old tasks during history replay. When data-source boundaries are unstable, it falls back safely and skips untrusted history.

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
3. The current app-server response includes a specific available reset credit and expiration time
4. Network access and Codex sign-in were available at the scheduled time
5. `Automatic Reset Notifications` is enabled if you expected a notification; disabling notifications does not stop Automatic Reset itself

Automatic Reset processes only credits explicitly listed in the latest app-server response. A single round retries network or temporary service failures continuously for no more than 5 minutes. Later normal rate-limit refreshes can schedule another attempt for a credit that remains valid.

Disabling Automatic Reset or quitting CodexBar cancels the current wake schedule. To inspect system schedules, run this command in Terminal:

```bash
pmset -g sched
```

## Cross-Device Sync Is Unavailable

- Confirm that the Mac is signed in to iCloud
- Confirm that iCloud Drive and CloudKit are available
- Confirm that CodexBar Hook is enabled
- Confirm that `Sync Across Devices` is enabled
- Hover over the iCloud icon at the bottom of the main panel for the detailed status

A sync failure does not delete local Hook data. A later maintenance run retries it.

## CodexBar Still Shows the Old Version After Updating Codex

The current version comes from the running app-server handshake. The on-disk version comes from running Codex `--version` again.

If About shows the new installed version but `In Use` still shows the old one, click Refresh Connection. Alternatively, the next request after the connection is one hour old rebuilds it automatically.

## Using the Logs Window

Open it by either:

- Right-clicking the menu bar icon and selecting `Log`
- Pressing `⌘L` while the main panel is open

The Logs window keeps the latest 500 app-server requests from the current process.

Each entry includes request time, method, status, and response time. Expand it to inspect a request, response, or error preview.

You can view or copy the full content in a separate window. It cannot be recovered after you clear the log or quit the app.

## Viewing System Logs

Run this command in Terminal:

```bash
/usr/bin/log stream --predicate 'subsystem == "app.zabrian.codexbar"' --style compact
```

Debug builds use a `subsystem` with a `.debug` suffix.

When reporting an issue, describe the reproduction steps and visible error. Before sharing logs, check whether the in-app interaction log contains request data that you do not want to disclose.

Back to the [User Guide](README.md)

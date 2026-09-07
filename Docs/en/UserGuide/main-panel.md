# Main Panel and Menu Bar

[简体中文](../../UserGuide/main-panel.md) | English

## Menu Bar Icon

CodexBar combines its icon, a status dot, and an optional rate-limit bar to show account, task, and rate-limit status:

| Appearance | Meaning |
| --- | --- |
| Normal account icon | Account data is available |
| Error account icon | You are signed out, initialization failed, or trusted rate-limit and usage data is unavailable |
| Blue status dot | At least one task is running |
| Orange status dot | At least one task is waiting for your approval |
| Green status dot | A task has just finished; the highlight remains for 30 seconds |
| Rate-limit bar beside the icon | Remaining percentage in the selected rate-limit window |

When several states exist at once, waiting for approval takes priority over running, and running takes priority over recently completed.

Hover over the menu bar icon to see the current task state, project name, elapsed time, number of concurrent tasks, and remaining percentage in the selected rate-limit window.

When rate-limit data comes from cache, the icon and progress bar become translucent to indicate that the visible data is not the latest snapshot.

## Layout Customization

Reorder and show or hide sections in `Settings > General > Main Panel Layout`, with undo and redo support. See [Settings Reference](settings.md#main-panel-layout).

## Account

- Shows the signed-in account or account type
- Identifies Enterprise, Team, Business, Pro, Plus, Edu, and Free plans
- Double-clicking the account icon refreshes account, rate-limit, and usage data immediately
- Double-clicking the email toggles blurring
- Shows `Not signed in` when no account is signed in
- Shows the minimum-version requirement when the Codex currently in use is too old
- Shows `Initialization failed` when the Codex connection cannot initialize

The About page in Settings shows the connection failure reason; the Logs window provides complete requests and responses.

## Rate Limits

CodexBar shows every rate-limit group and window returned by Codex.

Each rate-limit window includes:

- A window name, such as `5h` or `7d`
- Remaining percentage
- A segmented progress bar
- The next reset time

When `Animation Effects` is enabled, each segmented progress bar fills from zero to its current remaining percentage whenever the main panel opens.

The primary rate-limit group may also show:

- Available credits or unlimited-credit status
- Available banked resets
- The expiration time for each batch of banked resets

Click `Banked Resets` to view expiration times by batch. The entry appears when the available count is greater than `0`.

## Token Usage and Heatmap

The summary area shows:

- All-time token usage
- Highest daily token usage
- Current usage streak
- Longest usage streak
- Longest task duration

The heatmap uses a 30-column by 7-row grid to show daily token usage over the last 30 weeks. Color intensity is relative to the highest value currently visible in the heatmap.

When `Animation Effects` is enabled, the day squares appear from the top left to the bottom right whenever the main panel opens.

Hover over a day to see its date, token count, and usage intensity.

When CodexBar Hook is enabled and data exists for that day, the details also include:

- Most-used model
- Sessions
- Turns
- Subagents
- Tool calls
- Permission requests
- Context compactions

## Activity Card

Activity-card states are prioritized as waiting for approval, running, recently completed, then recently terminated.

The card shows the following fields when available:

- Project name
- Model and reasoning effort
- Current tool or execution stage
- Running or waiting duration
- Active subagent count
- Number of other concurrent tasks
- Anonymous-task icon

When sleep prevention is actively engaged, a coffee-cup indicator appears on the right side of the activity card.

Tasks whose session cannot be identified show an orange anonymous icon with the tooltip `Anonymous tasks do not prevent sleep`.

The activity card’s `+N` shows the total number of other active tasks.

Click a populated activity card to open Task Center.

## Task Center

Task Center groups tasks into:

- Waiting for Approval
- Running
- Recently Completed
- Recently Terminated

Recently completed and terminated records remain for 10 minutes. Completion means a turn ended; termination means it was interrupted and does not trigger a completion notification.

Completion does not guarantee a successful result.

## Footer Status

The bottom of the main panel shows:

- Data update time
- Countdown to the next automatic refresh
- iCloud sync status: off, syncing, synced, or failed
- Available-update indicator

When a new version is available, double-click the update indicator to start the update.

Back to the [User Guide](README.md)

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

## Account

- Shows the signed-in account or account type
- Identifies Enterprise, Team, Business, Pro, Plus, Edu, and Free plans
- Double-clicking the account icon refreshes account, rate-limit, and usage data immediately
- Double-clicking the email toggles blurring
- Shows `Not signed in` when no account is signed in
- Shows `Initialization failed` when app-server cannot initialize

The main panel presents only states that help you decide what to do. Detailed request errors remain available in the Logs window.

## Rate Limits

CodexBar shows every rate-limit group and window returned by Codex.

Each rate-limit window includes:

- A window name, such as `5h` or `7d`
- Remaining percentage
- A segmented progress bar
- The next reset time

The primary rate-limit group may also show:

- Available credits or unlimited-credit status
- Available reset credits
- The expiration time for each batch of reset credits

Click the reset-credit count to open its details. This entry appears only when Codex reports available reset credits.

## Token Usage and Heatmap

The summary area shows:

- All-time token usage
- Highest daily token usage
- Current usage streak
- Longest usage streak
- Longest task duration

The heatmap uses a 30-column by 7-row grid to show daily token usage over the last 30 weeks. Color intensity is relative to the highest value currently visible in the heatmap.

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

If a Hook event has no session ID, the task still appears in the activity card and Task Center with an orange anonymous icon. Hovering over the icon shows `Anonymous tasks do not prevent sleep`.

The activity card's `+N` shows only the total number of other active tasks; it does not break out anonymous tasks separately.

Click a populated activity card to open Task Center.

## Task Center

Task Center groups tasks into:

- Waiting for Approval
- Running
- Recently Completed
- Recently Terminated

Recently completed and recently terminated tasks remain in Task Center for 10 minutes. Completion and termination are distinct states.

Completion means that a task turn ended; it does not necessarily mean that the result was successful.

Terminated tasks do not trigger task-completion notifications.

Anonymous tasks use the same anonymous icon while running, waiting for approval, recently completed, or recently terminated.

## Footer Status

The bottom of the main panel shows:

- Data update time
- Countdown to the next automatic refresh
- iCloud sync status: off, syncing, synced, or failed
- Available-update indicator

When a new version is available, double-click the update indicator to start the update.

Back to the [User Guide](README.md)

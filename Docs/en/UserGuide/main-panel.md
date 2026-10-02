# Main Panel and Menu Bar

[简体中文](../../UserGuide/main-panel.md) | English

## Menu Bar Icon

CodexBar combines a person symbol with an optional circular rate-limit arc:

| Appearance | Meaning |
| --- | --- |
| Plain person | Default or idle state |
| Pale orange person and badge | Account data indicates ordinary usage is restricted |
| Slashed person | You are signed out, initialization failed, or trusted rate-limit and usage data is unavailable |
| Clock badge | At least one task is running |
| Key badge | At least one task is waiting for approval |
| Shield with a checkmark | A task finished within the last 10 seconds |
| Shield with an exclamation mark | A task was terminated within the last 10 seconds |
| Circular arc with a bottom gap | Remaining percentage in the selected rate-limit window, using the same colors as the panel |

Account errors take priority, followed by waiting for approval, running, and the latest completion or termination within 10 seconds. The most recent timestamp determines which terminal state appears.

The person symbol grows when the quota arc is hidden.

Hover over the menu bar icon to see the current task state, project name, elapsed time, number of concurrent tasks, and remaining percentage in the selected rate-limit window.

Cached rate-limit data dims the icon and arc. Zero quota retains the empty track; unavailable or disabled quota hides the arc.

## Layout Customization

Reorder and show or hide sections in `Settings > General > Main Panel Layout`, with undo and redo support. See [Settings Reference](settings.md#main-panel-layout).

## Account

- Shows the signed-in account or account type
- Identifies Enterprise, Team, Business, ProMax, Pro, ProLite, Plus, Go, Edu, and Free plans
- Double-clicking the account icon refreshes account, rate-limit, and usage data immediately
- Double-clicking the email toggles blurring
- Shows `Not signed in` when no account is signed in
- Shows the minimum-version requirement when the Codex currently in use is too old
- Shows `Initialization failed` when the Codex connection cannot initialize

The About page in Settings shows the connection failure reason; the Logs window provides complete requests and responses.

## Rate Limits

CodexBar shows every rate-limit group and window returned by Codex.

Each rate-limit window includes:

- A window name, such as `5 Hours` or `Weekly`
- Remaining percentage
- A segmented progress bar
- The next reset time

When `Animation Effects` is enabled, each segmented progress bar fills from zero to its current remaining percentage whenever the main panel opens.

Glass dividers use a slowly flowing gradient independently of `Animation Effects`; the animation pauses while their window is hidden.

The primary rate-limit group may also show:

- Available credits or unlimited-credit status
- Available banked resets
- The expiration time for each batch of banked resets

Click `Banked Resets` to view expiration times by batch. The entry appears when the available count is greater than `0`.

## Token Usage and Heatmap

Account usage comes from app-server. The summary area shows:

- All-time token usage
- Highest daily token usage
- Current usage streak
- Longest usage streak
- Longest task duration

The heatmap shows recent daily token usage by date. Color intensity is relative to the highest value currently visible in the heatmap.

When `Animation Effects` is enabled, the day squares appear from the top left to the bottom right whenever the main panel opens.

Hover over a day to see its date, token count, and usage intensity.

When Advanced Mode is enabled, the details also include:

- Most-used model
- Sessions
- Turns
- Subagents
- Tool calls
- Permission requests
- Context compactions

Date details group activity statistics and daily rollout token usage, with an intensity bar showing relative usage. Token metrics include totals, input and output, cache usage, and reasoning output. Token counts use K/M/B units. Missing and zero counts display `0`; missing or zero cache hit rate displays `0%`. Activity counts, token values, and the most-used model roll between values when the selected date changes.

Each thread turn contributes once. Main and child-agent usage belongs to the root task's start date, including tasks that cross midnight. Daily cache hit rate divides total cached input by total input. With iCloud sync enabled, duplicate turns across Macs are merged before daily aggregation.

Heatmap colors, the token count beside the date, and intensity come from app-server. Session tokens in the right column come from local rollouts and iCloud history, with a different scope. See [Data, Sync, and Privacy](sync-data-privacy.md#historical-token-replay) for backfill, incremental reads, and rebuilding.

## Activity Card

The activity card prioritizes tasks waiting for approval, then running tasks. With no active tasks, it shows the latest completion or termination by end time, with termination taking precedence on ties.

The card shows the following fields when available:

- Project name
- Model and reasoning effort
- Current tool or execution stage
- Running or waiting duration
- Active subagent count
- Number of other concurrent tasks
- Anonymous-task icon

While sleep prevention is active, a teal sun badge appears on the right side of the activity card. Hover over it to see the sleep-prevention source. The badge rotates while Animation Effects is enabled and stays static when it is disabled.

Tasks whose session cannot be identified show an orange anonymous icon with the tooltip `Anonymous tasks do not prevent sleep`.

The activity card’s `+N` shows the total number of other active tasks.

Click a populated activity card to open Task Center. In both views, status-text colors follow task state. With Animation Effects enabled, running status text shimmers and orange particles appear around approval-waiting text. Disabling the setting keeps the colored text static.

### Token Usage for the Current Turn

Once rollout usage is available, the activity card shows token metrics beneath its status, including totals, input and output, cache usage, and reasoning output. Counts use K/M/B units. The usage row and its divider expand or collapse together, independently of `Animation Effects`. Both remain hidden when usage is unavailable.

While a task is running or waiting for approval, usage updates for main and child threads whose ownership is confirmed. Later thread records fill in the subtotal. After completion or termination is confirmed, background usage queries run for up to 30 seconds, displaying a complete total when available and accepting updates until the deadline. The terminal state appears immediately, without a query countdown or loading indicator. If usage is still unavailable at expiry, the usage area stays hidden; values already obtained remain visible. These values cover the current turn and its subagents.

Total equals input plus output. Cached input and cache write are included in input; reasoning is included in output. These subsets must not be added to the total again. Cache-H is cached input divided by input; the card shows `—` when input is zero. Cached shows the number of input tokens served from cache; Cache-W shows cache writes.

## Task Center

Task Center groups tasks into:

- Waiting for Approval
- Running
- Recently Completed
- Recently Terminated

Recently completed and terminated records remain for 10 minutes. Completion means a turn ended, without implying success. Termination records include interruptions and other task terminations, and do not trigger completion notifications.

Recently completed and terminated entries show total tokens for the turn when available, using K/M/B units. Running and waiting entries show task status; the main-panel activity card displays usage for the task it summarizes.

## Footer Status

The bottom of the main panel shows:

- Data update time
- Countdown to the next automatic refresh
- iCloud sync status: off, syncing, synced, or failed
- Available-update indicator

When a new version is available, double-click the update indicator to start the update.

Back to the [User Guide](README.md)

# Live Tasks and Advanced Mode

[简体中文](../../UserGuide/advanced-mode.md) | English

Advanced Mode provides live task status, task notifications, haptics, task-based sleep prevention, and daily session, turn, and tool-call statistics. It also enables syncing daily activity statistics and rollout token history. Rebuild Data recalculates both types of retained local history.

## Enable Advanced Mode

1. Open `Settings > Advanced`
2. Enable `Advanced Mode` and wait for validation
3. Start a Codex task and check its status in the main panel

Advanced Mode requires the Codex currently in use to be `0.153.0` or later. If the version warning remains after upgrading, click `Reconnect` in `Settings > About`. For other errors, see [Troubleshooting](troubleshooting.md#advanced-mode-cannot-be-enabled-or-validated).

CodexBar automatically checks and repairs enabled Hook configuration, preserving handlers belonging to users and other apps. If Codex is confirmed to be below the minimum version, Advanced Mode is disabled and CodexBar removes its handlers; enable Advanced Mode again after upgrading Codex. Configuration is retained for the next check if the connection or version is temporarily unavailable.

## Task States

| State | Meaning |
| --- | --- |
| Running | Codex is processing the task |
| Waiting for Approval | You need to approve the next action |
| Recently Completed | A turn ended; its result is not necessarily successful |
| Recently Terminated | An interruption or other terminal signal confirmed termination; no completion notification is sent |

After `Stop`, the task shows “Finishing up”, with approval waiting taking priority while a subagent still waits. A completion notification is sent after the turn is confirmed complete and the notification settings are satisfied; an interruption during that time is shown as terminated.

Interruption ends only the matching turn; a newer turn in the same session stays active. Task-based sleep prevention releases once all eligible tasks end.

Subagent activity is combined with its parent task. Internal automatic-review tasks and tasks whose origin remains unconfirmed do not appear as live tasks or trigger Task Glow, task alerts, or sleep prevention; their activity still contributes to daily statistics. Once the same session and turn have been confirmed as a normal task, later events with a temporarily unknown origin continue updating its state.

When the main agent or a subagent waits for approval, progress from another agent does not clear its wait. The card stays in the waiting state while any user approval wait remains in that task.

Tasks with a known origin whose session cannot be identified show an orange anonymous icon. You can view them, but they do not trigger notifications or haptics, prevent sleep, or participate in Stalled Task Protection.

[Stalled Task Protection](sleep-prevention.md#stalled-task-protection) may hide running tasks that stop making progress. They reappear when progress resumes.

## Daily Statistics

Hover over a day in the main-panel heatmap to see sessions, turns, tool calls, permission requests, context compactions, subagents, and the most-used model in the left column, with session token totals on the right. Token usage belongs to the root turn’s start date, unlike daily activity counts. See [Token Usage and Heatmap](main-panel.md#token-usage-and-heatmap).

Sessions and turns are deduplicated within each day; activity continuing into another day counts toward that day. Sessions with only a session-end event and turns with only completion-candidate or interruption events do not count as active that day. Tool calls use the larger of the start and end event counts.

## Disable Advanced Mode

Disabling Advanced Mode stops updates to live tasks, task notifications, haptics, sleep prevention, and Hook statistics, and stops cross-device sync for activity and token history. The heatmap hides its history details. Account, quota, and the app-server token heatmap remain available.

Hook records task information such as time, model, tool name, and project, without saving prompt, reply, or tool input/output content. See [Data, Sync, and Privacy](sync-data-privacy.md) for retention and sync details.

Back to the [User Guide](README.md).

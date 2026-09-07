# Live Tasks and CodexBar Hook

[简体中文](../../UserGuide/activity-and-hook.md) | English

CodexBar Hook provides live task status, task notifications, haptics, task-based sleep prevention, and daily session, turn, and tool-call statistics. It also enables syncing and rebuilding those daily statistics.

## Enable Hook

1. Open `Settings > Advanced`
2. Enable `CodexBar Hook` and wait for validation
3. Start a Codex task and check its status in the main panel

Hook requires the Codex currently in use to be `0.145.0` or later. If the version warning remains after upgrading, click `Reconnect` in `Settings > About`. For other errors, see [Troubleshooting](troubleshooting.md#codexbar-hook-cannot-be-enabled-or-validated).

CodexBar automatically checks and repairs enabled Hook configuration. Enabling or disabling it preserves Hooks belonging to you and other apps.

## Task States

| State | Meaning |
| --- | --- |
| Running | Codex is processing the task |
| Waiting for Approval | You need to approve the next action |
| Recently Completed | A turn ended; its result is not necessarily successful |
| Recently Terminated | The task was interrupted; no completion notification is sent |

Subagent activity is combined with its parent task. Internal automatic-review tasks do not appear separately or trigger task alerts or sleep prevention; their activity still contributes to daily statistics.

Tasks whose session cannot be identified show an orange anonymous icon. You can view them, but they do not trigger notifications or haptics, prevent sleep, or participate in Stalled Task Protection.

[Stalled Task Protection](sleep-prevention.md#stalled-task-protection) may hide running tasks that stop making progress. They reappear when progress resumes.

## Daily Statistics

Hover over a day in the main panel heatmap to view sessions, turns, tool calls, permission requests, context compactions, subagents, and the most-used model.

Sessions and turns are deduplicated within each day; activity continuing into another day counts toward that day. Paired records such as tool-call events may be incomplete, so statistics reflect the activity CodexBar actually observed.

## Disable Hook

Disabling Hook stops updates to live tasks, task notifications, haptics, sleep prevention, Hook statistics, and their cross-device sync. Account, quota, and token heatmap features remain available.

Hook records task information such as time, model, tool name, and project, without saving prompt, reply, or tool input/output content. See [Data, Sync, and Privacy](sync-data-privacy.md) for retention and sync details.

Back to the [User Guide](README.md).

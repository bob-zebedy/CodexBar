# Live Tasks and CodexBar Hook

[简体中文](../../UserGuide/activity-and-hook.md) | English

## What the Hook Provides

Account, rate-limit, and token usage data are periodic snapshots. They cannot tell you whether a Codex task is running, waiting for approval, or finished.

CodexBar Hook records a small set of structured fields when key Codex events occur, enabling:

- Menu bar task-status dots and task details
- The main-panel activity card and Task Center for concurrent tasks
- Alerts for task completion, approval requests, and stalled tasks
- Haptic feedback for task events
- Daily metrics for sessions, turns, tool calls, permission requests, context compactions, and subagents
- Automatic sleep prevention based on live tasks
- Cross-device sync of daily Hook aggregations
- Rebuilding historical aggregations from raw events

## Requirements

Before enabling CodexBar Hook, make sure that:

- CodexBar can connect to the currently running Codex app-server
- The running app-server version is `0.145.0` or later
- `features.hooks` is not disabled globally in the Codex configuration
- The current `hooks.json` is valid JSON

The version check uses the handshake version from the connected app-server, not a newly installed version on disk.

If CodexBar still reports an older version after you update Codex, quit and reopen CodexBar to establish a new connection.

## Enabling the Hook

1. Right-click or Control-click the menu bar icon
2. Select `Settings`
3. Open the `Advanced` page
4. Enable `CodexBar Hook`
5. Wait for configuration and validation to finish

CodexBar checks the installed Hook again whenever you open Settings or reactivate the app.

## Configuration Changes

CodexBar uses `$CODEX_HOME/hooks.json`, or `~/.codex/hooks.json` when `CODEX_HOME` is unset.

When enabled, CodexBar:

1. Reads and preserves the existing configuration
2. Appends a separate command handler for CodexBar
3. Asks Codex to validate the event list, source, and trust status
4. Updates only trust entries that match the current CodexBar handler

When disabled, it removes only handlers that match both the current CodexBar executable path and the `--hook-event` argument.

Your own handlers, handlers from other apps, unrecognized fields, and unrelated trust entries are preserved.

## Understanding Task States

| State | Meaning | Active task? |
| --- | --- | --- |
| Running | The task is still making progress | Yes |
| Waiting for Approval | The task is waiting for you to approve its next action | Yes |
| Recently Completed | A task turn has been confirmed as finished | No |
| Recently Terminated | A task turn has been confirmed as terminated | No |
| Hidden | A running task exceeded the stalled-task silence threshold | No |

Completion means that a task turn ended; it does not necessarily mean that the result was successful.

Waiting for Approval applies only to approval requests that require user action. Automatically reviewed requests are not shown as waiting for you.

Subagent events update their parent top-level task instead of appearing as separate concurrent tasks.

When a Hook event has no session ID, CodexBar shows an anonymous task for its project. Anonymous tasks can still appear in Running, Waiting for Approval, Recently Completed, and Recently Terminated lists, but they do not trigger task notifications or haptic feedback and do not participate in sleep prevention or stalled task protection.

The activity card and Task Center mark these tasks with an orange anonymous icon. Hovering over it shows `Anonymous tasks do not prevent sleep`.

## Hook Events and Their Uses

| Event | Primary use |
| --- | --- |
| `SessionStart` and `SessionEnd` | Session lifecycle, session metrics, and task finalization |
| `UserPromptSubmit` and `Stop` | Turn metrics, task start, and completion candidates |
| `PreToolUse` and `PostToolUse` | Tool-call metrics and task progress |
| `PermissionRequest` | User-waiting state and permission-request metrics |
| `PreCompact` and `PostCompact` | Context-compaction metrics and task progress |
| `SubagentStart` and `SubagentStop` | Subagent count, state, and task progress |

## How Daily Metrics Are Calculated

| Metric | Meaning |
| --- | --- |
| Sessions | Number of distinct Codex sessions on that day |
| Turns | Number of distinct turns on that day |
| Tool calls | The larger of the `PreToolUse` and `PostToolUse` counts |
| Permission requests | Number of `PermissionRequest` events |
| Context compactions | The larger of the `PreCompact` and `PostCompact` counts |
| Subagents | The larger of the `SubagentStart` and `SubagentStop` counts |
| Most-used model | The model that appears most often in Hook events for that day |

Using the larger count preserves observed operations when one side of an event pair is missing.

## Effects of Disabling the Hook

Disabling CodexBar Hook stops updates to:

- Live tasks and Task Center
- Menu bar task-status dots
- Task notifications and haptic feedback
- Daily Hook metrics
- Sleep prevention
- Cross-device sync of Hook aggregations

Account data, rate limits, the token heatmap, update checks, and the Logs window remain available.

## Data Boundaries

Raw Hook events contain only structured fields such as time, event name, model, reasoning effort, approval mode, `reviewer`, `session`, `turn`, `agent`, tool name, and working directory.

CodexBar does not store prompt text, Codex responses, tool arguments, or tool output.

See [Data, Sync, and Privacy](sync-data-privacy.md) for complete storage and sync boundaries.

Back to the [User Guide](README.md)

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

If CodexBar still reports an older version after you update Codex, click Refresh Connection under Settings > About.

## Enabling the Hook

1. Right-click or Control-click the menu bar icon
2. Select `Settings`
3. Open the `Advanced` page
4. Enable `CodexBar Hook`
5. Wait for configuration and validation to finish

CodexBar checks an enabled Hook at launch, when you open the menu or Settings, when the app becomes active again, and after each quota refresh. Automatic quota refresh normally completes every 60 seconds, and missing required event configuration or trust entries are repaired automatically.

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

Codex Auto-review uses a separate reviewer agent for permission review. CodexBar recognizes and excludes that internal review task, so it does not appear in the menu bar, activity card, or Task Center and cannot trigger notifications, haptics, Stalled Task Protection, or sleep prevention. Existing behavior for other subagents is unchanged.

Auto-review origin is identified from rollout metadata first. When rollout origin is unavailable, an exact `codex-auto-review` model match serves as the fallback. Live activity applies the same rule while reading local Hook records without backfilling or rewriting the raw records.

When a Hook event has no session ID, CodexBar shows an anonymous task for its project. Anonymous tasks can still appear in Running, Waiting for Approval, Recently Completed, and Recently Terminated lists, but they do not trigger task notifications or haptic feedback and do not participate in sleep prevention or stalled task protection.

The activity card and Task Center mark these tasks with an orange anonymous icon. Hovering over it shows `Anonymous tasks do not prevent sleep`.

## Hook Events and Their Uses

| Event | Primary use |
| --- | --- |
| `SessionStart` and `SessionEnd` | Session lifecycle and task finalization |
| `UserPromptSubmit` and `Stop` | Turn lifecycle, task start, and completion candidates |
| `PreToolUse` and `PostToolUse` | Tool-call metrics and task progress |
| `PermissionRequest` | User-waiting state and permission-request metrics |
| `PreCompact` and `PostCompact` | Context-compaction metrics and task progress |
| `SubagentStart` and `SubagentStop` | Subagent count, state, and task progress |

## How Daily Metrics Are Calculated

| Metric | Meaning |
| --- | --- |
| Sessions | Distinct sessions in the day's events other than `SessionEnd` |
| Turns | Distinct turns in the day's events other than `Stop` |
| Tool calls | The larger of the `PreToolUse` and `PostToolUse` counts |
| Permission requests | Number of `PermissionRequest` events |
| Context compactions | The larger of the `PreCompact` and `PostCompact` counts |
| Subagents | The larger of the `SubagentStart` and `SubagentStop` counts |
| Most-used model | The model that appears most often in Hook events for that day |

Only nonempty session and turn IDs are counted and deduplicated within each day. A session or turn spanning multiple days contributes when that day contains another event; a session observed only through `SessionEnd` and a turn observed only through `Stop` do not contribute.

Using the larger count preserves observed operations when one side of an event pair is missing.

Auto-review is excluded only from the live-task pipeline; its Hook events still contribute to these daily metrics.

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

Raw Hook events contain only structured fields such as time, event name, normalized `origin`, model, reasoning effort, approval mode, `reviewer`, `session`, `turn`, `agent`, tool name, and working directory.

CodexBar does not store rollout paths, raw source values, prompt text, Codex responses, tool arguments, or tool output.

See [Data, Sync, and Privacy](sync-data-privacy.md) for complete storage and sync boundaries.

Back to the [User Guide](README.md)

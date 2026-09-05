# CodexBar User Guide

[简体中文](../../UserGuide/README.md) | English

## Contents

| Document | Contents |
| --- | --- |
| [Installation and Quick Start](getting-started.md) | Requirements, installation, basic controls, and feature dependencies |
| [Main Panel and Menu Bar](main-panel.md) | Menu bar states, account, rate limits, token heatmap, and Task Center |
| [Live Tasks and CodexBar Hook](activity-and-hook.md) | What the Hook does, how to enable it, task states, and historical metrics |
| [Notifications and Alerts](notifications.md) | Triggers, defaults, sounds, and haptic feedback for each notification type |
| [Preventing System Sleep](sleep-prevention.md) | Activation conditions, protection options, CodexBarHelper authorization, and coexistence with external sleep settings |
| [Data, Sync, and Privacy](sync-data-privacy.md) | Local data, iCloud sync, rebuilding data, and network boundaries |
| [Settings Reference](settings.md) | Every setting on the General, Advanced, and About pages, including Automatic Reset |
| [Troubleshooting](troubleshooting.md) | Sign-in, Hook, notifications, Automatic Reset, sleep prevention, sync, and logging issues |

## Find What You Need

- To view only your account and rate limits, start with [Installation and Quick Start](getting-started.md)
- To follow running tasks or tasks waiting for approval, read [Live Tasks and CodexBar Hook](activity-and-hook.md)
- To reset your rate limit automatically before banked resets expire, see [Automatic Reset](settings.md#automatic-reset)
- To keep your Mac awake during long tasks, read [Preventing System Sleep](sleep-prevention.md)
- To find out whether a setting uploads data, read [Data, Sync, and Privacy](sync-data-privacy.md)
- If you already see an error, go directly to [Troubleshooting](troubleshooting.md)

## Terminology

| Term | Meaning |
| --- | --- |
| Codex | Codex capabilities running through Codex CLI, ChatGPT App, or Codex App |
| app-server | The local Codex data-interface process that CodexBar launches and connects to |
| CodexBar Hook | The event handler that CodexBar installs in your Codex configuration |
| Live task | A running task or task waiting for approval, inferred from Hook events and local session state |
| Hook aggregation | Daily session, turn, tool, and other metrics calculated from local raw Hook events |
| CodexBarHelper | CodexBar's background service for system-level sleep-state changes and a fixed Automatic Reset wake schedule |

Back to the [CodexBar README](../../../README.en.md)

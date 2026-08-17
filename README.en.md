<div align="center">

<img src="Images/icon.png" width="128" alt="CodexBar">

# CodexBar

**Codex at a glance, right from your macOS menu bar**

[简体中文](README.md) | English

[![macOS](https://img.shields.io/badge/macOS-15.0+-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Release](https://img.shields.io/github/v/release/bob-zebedy/CodexBar?color=1F6FEB)](https://github.com/bob-zebedy/CodexBar/releases)
[![Downloads](https://img.shields.io/github/downloads/bob-zebedy/CodexBar/total?color=2EA043)](https://github.com/bob-zebedy/CodexBar/releases)
[![License](https://img.shields.io/github/license/bob-zebedy/CodexBar?color=8957E5)](LICENSE)

[Features](#features) | [Installation](#installation) | [Quick Start](#quick-start) | [Documentation](#documentation) | [Privacy](#privacy)

<img src="Images/preview.gif" width="640" alt="CodexBar preview">

</div>

---

CodexBar is a menu bar app for macOS 15 and later that brings your Codex account, rate limits, token usage, and live task status into one place.

It can notify you when a task finishes, needs approval, or when your rate limits change. It can also keep your Mac awake only while Codex tasks are running.

## Features

### Account and rate limits at a glance

- View your current Codex account and plan
- See every rate-limit window, its remaining allowance, and reset time
- Check available credits and reset credits
- Automatically use reset credits from 15 minutes to 6 hours before they expire, with a default lead time of 30 minutes; CodexBar can wake your Mac at the scheduled time and revalidate availability before use
- Show a selected rate-limit window directly beside the menu bar icon

### Understand your Codex usage

- Track total tokens, your highest daily usage, and usage streaks
- See your longest task duration
- Review 30 weeks of daily token usage in a heatmap
- Enable CodexBar Hook for daily session, turn, tool call, subagent, and other activity metrics

### Keep track of active tasks

- Menu bar status dots distinguish running tasks, tasks waiting for approval, and recently completed tasks
- The main panel shows the current task, project, model, reasoning effort, and elapsed time
- Task Center brings concurrent, recently completed, and recently terminated tasks together
- Receive alerts for completed tasks, approval requests, and stalled tasks

### Let long-running tasks finish

- Prevent system sleep only while eligible Codex tasks are active
- Optionally stay awake while waiting for approval or keep the display awake as well
- Set a keep-awake time limit, low-battery protection, and stalled task protection
- Restore normal system sleep automatically when tasks finish or a protection rule is triggered

### Fit naturally into macOS

- Runs as a menu bar app without taking up space in the Dock
- Supports a global keyboard shortcut, launch at login, and automatic updates
- Provides Simplified Chinese and English interfaces
- Optionally merges daily Hook metrics across Macs through iCloud

## Installation

### Homebrew

```bash
brew install --cask bob-zebedy/tap/codexbar
```

### DMG

Download the latest version from [GitHub Releases](https://github.com/bob-zebedy/CodexBar/releases), then drag CodexBar into Applications.

## Requirements

- macOS 15.0 or later
- [Codex CLI](https://github.com/openai/codex) installed and signed in, or ChatGPT App or Codex App with bundled Codex installed
- The running Codex version must be `0.143.0` or later
- Live tasks and other Hook features require the running Codex version to be `0.145.0` or later
- Cross-device sync requires an available iCloud account on the Mac

## Quick Start

1. Launch CodexBar and find its icon in the menu bar
2. Left-click the icon to view your account, rate limits, and token usage
3. Right-click or Control-click the icon to open Settings, Logs, or the Quit menu
4. Enable CodexBar Hook under `Settings > Advanced` to unlock live tasks, task notifications, sleep prevention, and Hook metrics

The default global shortcut is `⌘⇧W`. You can record a different shortcut or disable it in Settings.

## Documentation

| Document | Contents |
| --- | --- |
| [User Guide](Docs/en/UserGuide/README.md) | Installation, main panel, Hook, notifications, sleep prevention, sync, settings, and troubleshooting |
| [Developer Guide](Docs/en/DeveloperGuide/README.md) | Architecture, data flows, core state machines, storage, privacy boundaries, and development validation |
| [Documentation Index](Docs/en/README.md) | Complete documentation index |

## Privacy

CodexBar processes all data locally. It uploads aggregated data to your private iCloud database only when you enable cross-device sync.

See [Data, Sync, and Privacy](Docs/en/UserGuide/sync-data-privacy.md) for complete details about data access, local storage, and network boundaries.

## Feedback

Report bugs, request features, or ask questions through [GitHub Issues](https://github.com/bob-zebedy/CodexBar/issues).

## License

[GNU General Public License v3.0](LICENSE)

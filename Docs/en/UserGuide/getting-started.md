# Installation and Quick Start

[简体中文](../../UserGuide/getting-started.md) | English

## Requirements

- macOS 15.0 or later
- [Codex CLI](https://github.com/openai/codex) installed and signed in, or ChatGPT App or Codex App with bundled Codex installed
- The running Codex app-server must be `0.143.0` or later
- Hook features require the running Codex app-server to be `0.145.0` or later
- Cross-device sync requires an available iCloud account on the Mac

CodexBar prefers a globally installed Codex CLI. If it cannot find one, it tries the Codex bundled with ChatGPT App and Codex App.

## Installation

### Homebrew

```bash
brew install --cask bob-zebedy/tap/codexbar
```

### DMG

1. Download the latest DMG from [GitHub Releases](https://github.com/bob-zebedy/CodexBar/releases)
2. Open the DMG and drag CodexBar into Applications
3. Launch CodexBar from Applications

## First Launch

CodexBar is a menu bar app, so it does not show an icon in the Dock after launch:

1. Find the CodexBar icon in the menu bar at the top of the screen
2. Left-click the icon to open the main panel
3. Wait for the initial account and usage refresh to finish
4. If the panel says you are not signed in, sign in through the active Codex installation first
5. For live tasks, task notifications, sleep prevention, or Hook metrics, enable CodexBar Hook under `Settings > Advanced`

CodexBar refreshes account, rate-limit, and token usage data every 60 seconds. Double-click the account icon in the main panel to refresh immediately.

## Basic Controls

| Action | Result |
| --- | --- |
| Left-click the menu bar icon | Open or close the main panel |
| Right-click or Control-click the menu bar icon | Open the Settings, Logs, and Quit menu |
| `⌘⇧W` | Open or close the main panel with the default global shortcut |
| `⌘,` | Open the Settings window |
| `⌘L` | Close the main panel and open the Logs window while the panel is open |
| Double-click the account icon | Refresh account, rate-limit, and usage data immediately |
| Double-click the account email | Toggle email blurring |
| Hover over a heatmap cell | View token and Hook metrics for that day |
| Click the activity card | Open Task Center for concurrent tasks |
| Click the reset-credit count | View the expiration time of each credit batch |
| `Settings > Advanced > Automatic Reset` | Configure automatic use and lead time |

The global shortcut opens the main panel on the screen under the pointer when possible. If the menu bar anchor is unavailable, CodexBar uses a standalone floating panel.

## Feature Dependencies

| Feature | CodexBar Hook | Other requirements |
| --- | --- | --- |
| Account, plan, and rate limits | Not required | Signed in to Codex; app-server `0.143.0` or later |
| Token totals and heatmap | Not required | app-server `0.143.0` or later |
| Live tasks and Task Center | Required | Hook validation has passed |
| Daily Hook metrics | Required | Local raw Hook events are available |
| Rate-limit notifications | Not required | System Notifications and macOS permission are enabled |
| Automatic Reset | Not required | Confirmation is required each time it is enabled; waking from system sleep and showing the lead-time options require approved CodexBarHelper access; lead time ranges from 15 minutes to 6 hours and defaults to 30 minutes |
| Task notifications | Required | Hook validation has passed and notifications are enabled |
| Prevent System Sleep | Required | Confirmation is required each time it is enabled; CodexBarHelper is registered and approved by macOS |
| Cross-device sync | Required | iCloud is available and sync is explicitly enabled |

Disabling CodexBar Hook does not affect account data, rate limits, the token heatmap, update checks, or the Logs window.

## Language and Region

CodexBar provides Simplified Chinese and English interfaces. By default, it follows the macOS per-app language preference.

To choose a language specifically for CodexBar, use Language & Region in macOS System Settings.

Dates, times, durations, percentages, calendar layout, and the first day of the week always follow the current regional format.

Next, read [Main Panel and Menu Bar](main-panel.md) or the [Settings Reference](settings.md).

<div align="center">

<img src="Images/icon.png" width="128" alt="CodexBar">

# CodexBar

**Codex at a glance, right from your macOS menu bar**

[简体中文](README.md) | English

[![macOS](https://img.shields.io/badge/macOS-15.0+-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![Release](https://img.shields.io/github/v/release/bob-zebedy/CodexBar?color=1F6FEB)](https://github.com/bob-zebedy/CodexBar/releases)
[![Downloads](https://img.shields.io/github/downloads/bob-zebedy/CodexBar/total?color=2EA043)](https://github.com/bob-zebedy/CodexBar/releases)
[![License](https://img.shields.io/github/license/bob-zebedy/CodexBar?color=8957E5)](LICENSE)

[Features](#features) | [Installation](#installation) | [Privacy](#privacy) | [Runtime Architecture](https://codexbar.zabrian.app/architecture) | [Performance Report](https://codexbar.zabrian.app/performance) | [Protocol](Protocol.en.md)

<img src="Images/preview.gif" width="640" alt="CodexBar preview">

</div>

---

CodexBar is a menu bar app for macOS that displays your Codex account information, usage limits, token usage, and real-time task status in one place.

## Features

### Account and rate limits at a glance

- View your account, plan, credits, and the remaining allowance and reset time for each rate-limit window
- Show your preferred allowance directly in the menu bar
- Track banked resets and their expiry dates, with automatic use before they expire

### Follow your tasks in real time

- See each task's project, model, reasoning effort, duration, and token usage
- Follow live states, actions that need your attention, task progress, and recent events
- Review concurrent tasks and recent completions, failures, and interruptions in Task Center

### Review your usage

- Track total usage, daily peaks, usage streaks, and your longest task duration
- Explore daily token usage and activity statistics in a heatmap
- Combine usage records across Macs through iCloud

### Get timely alerts

- Receive alerts for task completions, approval requests, allowance changes, and protection events
- Choose notification types, sounds, and task haptic feedback
- Follow status changes through customizable task glow at the top of your displays

### Keep long tasks running

- Keep your Mac awake while tasks run, then allow normal sleep when they finish
- Optionally stay awake while waiting for approval or keep the display on as well
- Set a keep-awake time limit, low-battery protection, and stalled task protection


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
- Codex background service version `0.162.0` or later
- Cross-device sync requires an available iCloud account on the Mac

## Privacy

Raw activity events and live tasks are processed locally. Enabling cross-device sync uploads daily activity aggregates and token usage records to your private iCloud database.

## Feedback

Report bugs, request features, or ask questions through [GitHub Issues](https://github.com/bob-zebedy/CodexBar/issues).

## License

[GNU General Public License v3.0](LICENSE)

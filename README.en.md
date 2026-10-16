<div align="center">

<img src="Images/icon.png" width="128" alt="CodexBar">

# CodexBar

**Codex at a glance, right from your macOS menu bar**

[简体中文](README.md) | English

[![macOS][badge-macos]](https://www.apple.com/macos/)
[![Codex][badge-codex]](https://github.com/openai/codex)
[![Swift][badge-swift]](https://www.swift.org/)
[![Release][badge-release]](https://github.com/bob-zebedy/CodexBar/releases)
[![Downloads][badge-downloads]](https://github.com/bob-zebedy/CodexBar/releases)
[![License][badge-license]](LICENSE)

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
- Follow live states, pending responses, task progress, and recent events
- Review concurrent tasks and recent completions, failures, and interruptions in Task Center

### Review your usage

- Track total usage, daily peaks, usage streaks, and your longest task duration
- Explore daily token usage and activity statistics in a heatmap
- Combine usage records across Macs through iCloud

### Get timely alerts

- Receive alerts for task completions, pending responses, allowance changes, and protection events
- Choose notification types, sounds, and task haptic feedback
- Follow status changes through customizable task glow at the top of your displays

### Keep long tasks running

- Keep your Mac awake while tasks run, then allow normal sleep when they finish
- Optionally stay awake while awaiting a response or keep the display on as well
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

[badge-macos]: https://img.shields.io/badge/macOS-15.0%2B-6E6E73?style=flat&labelColor=E9E9ED&logo=apple&logoColor=6E6E73
[badge-codex]: https://img.shields.io/badge/Codex-0.162.0%2B-5B6CFF?style=flat&labelColor=E8EBFF&logo=data:image%2Fsvg%2Bxml;base64,PHN2ZyB3aWR0aD0iMzU0LjY3Mzk4MyIgaGVpZ2h0PSIzNTQuNjczOTgzIiB2aWV3Qm94PSIxODAuNDk5NTc1IDE4MC40OTk5NDMgMzU0LjY3Mzk4MyAzNTQuNjczOTgzIiBmaWxsPSJub25lIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPgo8cGF0aCBkPSJNNTA4Ljc0OSAzMTcuMzk5QzUxNi43NzcgMjg3LjMxNCA1MDguOTkxIDI1My44ODQgNDg1LjM4OSAyMzAuMjgyQzQ2MS43ODggMjA2LjY4MSA0MjguMzYgMTk4Ljg5NSAzOTguMjczIDIwNi45MjNDMzc2LjIzMSAxODQuOTI4IDM0My4zOSAxNzQuOTU2IDMxMS4xNDggMTgzLjU5NkMyNzguOTA2IDE5Mi4yMzQgMjU1LjQ1IDIxNy4yOTIgMjQ3LjM2IDI0Ny4zNjFDMjE3LjI5MSAyNTUuNDUxIDE5Mi4yMzMgMjc4LjkxIDE4My41OTUgMzExLjE0OUMxNzQuOTU3IDM0My4zOTEgMTg0LjkyNyAzNzYuMjMyIDIwNi45MjQgMzk4LjI3NEMxOTguODk2IDQyOC4zNTkgMjA2LjY4MyA0NjEuNzg5IDIzMC4yODQgNDg1LjM5MUMyNTMuODg1IDUwOC45OTIgMjg3LjMxMyA1MTYuNzc5IDMxNy40MDEgNTA4Ljc1QzMzOS40NDIgNTMwLjc0NSAzNzIuMjg2IDU0MC43MTcgNDA0LjUyNSA1MzIuMDc5QzQzNi43NjcgNTIzLjQ0MSA0NjAuMjIzIDQ5OC4zODQgNDY4LjMxMyA0NjguMzE1QzQ5OC4zODMgNDYwLjIyNCA1MjMuNDQgNDM2Ljc2NiA1MzIuMDc4IDQwNC41MjZDNTQwLjcxNiAzNzIuMjg1IDUzMC43NDcgMzM5LjQ0MyA1MDguNzQ5IDMxNy40MDJWMzE3LjM5OVpNNDcwLjg5OSAyNDQuNzc2QzQ4Ni44OTIgMjYwLjc3IDQ5My40ODggMjgyLjYwMSA0OTAuNjg3IDMwMy40MTJMNDE1LjU3NyAyNjAuMDQ2QzQxMi40MTEgMjU4LjIxOCA0MDguNTA5IDI1OC4yMTggNDA1LjM0NSAyNjAuMDQ2TDMxNy40MDEgMzEwLjgyVjI3Ny41MjZDMzE3LjQwMSAyNzUuMTkxIDMxOC42NTIgMjczLjAwNSAzMjAuNjc2IDI3MS44MzdMMzg3LjY0NCAyMzMuMTc0QzQxNC4xNzggMjE4LjM1MyA0NDguMzQ2IDIyMi4yMjMgNDcwLjkwMSAyNDQuNzc2SDQ3MC44OTlaTTM1Ny44MzcgMzExLjE0NEwzOTguMjc1IDMzNC40OTFWMzgxLjE4NUwzNTcuODM3IDQwNC41MzJMMzE3LjM5OCAzODEuMTg1VjMzNC40OTFMMzU3LjgzNyAzMTEuMTQ0Wk0yNjQuNzc2IDI2OS42OTNDMjY1LjIwNyAyMzkuMzA1IDI4NS42NDQgMjExLjY0OSAzMTYuNDUzIDIwMy4zOTNDMzM4LjMgMTk3LjU0IDM2MC41MDUgMjAyLjc0NCAzNzcuMTI3IDIxNS41NzNMMzAyLjAxNCAyNTguOTM3QzI5OC44NDggMjYwLjc2NCAyOTYuODk4IDI2NC4xNDQgMjk2Ljg5OCAyNjcuNzk4VjM2OS4zNDZMMjY4LjA2NSAzNTIuNjk5QzI2Ni4wNDMgMzUxLjUzMSAyNjQuNzc2IDM0OS4zNTMgMjY0Ljc3NiAzNDcuMDE3VjI2OS42OTFWMjY5LjY5M1pNMjAzLjM5MSAzMTYuNDU0QzIwOS4yNDQgMjk0LjYwOCAyMjQuODU0IDI3Ny45NzggMjQ0LjI3NiAyNjkuOTk5VjM1Ni43M0MyNDQuMjc2IDM2MC4zODQgMjQ2LjIyNiAzNjMuNzYzIDI0OS4zOTIgMzY1LjU5MUwzMzcuMzM3IDQxNi4zNjVMMzA4LjUwMyA0MzMuMDEzQzMwNi40ODEgNDM0LjE4MSAzMDMuOTYxIDQzNC4xODggMzAxLjkzOSA0MzMuMDJMMjM0Ljk3MSAzOTQuMzU3QzIwOC44NjggMzc4Ljc4OSAxOTUuMTM4IDM0Ny4yNjEgMjAzLjM5MSAzMTYuNDU0Wk0yNDQuNzc1IDQ3MC45QzIyOC43ODEgNDU0LjkwNiAyMjIuMTg2IDQzMy4wNzUgMjI0Ljk4NiA0MTIuMjY0TDMwMC4wOTYgNDU1LjYzQzMwMy4yNjMgNDU3LjQ1NyAzMDcuMTY0IDQ1Ny40NTcgMzEwLjMyOCA0NTUuNjNMMzk4LjI3MyA0MDQuODU2VjQzOC4xNDlDMzk4LjI3MyA0NDAuNDg1IDM5Ny4wMjIgNDQyLjY3MSAzOTQuOTk3IDQ0My44MzlMMzI4LjAyOSA0ODIuNTAyQzMwMS40OTUgNDk3LjMyMiAyNjcuMzI3IDQ5My40NTIgMjQ0Ljc3MiA0NzAuOUgyNDQuNzc1Wk00NTAuODk3IDQ0NS45ODJDNDUwLjQ2NiA0NzYuMzcxIDQzMC4wMjkgNTA0LjAyNyAzOTkuMjIgNTEyLjI4M0MzNzcuMzczIDUxOC4xMzYgMzU1LjE2OCA1MTIuOTMyIDMzOC41NDcgNTAwLjEwMkw0MTMuNjU5IDQ1Ni43MzhDNDE2LjgyNiA0NTQuOTExIDQxOC43NzUgNDUxLjUzMiA0MTguNzc1IDQ0Ny44NzdWMzQ2LjMyOUw0NDcuNjA5IDM2Mi45NzdDNDQ5LjYzMSAzNjQuMTQ1IDQ1MC44OTcgMzY2LjMyMyA0NTAuODk3IDM2OC42NTlWNDQ1Ljk4NVY0NDUuOTgyWk01MTIuMjgyIDM5OS4yMjFDNTA2LjQyOSA0MjEuMDY4IDQ5MC44MTkgNDM3LjY5NyA0NzEuMzk3IDQ0NS42NzZWMzU4Ljk0NkM0NzEuMzk3IDM1NS4yOTIgNDY5LjQ0OCAzNTEuOTEyIDQ2Ni4yODEgMzUwLjA4NUwzNzguMzM2IDI5OS4zMTFMNDA3LjE3IDI4Mi42NjNDNDA5LjE5MiAyODEuNDk1IDQxMS43MTIgMjgxLjQ4NyA0MTMuNzM0IDI4Mi42NTVMNDgwLjcwMiAzMjEuMzE4QzUwNi44MDUgMzM2Ljg4NyA1MjAuNTM2IDM2OC40MTUgNTEyLjI4MiAzOTkuMjIxWiIgZmlsbD0iIzVCNkNGRiIvPgo8L3N2Zz4%3D
[badge-swift]: https://img.shields.io/badge/Swift-6.4-F05138?style=flat&labelColor=FDE9E5&logo=swift&logoColor=F05138
[badge-release]: https://img.shields.io/github/v/release/bob-zebedy/CodexBar?style=flat&label=Release&labelColor=EFE7FB&color=8957E5&logo=github&logoColor=8957E5
[badge-downloads]: https://img.shields.io/github/downloads/bob-zebedy/CodexBar/total?style=flat&label=Downloads&labelColor=E4F3E7&color=2EA043&logo=data:image%2Fsvg%2Bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMkVBMDQzIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI%2BPHBhdGggZD0iTTEyIDN2MTJtLTUtNSA1IDUgNS01TTQgMTZ2NWgxNnYtNSIvPjwvc3ZnPg%3D%3D
[badge-license]: https://img.shields.io/github/license/bob-zebedy/CodexBar?style=flat&label=License&labelColor=F7EFCF&color=A67C00&logo=data:image%2Fsvg%2Bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjQTY3QzAwIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI%2BPHBhdGggZD0iTTEyIDN2MThtLTQgMGg4TTMgN2gxOE01IDdsLTMgOGg2TDUgN1ptMTQgMC0zIDhoNmwtMy04WiIvPjwvc3ZnPg%3D%3D

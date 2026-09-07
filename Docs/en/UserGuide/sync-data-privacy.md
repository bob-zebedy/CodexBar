# Data, Sync, and Privacy

[简体中文](../../UserGuide/sync-data-privacy.md) | English

## Cross-Device Sync

Enable `Cross-Device Sync` in `Settings > Advanced` to combine daily Hook statistics from Macs using the same iCloud account. CodexBar Hook must be enabled and an available iCloud account signed in.

The first sync uploads statistics within local retention; later changes sync automatically. Turning sync off keeps local data.

| State | Meaning |
| --- | --- |
| Sync Off | Sync or CodexBar Hook is disabled |
| Syncing | Data is being transferred |
| Synced | The latest sync cycle succeeded |
| Sync Failed | The network, iCloud account, or service is temporarily unavailable; CodexBar will retry |

The main panel footer and Settings show sync status. Settings also shows the last successful upload time.

## Uploaded Data

Synced data is stored in your private iCloud database. It includes dates, daily event and session statistics, project display names, model names, and identifiers used to distinguish devices and avoid duplicate counts.

The following are not synced:

- Raw Hook events, session and task identifiers, and full working-directory paths
- Prompts, Codex replies, and tool parameters or output
- Codex account data, quota, token usage, and banked resets
- App settings, proxy configuration, and passwords
- Logs, live task state, and Stalled Task Protection records

**Project display names are uploaded.** Disable cross-device sync if a project name contains information you do not want stored in iCloud.

## Local Data

| Data | Contents and retention |
| --- | --- |
| Hook records and daily statistics | Times, events, models, tools, projects, and task identifiers, retained for 210 days; session and turn details in daily statistics are retained for only the latest 3 days |
| Stalled Task Protection | Irreversible task identifiers and times, retained for up to 24 hours after the last progress |
| App settings | Stored on the current Mac, including proxy configuration; proxy passwords are stored in plain text |
| Interaction logs | The latest 500 Codex requests and responses, retained only during the current run |
| Background-service state | Used to restore sleep settings and clean up Automatic Reset wake schedules |

CodexBar reads local Codex task state and activity records without saving prompts, replies, or tool content, or copying Codex sign-in credentials.

Turning the proxy off retains its configuration and password. Saving with authentication disabled or choosing `Delete Configuration` removes the password.

## Rebuild Data

If statistics look incorrect, choose a date range in `Settings > Advanced > Rebuild Data` and confirm. You can select from the last 210 days; dates with local records are marked.

Rebuilding recalculates Hook statistics from retained local records and displays the result. With sync enabled, the result replaces this device’s cloud statistics for those dates while preserving other devices’ contributions. Account, quota, and token usage are unaffected.

## Network and Logs

| Network access | Purpose |
| --- | --- |
| Codex service | Read account, quota, and usage data; perform Automatic Reset |
| Update service | Check for and download CodexBar updates |
| iCloud | Transfer daily Hook statistics when sync is enabled |

The proxy applies only to CodexBar’s Codex service connection, not updates, iCloud, or other apps.

Interaction logs may contain account data and request or response content and are cleared when the app quits. Check for private information before sharing them.

Back to the [User Guide](README.md).

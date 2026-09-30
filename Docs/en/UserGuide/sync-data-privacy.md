# Data, Sync, and Privacy

[简体中文](../../UserGuide/sync-data-privacy.md) | English

## Cross-Device Sync

Enable `Cross-Device Sync` in `Settings > Advanced` to combine daily Hook statistics and rollout token usage from Macs using the same iCloud account. Advanced Mode must be enabled and an available iCloud account signed in.

The first sync uploads statistics within local retention; later changes sync automatically. Turning sync off keeps local data.

| State | Meaning |
| --- | --- |
| Sync Off | Sync or Advanced Mode is disabled |
| Syncing | Data is being transferred |
| Synced | The latest sync cycle succeeded |
| Sync Failed | The network, iCloud account, or service is temporarily unavailable; CodexBar will retry |

The main panel footer and Settings show sync status. Settings also shows the last successful upload time.

## Uploaded Data

Synced data is stored in your private iCloud database. It includes dates, daily event and session statistics, project display names, model names, and identifiers used to distinguish devices and avoid duplicate counts. Token history separately syncs hashed identifiers derived from thread and turn IDs, necessary timestamps, and cumulative token counters for cross-device deduplication and daily totals.

The following are not synced:

- Raw Hook events, session and task identifiers, and full working-directory paths
- Prompts, Codex replies, and tool parameters or output
- Codex account data, quota, app-server account usage, and banked resets
- App settings, proxy configuration, and passwords
- Logs, live task state, and Stalled Task Protection records

Project display names are uploaded. Disable cross-device sync if you do not want those names stored in iCloud.

## Local Data

| Data | Contents and retention |
| --- | --- |
| Hook records and daily statistics | Times, events, models, tools, projects, and task identifiers, retained for 210 days; session and turn details in daily statistics are retained for only the latest 3 days |
| Rollout token history | Hashed turn identities, timestamps, cumulative counts, and read cursors, retained for 210 days; root timestamps referenced by retained child turns are also kept |
| Stalled Task Protection | Irreversible task identifiers and times, retained for up to 24 hours after the last progress |
| App settings | Stored on the current Mac, including proxy configuration; proxy passwords are stored in plain text |
| Interaction logs | The latest 500 Codex requests and responses, retained only during the current run |
| Background-service state | Used to restore sleep settings and clean up Automatic Reset wake schedules |

CodexBar reads local Codex task state and activity records without saving prompts, replies, or tool content, or copying Codex sign-in credentials.

Turning the proxy off retains its configuration and password. Saving with authentication disabled or choosing `Delete Configuration` removes the password.

## Historical Token Replay

During historical-statistics refreshes, the app automatically reads local Codex rollouts to backfill retained turn usage. No manual rebuild is required. Each batch saves usage and read positions; reopening the app resumes from those positions. Once caught up, later refreshes read appended content. Replaced or truncated files are reread, with each thread and turn still counted once.

Large histories may take several refreshes to complete. Progress appears in the `workflow` system-log category. `Rollout 回放完成` means the files checked in that pass are caught up locally; the sync area reports cloud transfer status.

Daily usage follows the root turn’s start time in the viewing device’s local time zone. Missing rollouts or records without usage cannot supply the corresponding counts.

## Rebuild Data

If statistics look incorrect, choose a date range in `Settings > Advanced > Rebuild Data` and confirm. You can select from the last 210 days; dates with local Hook records or discovered token turns are marked; unmarked dates can also be selected.

Rebuilding recalculates activity statistics and token usage for the selected dates from local Hook events and rollouts. Tokens belong to the root turn's start date; each thread and turn contributes once. Dates without Hook events can still rebuild token usage from local rollouts.

The work runs in the background. You can keep using the main panel or close Settings. Token files are read in batches and committed only after the complete scan succeeds; cancellation and read errors do not publish partial results. Quitting the app stops the operation, and an unfinished token rebuild must be started again. The result dialog reports the number of days, Hook events, and token turns processed.

With sync enabled, rebuilding replaces this device's activity statistics and the token turns reread locally, preserving other turns. Rebuilding can lower token counts. If a turn is reread without usage records, its previous counts are cleared and that correction syncs to iCloud. Turns whose local rollouts are missing retain known statistics; missing files do not delete cloud records. Account details, quota, and app-server account usage are unaffected.

## Network and Logs

| Network access | Purpose |
| --- | --- |
| Codex service | Read account, quota, and usage data; perform Automatic Reset |
| Update service | Check for and download CodexBar updates |
| iCloud | After enabling synchronization, transmit daily Hook statistics and session data |

The proxy applies only to CodexBar’s Codex service connection, not updates, iCloud, or other apps.

Interaction logs may contain account data and request or response content and are cleared when the app quits. Check for private information before sharing them.

Back to the [User Guide](README.md).

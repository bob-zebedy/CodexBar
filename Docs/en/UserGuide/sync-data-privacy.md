# Data, Sync, and Privacy

[简体中文](../../UserGuide/sync-data-privacy.md) | English

## What Cross-Device Sync Includes

Cross-device sync merges daily Hook aggregations from multiple Macs. It does not sync account data, rate limits, token usage, reset credits, or Automatic Reset settings.

It requires:

- CodexBar Hook to be enabled
- An available iCloud account
- `Sync Across Devices` to be explicitly enabled

After you enable it, CodexBar uploads daily Hook aggregations within the local retention period, then uploads changed dates during later statistics maintenance.

Each device stores its contribution for a date separately. CodexBar merges contributions from different devices for display while avoiding double-counting the current device's local and cloud copies.

Sync uses the CloudKit private database in the `iCloud.app.zabrian.codexbar` container.

## Sync Status

The bottom of the main panel and the Settings page show these states:

| Status | Meaning |
| --- | --- |
| Sync is off | You have not enabled sync, or CodexBar Hook is off |
| Syncing | CodexBar is reading from or writing to CloudKit |
| Synced | The most recent sync completed successfully |
| Sync failed | The network, iCloud account, or service is temporarily unavailable |

Settings also shows the time of the most recent successful upload.

## Rebuilding Data

Use `Settings > Advanced > Rebuild Data` to regenerate daily aggregations for selected dates from local raw Hook events.

This is useful when:

- Older aggregations lack metrics added by a newer version
- Metrics for certain dates look incorrect
- Local raw events were replaced or truncated
- You need to replace the current device's cloud contribution for those dates with a local result

The rebuild process works as follows:

1. The date picker allows only dates within the raw Hook-event retention period
2. Dates with raw data are marked
3. After confirmation, CodexBar reparses the selected local JSONL files
4. Unparseable lines are skipped and included in the result count
5. If sync is enabled, the rebuilt dates replace this device's cloud contribution during a later sync

Rebuilding does not change your Codex account, rate limits, or token usage.

## Data Stored Locally

| Data | Contents | Location or lifetime |
| --- | --- | --- |
| Raw Hook events | Selected structured event fields | `~/Library/Application Support/CodexBar/HookEvents/events`, retained for 210 days |
| Daily Hook aggregations | Event counts, sessions and turns, project-name counts, and model counts | `~/Library/Application Support/CodexBar/HookEvents/daily.jsonl`, retained for 210 days |
| Hook maintenance state | File `offset`, `generation`, and pending dates | `~/Library/Application Support/CodexBar/HookEvents/maintenance.json` |
| Sync cache | CloudKit cache, cursors, and upload state | `~/Library/Application Support/CodexBar/HookEvents/Sync` |
| Stalled Task Protection | Hashed task identifiers and timestamps | `~/Library/Application Support/CodexBar/ActivityProtection/state.json`, up to 24 hours |
| CodexBarHelper ownership | Sleep-state ownership and recovery transactions | `/Library/Application Support/CodexBar/helper-state.json` |
| Automatic Reset wake schedule | CodexBar's fixed owner, `wake` type, and next time | macOS power management; removed after firing or cancellation |
| App preferences | Switches, thresholds, shortcut, Automatic Reset lead time, and notification deduplication state | macOS UserDefaults |
| app-server interaction log | The latest 500 requests and responses | Current app process memory only |

Daily aggregations retain lists of session and turn IDs only for the latest 3 days. Older dates are reduced to counts and the lists are removed.

The CodexBarHelper ownership file is owned by root and is used to recover sleep state after an unexpected CodexBar or CodexBarHelper exit.

The Automatic Reset wake schedule contains no account data, reset credits, `creditId`, or idempotency key. CodexBarHelper removes schedules left by the same build identity when it starts. The app also cancels schedules when tasks change, the feature is disabled, or the app exits normally.

Anonymous tasks do not participate in Stalled Task Protection, so they do not create hashed task identifiers or write to the protection-state file.

## Fields Uploaded to CloudKit

Each daily aggregation record may contain:

- A pseudonymous device identifier scoped to the iCloud account
- Date
- The local Hook data source `generation`
- Counts for each Hook event type
- Session and turn counts
- Project display-name counts
- Model-name counts
- Update time

The pseudonymous device identifier is derived from the device UUID and a random salt in the iCloud private database. The raw device UUID is not uploaded.

## Data Not Uploaded to CloudKit

- Raw Hook event files
- Session IDs, turn IDs, and agent IDs
- Full working-directory paths
- Prompts, Codex responses, tool arguments, or tool output
- Codex account, rate-limit, or token usage data
- Reset-credit details, Automatic Reset settings, or redemption state
- app-server interaction logs
- Stalled Task Protection records
- Codex authentication tokens

Project display names and model names are synced. Do not enable cross-device sync if a project name itself contains sensitive information.

## Local Data Access

CodexBar reads the following local data:

- Account, rate-limit, token usage, reset-credit details, and Codex configuration through the local app-server
- Raw Hook events to generate metrics and live tasks
- Lifecycle fields from local Codex rollout files to distinguish completion from termination and supplement progress timestamps

Rollout reading extracts only lifecycle, time, reasoning-effort, and similar fields. It does not display or store conversation text or tool content.

After you explicitly enable Automatic Reset, CodexBar uses reset credits that the same local app-server explicitly reports as near expiration. Raw `creditId` and idempotency keys are not written to disk or CloudKit. `UserDefaults` stores only the feature switch, lead time, notification switch, sound choice, and hashed notification-deduplication keys.

CodexBar does not copy or persist Codex authentication tokens.

## Network Activity

| Network access | Purpose | Trigger |
| --- | --- | --- |
| Sparkle update feed | Check for and install CodexBar updates | Automatic checking is enabled or you check manually |
| CloudKit private database | Sync daily Hook aggregations across devices | You enable cross-device sync |

Account data, rate limits, token usage, reset-credit details, and user-enabled Automatic Reset actions all use stdio communication with the local app-server. Automatic Reset does not add CloudKit requests. It sends CodexBarHelper only the time for a fixed system wake schedule, never account or reset-credit data.

## Log Privacy

System logs contain only operation results, state classifications, counts, and error stages.

They must not record account rate-limit values, token usage, project names, task content, session IDs, turn IDs, or OAuth tokens.

The in-app app-server interaction log may contain request and response data, but it exists only in current-process memory and is shown only when you explicitly open the Logs window.

Back to the [User Guide](README.md)

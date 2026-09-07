# CloudKit Sync

[简体中文](../../DeveloperGuide/sync.md) | English

## Sync Scope

CloudKit sync merges daily Hook metrics across Macs signed in to the same iCloud account.

It syncs aggregated results, not raw Hook events:

```text
Local raw Hook JSONL
  -> Local daily aggregation
  -> Current-device CloudKit record
  -> Download records from other devices
  -> Merge by date for display
```

Account data, rate limits, total tokens, Reset Credits, Automatic Reset settings and state, live tasks, and sleep-prevention state do not sync.

## Data Sources

Synced presentation combines three kinds of values:

| Data | Authoritative source | Offline behavior |
| --- | --- | --- |
| Current-device contributions for today and history | Local `daily.jsonl` merged with same-source cloud cache by completeness | Local aggregation continues; cloud cache is retained |
| Contributions from other devices | Last successfully fetched records in `cache.jsonl` | Preserves the last snapshot |
| Upload confirmation and incremental position | `state.json` and `cursor.data` | Continues or rebuilds next time |

Current-device local aggregates and cloud copies are merged by source and completeness, counting each source once. The cloud can supply missing local data or a same-source aggregate with more events.

The remote cache is a rebuildable projection, and the cursor is only an optimization. Any cursor failure can fall back to a full custom-zone read without requiring the user to delete local files.

## CloudKit Structure

[`WorkflowSyncService.swift`](../../../CodexBar/Services/Workflow/WorkflowSyncService.swift) uses the app's CloudKit private database:

| Item | Value |
| --- | --- |
| Container | `iCloud.app.zabrian.codexbar` |
| Custom zone | `CodexBarZone` |
| Metadata record type | `CodexBarSyncMetadata` |
| Daily aggregate record type | `CodexBarDailyAggregate` |

Private-database content belongs only to the current iCloud account and is never written to the public database.

The custom zone is more than a namespace. It provides zone change tokens and deletion events so devices can sync additions, modifications, and deletions incrementally instead of scanning the entire private database each cycle.

Zone confirmation and account salt are cached in the actor across cycles. Sync failure invalidates both for the next cycle to reread.

## Activation Conditions

Sync runs only when all conditions hold:

- The user enabled CloudKit sync
- `CodexHookSettings.isEnabled` is `true`; historical sync can consume aggregates already stored locally
- The current iCloud account is available
- The local aggregation service is available

Each sync checks all dates within local retention and uses hashes to select data that needs uploading, so initial sync and subsequent backfill use the same flow. Scheduling has a minimum 8-second cooldown to coalesce several local changes.

## Device Pseudonymization

Sync must distinguish device contributions without uploading a raw hardware identifier:

1. Create a random 32-byte account salt in the private database
2. Read the local `IOPlatformUUID`
3. Compute HMAC-SHA256 of the UUID with the account salt
4. Use the result as the cloud `deviceId`

The raw `IOPlatformUUID` is never uploaded. One device receives a stable pseudonym within one iCloud account and a different value in another account.

The private account salt gives the same device a different pseudonym in each iCloud account.

The salt lives in the same private custom zone. If several devices attempt initial creation, they converge on the existing record by reading it after a CloudKit conflict instead of keeping incompatible salts.

Local state records the most recently resolved `deviceId`. If it changes, sync clears the old cursor and remote cache while retaining pending replacement dates. A device-identity change means the cached account scope is untrusted and cannot continue incrementally.

## Daily Aggregate Fields

Each daily record contains:

- Schema
- Device ID pseudonym
- Date
- Source generation
- Hook event counts
- Session and turn counts
- Project counts
- Model counts
- Update time

It does not upload:

- Raw Hook JSONL
- Raw session or turn IDs
- Full working directories
- Prompt or response content
- Codex account or rate-limit data
- Tokens or files such as `auth.json`
- App request logs
- Stalled Task Protection state

For complete boundaries, see [Data and Privacy Boundaries](data-and-privacy.md).

## One Sync Cycle

```text
Read local sync state
  -> Create or confirm custom zone
  -> Read account salt and resolve device pseudonym
  -> Update local state for the device identity and schema
  -> Fetch remote changes into the cache and process replacement dates
  -> Upload changed dates for this device
  -> Fetch remote changes into the cache again
  -> Prune records outside retention
  -> Save state and publish merged results
```

The fetches before and after upload serve different purposes:

- Before uploading, it must know whether a same-device, same-day remote record exists so it can update, create a generation record, or skip
- Before replacement, it must perform a full fetch to discover old generations that an incremental cache may have missed
- It fetches again after upload to merge this cycle's writes and concurrent writes from other devices into the local cache
- It prunes expired records last so a pruning failure cannot block valid uploads in the same cycle

Every stage writes a `stage` field to logs, so an error identifies zone, device, fetch, upload, or prune instead of reporting only a generic CloudKit error:

- Upload batches contain at most 25 records
- Each upload cycle uses a 20-second budget to decide whether to start another batch
- A fetch page contains at most 200 changes
- SHA-256 hashes of local content skip unchanged records

The upload loop checks its 20-second budget before each batch. A batch already in progress continues waiting for its result. Once the budget is exhausted, remaining dates wait for a later sync.

Each date’s stable JSON is encoded and hashed once, reusing the result for pending-upload filtering and upload confirmation.

Uploads use `atomically: false`, allowing partial success remotely. If any error occurs in a batch, the caller removes local confirmation hashes for every date in that batch and rechecks it next cycle. Confirmations from earlier completed batches remain, and successful remote writes are not rolled back.

## Merge Semantics

One day may have records from several devices plus a newer local result that the current device has not uploaded yet.

Merge rules are:

- Add other-device contributions by field
- Use cloud contributions when the current device has no local aggregate
- Match sources by `sourceGeneration` or legacy-record content; use the cloud aggregate if it has more events, otherwise use local data
- If local source completeness is unconfirmed and no cloud record matches it, prefer existing cloud contributions
- Continue adding unmatched independent cloud sources

`confirmedDates` includes both successful uploads and dates skipped by the upload decision; it does not guarantee field-for-field equality between local and cloud content.

### Multiple Sources for One Device and Date

Legacy record names contain only `deviceId + date`. New source records may use `deviceId + date + sourceGeneration`.

A generation record identifies one raw source. Same-source local and cloud results replace one another, while clearly distinct sources may represent independent contributions created on the same day.

The read layer first finds the record matching local `sourceGeneration`. It uses whichever local or remote copy is more complete and continues adding other generations. A legacy record has no generation, but identical content can still be treated as the same source for compatibility.

The system does not infer “all old generations are invalid” from generation values. An explicit `replacementDates` transaction expresses that intent. This distinction preserves independent contributions during normal source rotation while allowing a user-requested full rebuild to remove historical copies.

Upload targets follow these rules:

| Remote state | Local source | Action |
| --- | --- | --- |
| No record for the date | Any | Create a legacy or generation record |
| Same-source record exists | Local is at least as complete as remote | Update that record |
| Same-source remote has more events | Local has a generation | Keep remote so a shorter stale scan cannot overwrite a more complete result |
| Other-source record exists | Local source is fresh | Create a record for the current generation |
| Other-source record exists | Local source is not fresh | Skip and wait for an authoritative rebuild |

`sourceIsFresh` describes the completeness of the raw source for one read, not its timestamp. A newer timestamp is not more authoritative while a file is replaced, truncated, or awaiting stable-boundary confirmation.

### Missing Count Fields

As the CloudKit record schema evolves, an old record may lack a new count field. `nil` means that device cannot provide the metric for that day; `0` means it explicitly observed zero occurrences.

CloudKit decoding and persisted models preserve optional counts. The current `WorkflowDailyMetrics` display projection converts missing individual event counts to `0`; session and turn counts first fall back to their start or stop event counts, then to `0`. Unavailable daily statistics and a missing individual count are different UI cases.

## Source Replacement and Rebuild

When the user requests a rescan:

1. Local aggregation rebuilds from raw JSONL
2. Affected dates are marked for replacement
3. Cloud records for those dates on the current device are overwritten or deleted and recreated
4. Other-device records remain unchanged

This design limits a rebuild to correcting the current device's contribution.

### Replacement Transaction

Rebuild and CloudKit synchronization may not finish in one process lifetime, so `replacementDates` persists in `state.json` instead of memory only.

For each replacement date, sync:

1. Rebuilds the remote cache in full
2. Enumerates all known legacy and generation record IDs for that date on the current device
3. Deletes those contributions, treating `unknownItem` as idempotent success
4. Removes the date from the local hash table to force reupload
5. Clears the replacement marker only after confirming the new content

While replacement is in progress, the snapshot filters the current device's cloud cache for that date and shows the latest local aggregation. Even if the app quits between deletion and reupload, the UI does not add the old cloud contribution to the new local contribution.

The full fetch before deletion is the crucial detail. An incremental cursor guarantees completeness only after its position; it cannot prove that an older app or manual deletion never caused the local cache to miss records. Full enumeration prevents ghost generations from remaining.

## Incremental Cursor and Local Cache

Sync state lives at:

```text
~/Library/Application Support/CodexBar/HookEvents/Sync/
```

| File | Purpose |
| --- | --- |
| `state.json` | Sync schema, local hashes, and replacement state |
| `cache.jsonl` | Cached daily aggregates from remote devices |
| `cursor.data` | CloudKit zone change token |

The current CloudKit record schema is `5`. The local sync-state schema is `4` and can read the previous schema `3`.

The three files have different recovery costs:

| File | Cost if lost | Recovery |
| --- | --- | --- |
| `state.json` | Loses upload hashes and replacement progress | Recompare and upload; replacement depends on markers that still exist |
| `cache.jsonl` | Temporarily loses other-device contributions | Full custom-zone fetch |
| `cursor.data` | Loses incremental position | Full fetch and new baseline |

`cursor.data` stores the opaque CloudKit token with secure coding; code does not inspect its structure. After a full fetch, sync must also create a new cursor baseline, or the next cycle may consume all recently fetched changes again from an empty cursor.

The local `3 -> 4` read path rebuilds the remote cache before committing new state. An unknown schema falls back to empty sync state because misinterpreting upload confirmations is more dangerous than resynchronizing.

Any change to record fields, identity, or schema is a compatibility decision. It must account for old apps still writing, new apps reading old fields, and whether downgrade can overwrite new records—not merely increment a constant.

## Sync Scheduler

Local maintenance and CloudKit sync share aggregation input but require different trigger rates. `WorkflowSyncScheduler` coalesces triggers into a single-threaded state machine.

Priority is:

```text
User-requested rebuild > Sync maintenance ready now > Local-only maintenance > Sync in cooldown
```

Important details include:

- Requests during the 8 seconds after a sync finishes merge into the next cycle so one Hook burst does not trigger many network operations
- Merged requests retain the earliest trigger because it is the real cause of the cycle
- A rebuild cancels completion for an earlier rebuild that has not started, preventing a caller from waiting forever
- Disabling sync during a wait clears pending sync but still allows required local maintenance
- `@Published` subscriptions run during `willSet`, when rereading the property returns the old value, so activation is calculated explicitly from the new callback argument

## Failure and Recovery Semantics

A sync failure does not roll back remote writes or clear the last usable cache. The next cycle continues through hashes, record IDs, and CloudKit APIs:

| Failure point | Preserved state | Next cycle |
| --- | --- | --- |
| Zone or account confirmation | Local aggregation and old cache | Reconfirm zone and salt |
| Incremental fetch | Old cache | Fall back to a full rebuild |
| Partial upload | Hashes from earlier completed batches and successful remote writes | Recheck all dates in the failed batch |
| Replacement deletion | Replacement marker | Re-enumerate and delete idempotently |
| Prune | In-retention data and upload results | Prune later |

A sync failure invalidates the actor’s cached zone confirmation and account salt. The next cycle resolves account and device identity again; a change from the device identity stored locally rebuilds the remote cache.

## Retention and Pruning

CloudKit records share the local Hook-history retention period of up to 210 days:

- Expired local raw data and daily aggregations are deleted
- Expired cloud records for the current device enter pruning
- Expired dates are removed from the local remote cache
- Prune failure does not affect in-retention display

## Error Classification

The sync layer distinguishes the following states for Settings and the main panel:

- Network unavailable
- iCloud account unavailable
- CloudKit service unavailable
- Server requested a later retry
- Local data or schema incompatible
- Sync succeeded or had no changes

Transient errors preserve the last usable remote cache. After account switching or identity invalidation, old-account cache must not be presented as current-account data.

## Manual Validation Matrix

- First enable uploads local aggregations within retention
- A second device merges contributions without duplicating the current device
- Disabling sync shows local metrics only
- When iCloud is signed out, the app shows a clear state and local metrics keep working
- After network loss, the app uses the last cache and completes incremental sync on recovery
- A local rebuild replaces only current-device records
- Local and remote cache older than 210 days is pruned
- Switching iCloud accounts does not show cache from the previous account

## Key Source Files

- [`WorkflowSyncService.swift`](../../../CodexBar/Services/Workflow/WorkflowSyncService.swift)
- [`WorkflowSyncScheduler.swift`](../../../CodexBar/Services/Workflow/WorkflowSyncScheduler.swift)
- [`WorkflowSyncSettings.swift`](../../../CodexBar/Services/Settings/WorkflowSyncSettings.swift)
- [`CodexWorkflowModels.swift`](../../../CodexBar/Models/CodexWorkflowModels.swift)
- [`CodexBar.entitlements`](../../../CodexBar/Resources/CodexBar.entitlements)

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

## Goals and Non-Goals

Sync does not replicate one Mac's database. It safely adds independent contributions from multiple devices for the same day.

Its priorities are:

1. Do not upload raw work content or identities directly tied to hardware
2. Local metrics must remain displayable without CloudKit
3. Rescans and file replacement must not create duplicate counts
4. Preserve the last explainable remote snapshot during network failure
5. Retries must be idempotent rather than depending on exactly-once requests

The sync protocol explicitly excludes:

- Live task state, which changes quickly and requires low-latency local evaluation
- Account rate limits, which belong to the Codex account rather than device work history
- Automatic Reset, whose multi-device convergence uses a deterministic idempotency key for the same `creditId`, not CloudKit locks or task records
- Sleep-prevention state, which is a system side effect on the current Mac
- Raw events, because cross-device statistics need only mergeable daily facts

Placing sync after aggregation also improves maintenance: the raw Hook format can evolve independently while CloudKit sees a stable daily projection.

## Sources of Authority

Synced presentation combines three kinds of values:

| Data | Authoritative source | Offline behavior |
| --- | --- | --- |
| Current-device contributions for today and history | Local `daily.jsonl` | Continues updating live |
| Contributions from other devices | Last successfully fetched records in `cache.jsonl` | Preserves the last snapshot |
| Upload confirmation and incremental position | `state.json` and `cursor.data` | Continues or rebuilds next time |

The current device is always local-first. Its CloudKit copy exists for other devices, not as truth for its own UI. This rule avoids a value appearing once locally and then doubling after a round trip to the cloud.

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

Confirmed zone state and the account salt are cached in the actor across sync cycles, avoiding two fixed network round trips each time. Any sync failure invalidates both because an iCloud account switch may first appear as a request failure. Reconfirming next cycle is safer than continuing with the wrong account context.

## Activation Conditions

Sync runs only when all conditions hold:

- The user enabled CloudKit sync
- Hook is enabled and validated
- The current iCloud account is available
- The local aggregation service is available

First enable marks a backfill and uploads dates within local retention that need synchronization. Scheduling has a minimum 8-second cooldown to coalesce several local changes.

## Device Pseudonymization

Sync must distinguish device contributions without uploading a raw hardware identifier:

1. Create a random 32-byte account salt in the private database
2. Read the local `IOPlatformUUID`
3. Compute HMAC-SHA256 of the UUID with the account salt
4. Use the result as the cloud `deviceId`

The raw `IOPlatformUUID` is never uploaded. One device receives a stable pseudonym within one iCloud account and a different value in another account.

HMAC is used instead of plain SHA-256. Hardware UUIDs have a fixed input format, so a simple hash would remain stable across accounts. A private per-account salt makes the same hardware unlinkable across accounts.

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
Confirm iCloud account
  -> Create or confirm custom zone
  -> Read account salt and resolve device pseudonym
  -> Read local sync state and cache
  -> Upload changed dates for this device
  -> Fetch remote changes
  -> Update the local CloudKit cache
  -> Prune records outside retention
  -> Publish merged results
```

The implementation intentionally performs a fetch before upload:

- Before uploading, it must know whether a same-device, same-day remote record exists so it can update, create a generation record, or skip
- Before replacement, it must perform a full fetch to discover old generations that an incremental cache may have missed
- It fetches again after upload to merge this cycle's writes and concurrent writes from other devices into the local cache
- It prunes expired records last so a pruning failure cannot block valid uploads in the same cycle

Every stage writes a `stage` field to logs, so an error identifies zone, device, fetch, upload, or prune instead of reporting only a generic CloudKit error:

- Upload batches contain at most 25 records
- One batch waits at most 20 seconds
- A fetch page contains at most 200 changes
- SHA-256 hashes of local content skip unchanged records

The 20 seconds is a budget for the complete upload cycle, not a per-record timeout. After the budget is reached, remaining dates stay unconfirmed for a later schedule. A historical backfill therefore does not occupy the actor and user-visible refresh path indefinitely.

Stable JSON for each date is encoded and hashed once, and the same result drives filtering and success confirmation. Re-encoding in different phases could let dictionary order or optional fields make change detection drift.

Uploads use `atomically: false`. On partial batch success, each CloudKit result is confirmed separately, while failed dates lose their local hash so they retry. The protocol relies on idempotent single-record identity rather than requiring all 25 records to succeed together.

## Merge Semantics

One day may have records from several devices plus a newer local result that the current device has not uploaded yet.

Merge rules are:

- Add contributions from other devices by field
- Replace the current device's same-source cloud contribution with its latest local aggregation
- Count a source generation at most once
- Add generations confirmed to represent independent sources
- Use a current-device cloud contribution only when local data is missing

Replacing the current device's cloud value with its local value prevents double counting when sync just uploaded but the local UI was already updated.

### Why One Device Can Have Multiple Records for One Day

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

### Why Missing Cannot Become Zero

As the CloudKit record schema evolves, an old record may lack a new count field. `nil` means that device cannot provide the metric for that day; `0` means it explicitly observed zero occurrences.

Preserving availability during merge lets the UI distinguish “all devices total zero” from “some historical sources do not support this metric.” Decoding missing as zero creates a false fact that cannot be repaired later.

## Source Replacement and Rebuild

When a raw Hook file is replaced or fully rebuilt, the aggregation layer changes its source generation. Sync must interpret this as replacement rather than adding old and new generations.

When the user requests a rescan:

1. Local aggregation rebuilds from raw JSONL
2. Affected dates are marked for replacement
3. Cloud records for those dates on the current device are overwritten or deleted and recreated
4. Other-device records remain unchanged

This design limits a rebuild to correcting the current device's contribution.

### Why Replacement Is a Persistent Transaction

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
| `state.json` | Sync schema, local hashes, backfill, and replacement state |
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

## Why the Scheduler Is Separate

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

The last detail is easy to break while “cleaning up” Combine lifecycle code. Rereading settings appears simpler but would decide synchronization using the old value.

## Failure and Recovery Semantics

A sync failure neither rolls back independently confirmed records nor clears the last usable cache. The next cycle converges through hashes, record IDs, and idempotent CloudKit APIs:

| Failure point | Preserved state | Next cycle |
| --- | --- | --- |
| Zone or account confirmation | Local aggregation and old cache | Reconfirm zone and salt |
| Incremental fetch | Old cache | Fall back to a full rebuild |
| Partial upload | Hashes for successful dates | Retry only unconfirmed dates |
| Replacement deletion | Replacement marker | Re-enumerate and delete idempotently |
| Prune | In-retention data and upload results | Prune later |

Account-level caches are invalidated after failure, but the disk cache is not immediately published as fact for a new account. The sync snapshot returns only after availability and device identity are confirmed again.

## Checklist for Sync Protocol Changes

1. Define field semantics first, especially whether missing, zero, and empty collections differ
2. Decide whether record identity remains idempotent
3. Evaluate concurrent writes by old and new app versions
4. Define upgrade or rebuild paths for local state, cache, and cursor
5. Confirm replacement can delete every old generation
6. Recheck privacy boundaries and explicit opt-in
7. Validate eventual convergence with two devices and an interrupted cycle

## Retention and Pruning

CloudKit records share the local Hook-history retention period of up to 210 days:

- Expired local raw data and daily aggregations are deleted
- Expired cloud records for the current device enter pruning
- Expired dates are removed from the local remote cache
- Prune failure does not affect in-retention display

## Error Classification

The sync layer distinguishes these states for Settings and notifications:

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

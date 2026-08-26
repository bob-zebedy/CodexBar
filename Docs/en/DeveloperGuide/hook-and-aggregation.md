# Hook Capture and Historical Aggregation

[简体中文](../../DeveloperGuide/hook-and-aggregation.md) | English

## Design Motivation

The Hook flow serves two similar-looking goals with opposite requirements:

- Record facts as quickly as possible on Codex's critical path
- Maintain reliable long-term statistics in the main app

Capture must be small, bounded, and allowed to fail. Aggregation can run asynchronously and must detect file changes, repair damaged caches, and support full rebuilds.

The implementation therefore uses append-only raw JSONL plus rebuildable daily aggregations instead of making Hook subprocesses update a complex statistics object directly.

## Flow Responsibilities

The Hook flow turns Codex lifecycle events into rebuildable local history:

```text
Codex Hook
  -> CodexBar --hook-event
  -> Raw JSONL
  -> Incremental WorkflowService aggregation
  -> daily.jsonl
  -> Activity UI and CloudKit sync
```

Raw events are the fact source; daily aggregation is a rebuildable cache. A change to the aggregation algorithm or field semantics requires a full rebuild from raw events within retention.

### Why Hook Subprocesses Do Not Aggregate Directly

Reading and rewriting `daily.jsonl` appears to remove a file layer but creates four problems:

- Every Hook invocation decodes and rewrites history, so latency grows with event volume
- The subprocess runs within Codex's timeout budget, turning aggregation failure into task delay
- Algorithm upgrades lack raw facts for recalculation
- Concurrent Codex sessions can lose updates between read and rewrite

The current design reduces the critical path to one append. The main app aggregates in batches on its own schedule, and a failure leaves raw events for a later repair.

### Raw Facts and Cache Responsibilities

| File | Authoritative? | Recovery |
| --- | --- | --- |
| `events/YYYY-MM-DD.jsonl` | Yes | Append only; prune after retention |
| `daily.jsonl` | No | Fully rebuild from raw events |
| `maintenance.json` | No | Reconcile when missing or after schema change |
| `stats.lock` | Stores no business data | Coordinates cross-process transactions only |

## Installation and Validation

[`CodexHookSettings.swift`](../../../CodexBar/Services/Settings/CodexHookSettings.swift) reads and changes Hook configuration through app-server.

Enabling requires:

- A resolvable current executable path
- Actual app-server version `0.145.0` or later
- Available `features.hooks`
- A trusted source returned by `hooks/list`
- A complete required event set

The target file is `$CODEX_HOME/hooks.json`, or `~/.codex/hooks.json` when `CODEX_HOME` is unset.

Installation adds the CodexBar handler as a separate command within the existing configuration. It never overwrites the entire file from a template:

- Preserve existing user fields
- Preserve handlers from other applications
- Update only handlers matching the current executable and `--hook-event`
- On disable, remove only an exact CodexBar handler match
- Preserve unrecognized configuration unchanged

`isEnabled` means only that a handler exists; `isVerified` means the most recent app-server validation passed. The UI treats Hook as a working source only when `isOperable` is true.

### Why Installation and Validation Are Separate

A command in `hooks.json` proves only that configuration exists on disk, not that Codex will run it.

Execution may still be blocked when:

- The current app-server version is too old
- `features.hooks` is globally disabled
- The handler event set is incomplete
- app-server resolves another source file
- The handler is untrusted or modified

`isEnabled` is therefore a local configuration fact, while `isVerified` is Codex's most recent explicit conclusion for the current source. Sleep prevention and task notifications depend only on their combined `isOperable` state.

A transient RPC failure means validation could not run this cycle, not that the handler became invalid. CodexBar preserves the last explicit conclusion while exposing the operation error for diagnosis.

### Enable Transaction Order

```text
Confirm running app-server >= 0.145.0
  -> Confirm features.hooks is not globally disabled
  -> Read existing hooks.json
  -> Remove only old CodexBar handlers for this executable
  -> Append a separate group for every event
  -> Atomically write hooks.json
  -> Use hooks/list to read app-server's parsed result
  -> Trust only entries matching command + sourcePath + event
  -> Run hooks/list again for full validation
```

Preflight checks happen before file changes. A failed version or global-feature check leaves the user's file byte-for-byte unchanged.

Trust matching requires both command and `sourcePath`. Command-only matching might trust the same command from another configuration; source-only matching might select the user's own handler.

### Why Disable Queries Trust Keys First

An app-server Hook key comes from the handler it currently parsed. Removing the command from `hooks.json` first would make a later `hooks/list` unable to recover the corresponding key.

Disable therefore saves keys for exact matches, removes handlers, then removes those keys from `hooks.state`. Cleanup reads and replaces the complete state so trust entries belonging to users and other tools survive.

A failed trust cleanup does not reinstall the handler. The UI reports that Hook is off but cleanup is incomplete because the user's intent to stop capture succeeded.

### Why Every Event Uses a Separate Group

CodexBar does not insert commands into an existing user group. Separate groups make uninstall remove only its own handler without interpreting the composition of user matchers and other handlers.

Removal skips structurally malformed sibling entries instead of failing the entire switch. CodexBar recognizes its own command; it is not a global validator for the user's Hook configuration.

### Generations for Asynchronous Settings Operations

The user may toggle Hook quickly, and app activation also triggers validation. `CodexHookSettings` increments `updateGeneration` and cancels the old task for every operation.

After every file write or RPC `await`, it checks the generation again. Even if an old operation cannot truly be canceled, it cannot overwrite the latest switch state or error.

## Supported Events

CodexBar subscribes to:

| Event | Aggregation or live use |
| --- | --- |
| `SessionStart` | Establish session lifecycle |
| `SessionEnd` | End session |
| `UserPromptSubmit` | Establish turn and task start |
| `PreToolUse` | Record tool-call start |
| `PostToolUse` | Record tool-call end |
| `PermissionRequest` | Detect user approval waiting |
| `PreCompact` | Record context-compaction start |
| `PostCompact` | Record context-compaction end |
| `Stop` | Create a task-completion candidate |
| `SubagentStart` | Record subagent start |
| `SubagentStop` | Record subagent end |

### Event Fields Serve Different Uses

Historical counts need event name, date, project, model, and identity sets. Live state additionally needs turn, reviewer, effort, tool, agent relationships, and normalized origin.

One minimal raw record lets the recorder write once while both consumers select their fields. A new field still requires a demonstrated consumer; its presence in the Hook payload does not justify persisting everything.

When `transcript_path` is available, the recorder performs a bounded read of the rollout's first line to classify origin. Reviewer or effort for `PermissionRequest` and `UserPromptSubmit` may be absent from the Hook payload, so only those two events also read the rollout tail for that turn.

## Hook Subprocess

[`WorkflowHookEventRecorder.swift`](../../../CodexBar/Services/Workflow/WorkflowHookEventRecorder.swift) checks for `--hook-event` at the earliest startup point.

When matched, it only:

1. Reads event JSON from stdin
2. Extracts the minimal fields needed for metrics and state machines
3. Acquires the file lock
4. Appends one complete JSONL line
5. Marks maintenance state in the same lock transaction
6. Exits immediately

Timeout depends on event:

| Event | Timeout |
| --- | --- |
| `SessionEnd` | 3 seconds |
| Other events | 5 seconds |

The lock-wait budget is the handler timeout minus 2 seconds. Lock acquisition starts with 1 ms exponential backoff capped at 20 ms per wait.

Invalid stdin, lock timeout, or write failure is swallowed. A statistics failure in the Hook subprocess must never block Codex.

### Why It Still Returns Success

Hook metrics are supplemental to CodexBar and not required for Codex to finish a task. Returning a nonzero exit code after a parsing or disk error could turn one statistics failure into a user's Codex failure.

After explicitly entering `--hook-event` mode, the process therefore reports handled and exits successfully regardless of input validity. Failure loses one statistic but never escalates into an upstream task failure.

### Why Event and Maintenance State Commit in One Lock Transaction

One capture performs under the same `stats.lock`:

```text
Check current file identity
  -> Start a new source generation if required
  -> Append one complete JSONL line
  -> Mark the date pending
  -> Atomically save maintenance.json
```

If append and pending were separate lock transactions, the app could finish maintenance between them and consider the date caught up. The recorder might then append the event but fail before marking pending, leaving the new line invisible until a later full-directory reconciliation.

The joint commit keeps “the file grew” consistent with “maintenance knows it must read.”

### Why Lock Waiting Uses Only Part of the Timeout

Codex waits at most 3 seconds for `SessionEnd` and 5 seconds for other events. The recorder caps lock waiting at total budget minus 2 seconds.

The reserve covers encoding, append, saving maintenance state, and process exit. Spending the whole budget on the lock could let Codex terminate the process mid-write, leaving a partial line or unmatched maintenance state.

Waiting backs off exponentially from 1 ms to 20 ms. Normal app critical sections are short, so a small start resumes quickly after release, while the cap avoids busy looping under contention.

### Why the Lock File Uses One `open(O_CREAT)`

Code must not check for absence, create, then reopen. Two processes could create different inodes; after one replaces the directory entry, both would lock separate files and each believe it has exclusivity.

One `open` makes creation and opening an atomic entry point so all participants use `flock` on the same inode at that path.

## Captured Fields

Raw records retain only information required for statistics and live state:

- Timestamp and event name
- Working directory
- Tool name
- Model and reasoning effort
- Permission and approval reviewer
- Session and turn IDs
- Agent and parent relationships
- Normalized `origin`

For `UserPromptSubmit` and `PermissionRequest`, input may omit reviewer or effort. When needed, the recorder looks for a matching `turn_context` near the end of the rollout transcript.

The lookup:

- Reads at most 512 KB once
- Extracts only structural fields such as reviewer and effort
- Never writes prompt or response content to Hook statistics

### Origin Normalization

`WorkflowHookEvent.origin` is a finite CodexBar-owned enum, not a copy of the rollout's raw `source`:

| `origin` | Classification |
| --- | --- |
| `main` | `source` is a known top-level string source `cli`, `vscode`, `exec`, or `mcp`, or a valid object source `{ "custom": "..." }` |
| `autoReview` | `source.subagent.other` exactly equals `guardian` |
| `auxiliary` | `source` explicitly represents another subagent, including `review`, `thread_spawn`, and Memories-related sources |
| `unknown` | The field is missing, malformed, unreadable, or an unknown top-level source |

Origin reading starts at byte zero in 32 KiB chunks, stops at the first newline, and has a total budget of 256 KiB. If the first complete record is not `session_meta`, exceeds the budget, or any file or decoding operation fails, classification falls back to `unknown` without waiting or retrying and without failing the Hook.

Raw JSONL stores only this enum. It never stores `transcript_path`, raw `source`, arbitrary `other` strings, or transcript content, and none of those values enter system logs.

Old events without `origin` and future enum values unknown to the current app both decode as `unknown`. CodexBar neither backfills historical records nor infers origin from `model == "codex-auto-review"`.

`origin` changes only live-activity filtering, not historical aggregation input. Auto-review events continue to contribute to existing session, turn, model, tool, project, and event counts, so this change does not increment the aggregation schema or alter the CloudKit projection.

### Input Normalization

Hook payload versions may represent identifiers and time as different JSON types. `WorkflowHookPayload` centralizes permissive normalization:

- Trim strings and turn empty strings into missing values
- Convert numeric identifiers to strings
- Accept ISO-8601, local timestamps, Unix seconds, and Unix milliseconds
- Fall back to recorder current time when time is missing
- Fall back to the subprocess current directory when cwd is missing

Permissiveness exists only at the external-input boundary. After conversion to `WorkflowHookEvent`, downstream aggregation and monitoring use uniform types instead of guessing protocol differences again.

### Rollout Tail-Lookup Boundary

The lookup reads only the last 512 KB of the transcript, discards a potentially truncated first line, then searches backward for the matching turn's `turn_context`.

Backward search finds the latest context for a turn nearest the file tail. The read limit protects Hook timeout; a miss leaves the field absent instead of expanding into an unbounded scan.

## Local Files

The default data root is:

```text
~/Library/Application Support/CodexBar/HookEvents/
```

Directory structure:

```text
HookEvents/
  events/
    YYYY-MM-DD.jsonl
  daily.jsonl
  maintenance.json
  stats.lock
  Sync/
    state.json
    cache.jsonl
    cursor.data
```

| File | Purpose |
| --- | --- |
| `events/YYYY-MM-DD.jsonl` | Store raw Hook events by day |
| `daily.jsonl` | Store aggregations by date and source generation |
| `maintenance.json` | Store pending maintenance and schema state |
| `stats.lock` | Coordinate Hook subprocesses and app maintenance |
| `Sync/*` | CloudKit sync cursor and cache |

Raw events and daily aggregations are retained for up to 210 days. Detailed session and turn ID lists remain only for 3 days; older dates compact them to counts to reduce file size and identity retention.

### Why JSONL

JSONL matches this write pattern:

- The recorder appends one complete record to the tail
- One damaged line can be isolated instead of failing the whole file
- Files can rotate by day and be pruned by retention
- Individual structures remain inspectable during manual diagnosis
- Aggregation and remote caches can use the same line-level recovery strategy

A regular JSON array would rewrite tail structure on every append. A database would add schema, locking, and deployment complexity, while current queries only scan chronologically by date and gain too little from it.

### A Complete Line Is the Commit Unit

The reader advances only to the offset of the final newline. If a partial line is being written at the tail, the current cycle keeps its old offset and processes the line after a future cycle sees it complete.

`JSONLines.decodeWithFailures` decodes per line. One malformed line increments the corrupt count without discarding valid events from the same read block.

### Why Identity Details Remain for Only 3 Days

Session and turn IDs support recent exact deduplication, while long-term presentation needs counts only.

Compacting identifiers to counts after 3 days reduces file size and identity retention. The aggregation model must record whether a field is retained or compacted; otherwise it cannot know whether later events can still use IDs for exact deduplication.

Raw events remain for 210 days and support a full algorithm rebuild. CloudKit never uploads these raw identities.

## Incremental Reading and Source Generations

For each raw file, the aggregator records inode, size, offset, and source generation:

- Normal appends resume at the previous offset
- An inode change means file replacement
- Size below offset means truncation
- Replacement or truncation creates a new source generation

Source generation distinguishes raw sources for the same day. Same-source results replace one another; clearly independent generations may add together. A user-requested full rebuild tells sync that all old generations are invalid through a replacement marker.

### `pending` Versus `dirty`

`maintenance.json` tracks two work states for a date:

| State | Used when | Next step |
| --- | --- | --- |
| `pending` | Confirmed normal append to the same source | Aggregate incrementally from the old offset |
| `dirty` | Source change, schema change, missing cache, or previous failure | Fully rebuild from the file start |

`dirty` takes priority. If a date appears in both sets, only a rebuild task is created, avoiding an append to the old aggregate followed by complete replacement.

Explicit states are safer than guessing from `offset == 0`. A new empty file, truncated file, and requested rebuild can all have offset 0 but differ in source generation and sync semantics.

### Determining Whether a File Is the Same Source

Maintenance combines four kinds of evidence:

- Whether inode identity changed
- Whether current size is below consumed offset
- Whether current size equals the previous recorded size
- Whether the boundary hash over the 4 KB before offset still matches

Inode and size detect replacement and truncation; the boundary hash detects an in-place rewrite at the same length.

### Why Boundary Hash Also Uses mtime

Rehashing every file across 210 days each cycle would hold `stats.lock` for too long and directly increase Hook recorder wait probability.

Maintenance records nanosecond mtime from the last boundary validation. If inode, size, and mtime are unchanged, it skips hashing. It recomputes the 4 KB before offset only after file change.

A normal append changes bytes only after offset, so the boundary continues to match and maintenance can aggregate incrementally. A changed boundary creates a new generation and marks it dirty.

### Why Build and Commit Are Separate

The aggregator cannot hold `stats.lock` while reading a full day because Hook subprocesses could time out repeatedly.

The actual flow is:

```text
Prepare under lock
  -> Fix sourceGeneration, inode, startOffset, and read upper bound
Build without lock
  -> Read in chunks and produce a candidate aggregate
Validate under lock
  -> Generation still matches
  -> Inode still matches
  -> Candidate upper bound still exists
  -> Boundary hash still matches
Commit daily.jsonl
Validate again under lock and advance maintenance offset
```

The recorder may continue appending during the read. As long as bytes before the candidate upper bound remain unchanged, the result is valid and the new tail remains pending for the next cycle.

If the source is replaced during build, the candidate does not commit; maintenance starts a new generation and waits for rebuild.

## Aggregation Rules

Daily results include:

- Total Hook events and per-event counts
- Session and turn counts
- Tool-call count
- Compaction count
- Subagent count
- Project distribution
- Model distribution

Only one side of a paired event may persist. Counts therefore use rules that avoid duplicates while tolerating missing data:

- Tool calls use `max(PreToolUse, PostToolUse)`
- Compactions use `max(PreCompact, PostCompact)`
- Subagents use `max(SubagentStart, SubagentStop)`

A missing field differs from numeric `0`:

- Missing means the historical source cannot provide this metric for the date
- `0` means the source is available and explicitly observed none

Decoding and UI must preserve the distinction.

### Why Paired Events Use `max`

`PreToolUse` and `PostToolUse` describe the two sides of one tool call. Since the recorder may fail, either side may be absent:

- Adding counts one complete call twice
- Pre-only misses a failed pre write followed by a successful post
- Post-only misses a tool that started before process interruption
- `max(pre, post)` is the least duplicate-prone estimate without stable call IDs

Compaction and subagent pairs follow the same rule.

If a future Hook protocol provides stable operation IDs, the algorithm can move to set deduplication, but that changes aggregation semantics and requires a schema increment and full rebuild.

### Carrying Availability Through Old Data

Older aggregations may not have a newer Hook count. Rebuild cannot assume that an old source captured an event merely because current code understands it.

`WorkflowHookCountAvailability` records source availability for each count. Rebuild inherits an existing date's availability for old fields, while a fresh source can declare all current fields available.

The UI can therefore distinguish:

- Explicitly zero occurrences
- Historical capture for the date did not provide the metric

## Schema Evolution and Rebuild

The current aggregation schema is `5`, managed by `WorkflowMaintenanceState.currentAggregationSchema`.

Increment the schema for:

- Changes to the raw-event-to-aggregate algorithm
- Added or removed output fields
- Changed field meanings
- Changed deduplication rules
- Changed source-generation merge semantics

After upgrade, CodexBar fully rebuilds from raw JSONL within the 210-day retention period instead of performing field-level historical migration. Every aggregation under one schema is then generated by the same current algorithm.

User-requested rebuilding uses the same full-recalculation path and marks dates for replacement in sync.

### Aggregation Schema Versus Source Generation

| Identity | Describes | Changes when |
| --- | --- | --- |
| Aggregation schema | How current code calculates an aggregate from raw events | Algorithm, fields, or semantics change |
| Source generation | Which generation of raw file a particular day belongs to | Replacement, truncation, requested rebuild, or boundary rewrite |

A schema change usually marks all event dates in retention dirty. A source-generation change affects only a specific date.

Neither can be replaced with the app version. One app version may not change aggregation, while development builds may iterate schemas without changing a version number.

### Why There Is No Field-Level Migration

`daily.jsonl` is a derived cache and raw JSONL remains available during retention. Migrating every historical field would retain both old and new algorithms and make mixed semantics more likely.

A full rebuild has a bounded one-time cost and guarantees:

- Every date under one schema uses the same code
- Removed or redefined fields leave no residual values
- Damaged aggregate lines are repaired at the same time
- CloudKit replacement follows source generation consistently

Only when the raw source itself lacks a field does missing preserve the historical capability difference.

### Commit Semantics for a User Rebuild

A batch rebuild handles dates independently. Failure on one day does not block days that succeeded; failed dates become dirty for normal maintenance to retry.

Both successful and failed dates register CloudKit replacement first. A failed date already entered a new generation, and its later successful automatic rebuild will use a new record identity. Without an early marker, the old generation might remain in the cloud and be added to the new value.

The operation fails as a whole only if every date fails. Partial success returns a detailed summary of successful dates, damaged lines, and pending replacement state.

## Maintenance Scheduling

[`WorkflowService.swift`](../../../CodexBar/Services/Workflow/WorkflowService.swift) is an actor that serializes reading, aggregation, pruning, and rebuild.

Maintenance coordinates with the rate-limit refresh cycle but has no data dependency on it. The Workflow view model refreshes UI no more often than every 5 seconds to avoid rerendering for frequent file changes.

### Why No-Op Maintenance Does Not Emit Normal Logs

Maintenance normally follows the 60-second refresh. An idle machine would otherwise emit more than a thousand no-change checks per day.

`WorkflowService` accumulates consecutive idle cycles and logs one summary only after a write, skip, failure, or cleanup, including the preceding idle count. Logs can prove that maintenance runs without burying real failures.

### How the Scheduler Coalesces Requests

`WorkflowSyncScheduler` serializes three request classes:

1. User rebuild, highest priority
2. Maintenance with sync
3. Local-only maintenance

After sync completes, an 8-second cooldown combines incoming requests and retains the earliest trigger as the real cause.

Opening the UI reads the current local snapshot and does not bypass the scheduler to start an unconditional CloudKit request.

## Steps to Add a Hook Event or Metric

1. Register the protocol name, configuration name, and handler timeout in `CodexHookEvent`
2. Ensure the recorder persists only minimal fields required for calculation
3. Update Hook-installation completeness validation
4. Define count and deduplication semantics in the accumulator
5. Update aggregate Codable and JSONL encoding while preserving missing semantics for old fields
6. Increment `WorkflowMaintenanceState.currentAggregationSchema`
7. Update CloudKit record schema and upload/download mapping
8. Decide coexistence with old apps and new records before changing compatibility formats
9. Update UI and privacy boundaries
10. Manually test normal append, a missing side of a pair, file replacement, and full rebuild

## Suggested Failure-Scenario Tests

- Concurrent Codex sessions write complete lines without overwriting one another
- While the main app holds the lock, the Hook recorder succeeds within budget or abandons safely
- Non-JSON stdin or missing event name still exits successfully and immediately
- A partial tail line does not advance offset and is read after completion
- One malformed JSONL line increments only the corrupt count
- Inode change, file shrink, and boundary rewrite each create a new generation
- Appends during build commit only to the fixed upper bound and leave the tail pending
- A schema change rebuilds every in-retention date with the current algorithm
- Missing fields on old dates remain unavailable instead of becoming `0`
- Disabling CodexBar Hook preserves user handlers and trust entries
- During rapid Hook toggling, old RPC results cannot overwrite the final operation

## Failure Boundaries

- One malformed JSONL line must not make the entire retention period unreadable
- A changed file source must not continue from the old offset
- A failed rebuild preserves the last usable aggregate
- Interrupted maintenance must not commit a partial result as a complete date
- When Hook is unavailable, the UI shows source unavailability rather than clearing to `0`
- A failed configuration write must not damage existing handlers

## Key Source Files

- [`CodexHookSettings.swift`](../../../CodexBar/Services/Settings/CodexHookSettings.swift)
- [`WorkflowHookEventRecorder.swift`](../../../CodexBar/Services/Workflow/WorkflowHookEventRecorder.swift)
- [`CodexHookEvent.swift`](../../../CodexBar/Models/CodexHookEvent.swift)
- [`JSONLines.swift`](../../../CodexBar/Services/Workflow/JSONLines.swift)
- [`WorkflowService.swift`](../../../CodexBar/Services/Workflow/WorkflowService.swift)
- [`CodexWorkflowModels.swift`](../../../CodexBar/Models/CodexWorkflowModels.swift)

# Hook Capture and Historical Aggregation

[简体中文](../../DeveloperGuide/hook-and-aggregation.md) | English

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

## Installation and Validation

[`CodexHookSettings.swift`](../../../CodexBar/Services/Settings/CodexHookSettings.swift) reads and writes local `hooks.json` directly, reads or updates related configuration through app-server, and calls `hooks/list` after writing to validate installation.

The enable flow checks the following conditions, validating source, trust, and event completeness after writing:

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

`isEnabled` tracks enabled state for the current process, initially restored from an existing CodexBar handler. `isVerified` defaults to `true`, then retains the latest explicit validation result. Live tasks and related features use their conjunction, `isOperable`; historical aggregation and sync use `isEnabled` to consume stored data.

### Validation State

A handler in `hooks.json` does not prove Codex will execute it. `isOperable` combines the enabled state with the last explicit validation result. Temporary RPC failures preserve the previous result and expose the operation error; unsupported versions, disabled global hooks, incorrect sources, trust failures, or incomplete events fail validation.

### Reconciliation of an Enabled Hook

An enabled Hook is reconciled at app launch, when Settings refreshes, when the main panel opens, and after each quota refresh. Automatic refresh waits 60 seconds after the previous round completes:

- Only a confirmed running app-server version below the current Hook minimum triggers the normal disable flow, which removes CodexBar handlers and their matching trust entries
- An unknown version or transient RPC failure preserves the user's configuration
- Configuration lost during the current process does not turn off the switch; CodexBar marks it damaged and starts repair
- A supported version traverses `CodexHookEvent.allCases`, rebuilds a separate group for every missing or noncanonical event, then reuses trust and completeness validation
- Missing trust entries or changed hashes are repaired only for entries whose command, `sourcePath`, and event belong to the current CodexBar
- A complete required event set leaves `hooks.json` unchanged

Reconciliation compares the required event set with the configuration and restores missing handlers. If no recognizable CodexBar handler exists at startup, Hook remains off.

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

Trust matching requires both command and `sourcePath`. Command-only matching might trust the same command from another configuration; source-only matching might select the user's own handler.

### Disable and Trust Cleanup

An app-server Hook key comes from the handler it currently parsed. Removing the command from `hooks.json` first would make a later `hooks/list` unable to recover the corresponding key.

Disable therefore saves keys for exact matches, removes handlers, then removes those keys from `hooks.state`. Cleanup reads and replaces the complete state so trust entries belonging to users and other tools survive.

A failed trust cleanup does not reinstall the handler. The UI reports that Hook is off but cleanup is incomplete because the user's intent to stop capture succeeded.

### Event Groups

CodexBar does not insert commands into an existing user group. Separate groups make uninstall remove only its own handler without interpreting the composition of user matchers and other handlers.

Removal skips malformed sibling entries and processes only precisely identified CodexBar commands.

### Generations for Asynchronous Settings Operations

When the user toggles Hook or validation is triggered, `CodexHookSettings` starts the operation through `updateCoordinator`. Its `RefreshTaskCoordinator` advances the generation and cancels the previous task.

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

When `transcript_path` is available, the recorder performs a bounded read of the rollout's first line to classify origin. If the rollout origin cannot be determined, only an exact `codex-auto-review` model match serves as the Auto-review fallback. Reviewer or effort for `PermissionRequest` and `UserPromptSubmit` may be absent from the Hook payload, so only those two events also read the rollout tail for that turn.

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

### Failure Exit

In `--hook-event` mode, invalid input, lock timeouts, and write errors all exit successfully so capture failures do not block Codex.

### Locked Event and Maintenance Transaction

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

### Lock File Creation

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
- Agent ID
- Normalized `origin`

For `UserPromptSubmit` and `PermissionRequest`, input may omit reviewer or effort. When needed, the recorder looks for a matching `turn_context` near the end of the rollout transcript.

The lookup:

- Reads at most 512 KB once
- Extracts only structural fields such as reviewer and effort
- Never writes prompt or response content to Hook statistics

### Origin Normalization

`WorkflowHookEvent.origin` is a finite CodexBar-owned enum, not a copy of the rollout's raw `source`. Both the initializer and decoder apply the same origin-resolution rule at the event input boundary, so downstream consumers read only the normalized `origin`:

| Effective origin | Classification |
| --- | --- |
| `main` | `source` is a known top-level string source `cli`, `vscode`, `exec`, or `mcp`, or a valid object source `{ "custom": "..." }` |
| `autoReview` | `source.subagent.other` exactly equals `guardian`, or the rollout origin is `unknown` and the model exactly equals `codex-auto-review` |
| `auxiliary` | `source` explicitly represents another subagent, including `review`, `thread_spawn`, and Memories-related sources |
| `unknown` | The field is missing, malformed, unreadable, or an unknown top-level source, and the model does not satisfy the Auto-review fallback |

Origin reading starts at byte zero in 32 KiB chunks, stops at the first newline, and has a total budget of 256 KiB. If the first complete record is not `session_meta`, exceeds the budget, or any file or decoding operation fails, the rollout origin falls back to `unknown` without waiting or retrying and without failing the Hook. The model fallback accepts only the exact string, with no prefix, alias, or fuzzy matching.

The recorder resolves origin before writing, and the JSONL origin field stores only this enum. It never stores `transcript_path`, raw `source`, arbitrary `other` strings, or transcript content, and none of those values enter system logs.

When JSONL omits `origin` or contains an unrecognized enum value, the origin field first decodes as `unknown`. The `WorkflowHookEvent` decoder then applies the same exact model fallback, so an event with `model == "codex-auto-review"` has `origin` equal to `autoReview` in memory. Reading never backfills or rewrites raw JSONL.

Origin classification changes only live-activity filtering, not historical aggregation input. Auto-review events still contribute to session, turn, model, tool, project, and event counts; neither the aggregation schema nor the CloudKit projection contains origin classification.

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

### A Complete Line Is the Commit Unit

The reader advances only to the offset of the final newline. If a partial line is being written at the tail, the current cycle keeps its old offset and processes the line after a future cycle sees it complete.

`JSONLines.decodeWithFailures` decodes per line. One malformed line increments the corrupt count without discarding valid events from the same read block.

### Identity Compaction

Session and turn IDs support recent exact deduplication, while long-term presentation needs counts only.

After 3 days, identifiers are compacted into counts. The accumulator chooses ID lists or counts in `finalized(identifierStorage:)`; `retained` and `compacted` select the output form and are not separately persisted mode fields.

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

### Boundary Hash and mtime

Rehashing every file across 210 days each cycle would hold `stats.lock` for too long and directly increase Hook recorder wait probability.

Maintenance records nanosecond mtime from the last boundary validation. If inode, size, and mtime are unchanged, it skips hashing. It recomputes the 4 KB before offset only after file change.

A normal append changes bytes only after offset, so the boundary continues to match and maintenance can aggregate incrementally. A changed boundary creates a new generation and marks it dirty.

### Build and Commit Validation

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

The session count deduplicates nonempty session IDs from all events except `SessionEnd` on that day. The turn count deduplicates nonempty turn IDs from all events except `Stop` on that day. A session or turn spanning multiple days contributes to each day with a nonexcluded event; a session observed only through `SessionEnd` and a turn observed only through `Stop` do not contribute.

Only one side of a paired event may persist. Counts therefore use rules that avoid duplicates while tolerating missing data:

- Tool calls use `max(PreToolUse, PostToolUse)`
- Compactions use `max(PreCompact, PostCompact)`
- Subagents use `max(SubagentStart, SubagentStop)`

A missing field differs from numeric `0`:

- Missing means the historical source cannot provide this metric for the date
- `0` means the source is available and explicitly observed none

Decoding and persistence retain optional values. The `WorkflowDailyMetrics` display projection converts missing individual event counts to `0`; session and turn counts use deduplicated IDs or compacted counts first, then fall back to corresponding event counts.

### Paired Event Counts

`PreToolUse` and `PostToolUse` describe the two sides of one tool call. Since the recorder may fail, either side may be absent:

- Adding counts one complete call twice
- Pre-only misses a failed pre write followed by a successful post
- Post-only misses a tool that started before process interruption
- `max(pre, post)` is the least duplicate-prone estimate without stable call IDs

Compaction and subagent pairs follow the same rule.

### Carrying Availability Through Old Data

Older aggregations may not have a newer Hook count. Rebuild cannot assume that an old source captured an event merely because current code understands it.

`WorkflowHookCountAvailability` records source availability for each count. Rebuild inherits an existing date's availability for old fields, while a fresh source can declare all current fields available.

This availability is retained in aggregate and sync fields; the current UI does not display missing historical fields individually.

## Schema Evolution and Rebuild

The current aggregation schema is `6`, managed by `WorkflowMaintenanceState.currentAggregationSchema`.

Increment the schema for:

- Changes to the raw-event-to-aggregate algorithm
- Added or removed output fields
- Changed field meanings
- Changed deduplication rules
- Changed source-generation merge semantics

A schema mismatch triggers a full rebuild from raw JSONL within the 210-day retention period, without field-level historical migration.

User-requested rebuilding uses the same full-recalculation path and marks dates for replacement in sync.

### Aggregation Schema Versus Source Generation

| Identity | Describes | Changes when |
| --- | --- | --- |
| Aggregation schema | How current code calculates an aggregate from raw events | Algorithm, fields, or semantics change |
| Source generation | Which generation of raw file a particular day belongs to | Replacement, truncation, requested rebuild, or boundary rewrite |

A schema change usually marks all event dates in retention dirty. A source-generation change affects only a specific date.

Neither can be replaced with the app version. One app version may not change aggregation, while development builds may iterate schemas without changing a version number.

### Rebuild Source

Aggregation-semantic changes rebuild from raw JSONL. Filling fields cannot recover identities or event relationships already lost in old aggregates. Missing semantics are retained when the raw source itself lacks the field.

### Commit Semantics for a User Rebuild

A batch rebuild handles dates independently. Failure on one day does not block days that succeeded; failed dates become dirty for normal maintenance to retry.

Both successful and failed dates register CloudKit replacement first. A failed date already entered a new generation, and its later successful automatic rebuild will use a new record identity. Without an early marker, the old generation might remain in the cloud and be added to the new value.

The operation fails as a whole only if every date fails. Partial success returns a detailed summary of successful dates, damaged lines, and pending replacement state.

## Maintenance Scheduling

[`WorkflowService.swift`](../../../CodexBar/Services/Workflow/WorkflowService.swift) is an actor that serializes reading, aggregation, pruning, and rebuild.

Maintenance coordinates with the rate-limit refresh cycle but has no data dependency on it. The Workflow view model refreshes UI no more often than every 5 seconds to avoid rerendering for frequent file changes.

### Maintenance Logs

Maintenance normally follows the 60-second refresh. An idle machine would otherwise emit more than a thousand no-change checks per day.

`WorkflowService` accumulates consecutive idle cycles and logs one summary only after a write, skip, failure, or cleanup, including the preceding idle count. Logs can prove that maintenance runs without burying real failures.

### How the Scheduler Coalesces Requests

`WorkflowSyncScheduler` serializes three request classes:

1. User rebuild, highest priority
2. Maintenance with sync
3. Local-only maintenance

After sync completes, an 8-second cooldown combines incoming requests and retains the earliest trigger as the real cause.

Opening the UI reads the current local snapshot and does not bypass the scheduler to start an unconditional CloudKit request.

## Suggested Failure-Scenario Tests

- Concurrent Codex sessions write complete lines without overwriting one another
- While the main app holds the lock, the Hook recorder succeeds within budget or abandons safely
- Non-JSON stdin or missing event name still exits successfully and immediately
- A partial tail line does not advance offset and is read after completion
- One malformed JSONL line increments only the corrupt count
- Inode change, file shrink, and boundary rewrite each create a new generation
- Appends during build commit only to the fixed upper bound and leave the tail pending
- A schema change rebuilds every in-retention date with the current algorithm
- Missing historical fields remain optional in decoding and persistence; display counts follow the current fallback rules
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

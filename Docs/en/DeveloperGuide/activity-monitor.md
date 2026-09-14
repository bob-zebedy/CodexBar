# Live Task Monitoring

[简体中文](../../DeveloperGuide/activity-monitor.md) | English

## Goals

The live-task flow answers four questions:

- Is a task currently running?
- Is a task waiting for user approval?
- Did a recent task complete or terminate?
- Which running tasks have made no progress for too long?

Hook events provide live progress and interruption signals, while rollout files supply lifecycle context. [`CodexActivityMonitor.swift`](../../../CodexBar/Services/Workflow/CodexActivityMonitor.swift) merges both into the sole task snapshot:

```text
Codex Hook -> WorkflowHookEventRecorder -> Hook JSONL
                                            |-> WorkflowService -> Daily history aggregates
                                            |-> HookEventTailReader -----+
                                                                         |-> CodexActivityMonitor
rollout JSONL -> CodexSessionLifecycleReader ----------------------------+           |
                                                                                     v
                                                                            CodexActivitySnapshot
                                                                                     |-> Activity card and task center
                                                                                     |-> Glow and sleep prevention
```

`WorkflowHookEventRecorder` extracts minimal fields from `stdin`, performs bounded rollout metadata lookup when needed, appends under a file lock, and exits. Historical aggregation and live monitoring independently read the same Hook JSONL. App-server quota and usage use a separate pipeline. See [Hook Collection and Aggregation](hook-and-aggregation.md) for collection details.

Notifications and haptics consume live transitions from the monitor. Glow consumes snapshots and terminal presentation events: orange for user approval, cyan for running, green for completion, and red for termination. Waiting takes precedence among active tasks; a short terminal indication can temporarily override active state.

### Division Between Sources

| Information | Primary source | Supplemental source |
| --- | --- | --- |
| Live prompt, tool, compact, and subagent progress | Hook | Rollout progress |
| User-approval candidate | `PermissionRequest` | Rollout reviewer confirmation |
| Turn start | `UserPromptSubmit` | Rollout `startedAt` or historical lookup |
| Completion candidate | `Stop` | Rollout terminal |
| Explicit turn interruption | `Interrupt` | Rollout terminal |
| Other terminal resolution | Rollout terminal | Retain unresolved tasks until expiration |
| Effort | Hook-recorder lookup | Rollout lifecycle backfill |

Each field is resolved from the sources listed above. Hook polling waits 2 seconds after each read, and rollout polling waits 1 second after each reconciliation round.

### Snapshots and Transitions

A snapshot may be read repeatedly after view reconstruction, a new subscription, or a settings change. A transition may be emitted once from live data only.

For example, bootstrap may recover a task already waiting for approval when the app starts:

- The snapshot shows it waiting
- No waiting transition is emitted
- The notification service therefore does not replay a historical alert

Completion works the same way. Notifications consume `.completed` transitions rather than scanning `recentCompletions`, preventing reminders on app restart or UI refresh.

## HookEventTailReader

[`HookEventTailReader.swift`](../../../CodexBar/Services/Workflow/HookEventTailReader.swift) is an actor that checks Hook event files every 2 seconds by default.

### Bootstrap

Initial startup reads the latest 24 hours to establish a task baseline:

- Read chunks of at most 512 KiB
- Try at most 3 times to obtain stable file boundaries
- Use inode and size to detect replacement or append during reading
- Never trigger historical completion or waiting notifications from bootstrap results

If stable boundaries cannot be obtained, the reader clears recovered state, moves to each date file’s tail, and publishes unhealthy state.

### Bootstrap Is One Logical Transaction

The 24-hour window may span two calendar-day files, and one file may arrive in several 512 KiB batches.

At `.bootstrapStart`, the monitor clears previous recovered state and pauses side effects. It consumes every `.bootstrapEvents` batch, then waits until `.bootstrapEnd` to:

- Fill in lifecycle from rollout
- Apply persisted Activity Protection records
- Reconcile silence under the current threshold
- Look up missing prompt starts selectively
- Publish one complete snapshot

Intermediate batches update internal task state only. Rollout backfill and protection reconciliation require a healthy source and an awake system.

### Stable-Boundary Retries

At the start of an attempt, the reader fixes inode and size for all relevant date files and validates them again after reading to those bounds:

- A historical date must retain both inode and size
- The current date may append only beyond the fixed upper bound
- The calendar day must not cross midnight during the read

If any condition fails, the reader retries from a new baseline. After three consecutive failures, it moves to the current tail and publishes degraded health, pausing Activity Protection checks.

A bootstrap that fails because a directory is unavailable or its boundaries are unstable is retried at most every 10 seconds. Existing events are replayed silently before normal incremental reading resumes. Complete malformed lines retain their coverage gaps without triggering repeated history scans.

### Complete-Line Cursor

The Hook recorder may be writing the final line. The reader includes only bytes before the last newline in `completeOffset`.

A partial line is neither discarded nor classified as corrupt. The next cycle rereads from the old offset and commits after the line is complete. Until the fixed boundary is fully consumed, the barrier returns `sourceUnavailable`. A malformed complete line degrades its date cursor until that date leaves the reading window or a replacement file is replayed.

While the Hook source is degraded, rollout reads continue for known tasks, accepting only explicit completion or interruption records from a complete current read with matching task identity. These tasks end silently. This path does not apply ordinary progress, backfill approval state, restore suppressed tasks, or resume Activity Protection. It pauses during system sleep and bootstrap, and discards results after cancellation or a reader generation change. Full lifecycle recovery still requires a successful Hook read barrier.

### Date Rollover and File Replacement

The reader keeps an independent cursor for each calendar date in the rolling 24-hour window. Every cycle covers all these dates, including intermediate dates after a long pause and late appends to the previous date. An inode change or file shrink restarts bootstrap.

When `UserPromptSubmit` predates the current incremental window, the reader can look backward up to 8 MiB to recover the prompt start of an existing task.

### `drainNow()` Read Barrier

Every caller of `drainNow()` must wait for a read that begins after its request:

```text
Call drainNow
  -> Record request generation
  -> Wait for the next new read to begin
  -> Wait for that read to finish
  -> Return that read's result
```

A read already in progress before the call cannot satisfy the barrier. If the reader is replaced, the data source is unavailable, or the task is canceled, the caller must not continue evaluating from an old snapshot.

### Exact Generational Semantics of the Barrier

Each `drainNow()` increments `requestedDrainGeneration` and registers its own waiter.

If a read is in flight, the request sets only `hasPendingDrain`. After the current cycle completes, the reader must begin another cycle that captures this request generation.

One read can satisfy several waiters queued before it begins, but not a waiter added afterward. This is the happens-after guarantee required for wake recovery.

Actors can reenter during `await`; `isProcessingReads` and `hasPendingDrain` converge all external requests into one serial drain loop so two reads never advance offset concurrently.

## Rollout Lifecycle Reading

[`CodexSessionLifecycleReader.swift`](../../../CodexBar/Services/Workflow/CodexSessionLifecycleReader.swift) reads `$CODEX_HOME/sessions` and `$CODEX_HOME/archived_sessions`.

Rules are:

- Poll every 1 second by default
- Begin with a 512 KiB tail window
- Look back at most 8 MiB for turn-context fields such as effort
- Parse only lifecycle, turn, progress, effort, and reviewer
- Keep conversation content out of the activity model and product presentation

Hook `Stop` marks the task as “Finishing up” and keeps it active. Tools, approvals, and other progress continue updating the same task. Rollout `task_complete` confirms completion; transition freshness and recovery conditions determine whether a completion transition is emitted.

If rollout is temporarily unreadable or the session or turn cannot be matched, the task continues waiting for reconciliation. `Stop` does not start a terminal timeout. A new turn or `SessionEnd` removes the old task from the active list and starts five seconds of fast terminal polling, followed by polling every 30 seconds. A late `Stop` updates only the pending task's metadata and progress, without restoring its presentation or resetting the deadline.

### Explicit Interruptions

`Interrupt` ends the matching top-level turn, clears protection state and notifications, and stores a termination record. It can match running, approval-waiting, suppressed, and pending-terminal tasks; a newer turn in the same session stays active. Ambiguous matches are ignored.

Hook and rollout terminal signals share deduplication records, retaining the first confirmed completion or termination. Terminations are displayed without triggering completion notifications or haptics.

### Locating Session Files

The reader checks a few likely directories first:

1. `sessions/YYYY/MM/DD` for the task start date
2. The current date directory
3. `archived_sessions`

A resume can continue a session created long ago. If the fast path misses, the fast path can retry every 10 seconds and the recursive fallback every 60 seconds. This discovers delayed or moved files without traversing the tree every second.

If a file moves to the archive, a missing cached URL clears its cursor and allows full discovery again.

### Rollout Read Budget

Live tasks need lifecycle near an active turn, not a full read of a long-running session. Starting from the last 512 KiB reduces resident I/O and discards the first potentially partial line.

If context, effort, or reviewer is missing, the reader replays up to 8 MiB to recover turn ownership, metadata, and progress together. Each file cursor stops looking back after one successful backfill; each cycle backfills at most one session.

Incremental scanning shares an 8 MiB budget per cycle across sessions in rotating order. At most 16 pending tasks are queried per cycle. Budget exhaustion and partial lines return `incomplete`, read failures return `unavailable`, and unresolved files return `notFound`. Cached facts do not establish successful current coverage. A complete read with turn context sets `lifecycleCoverageCheckedAt` to the check time; an incomplete or failed read, a missing file, or missing context clears it. Protection requires this timestamp to be present and less than five seconds old.

The incremental scan advances its offset by complete lines. A line larger than 8 MiB returns `incomplete` from the same line start each cycle, preventing consumption of subsequent records.

A malformed rollout line marks unfinished turns as having a coverage gap. Repeated context for the same turn does not clear the gap. New turns establish independent coverage, and explicit terminal records can end a task with incomplete history. Later malformed lines do not revoke known terminal facts. Failed or incomplete reads cannot use cached progress to advance task progress, restore suppressed tasks, or remove protection records.

### Associating Rollout Progress with a Turn

Each session file cursor stores its own `currentTurnId`, updated in JSONL file order:

- Outer `type = "turn_context"`, or `type = "event_msg"` with `payload.type = "task_started"`, establishes context from `payload.turn_id`
- An explicit `payload.turn_id` takes priority; a record without it inherits cursor context
- `task_complete` or `turn_aborted` for the current turn clears context; a late terminal for another turn does not
- Truncation or replacement rebuilds the cursor and clears both context and cached lifecycle states

Progress includes records whose outer `type` is `response_item` or `token_usage_record`, and `event_msg` records whose `payload.type` is `token_count`, `item_completed`, `agent_message`, `agent_reasoning`, `task_started`, `task_complete`, or `turn_aborted`. Time comes from outer `timestamp`, then `payload.completed_at`, then `payload.started_at`.

A record needs a usable timestamp and turn identity. It advances task progress only after a complete current read and when newer than `lastProgressAt`. A `token_usage_record` is treated as activity without comparing token totals. Records lacking both an explicit turn and cursor context do not contribute task progress.

### Rollout Fields

The shared `CodexRolloutLineEnvelope` extracts only fields needed for turn context, lifecycle, and progress. Prompt, response, and tool content never enters the activity model.

Terminal resolution requires a nonempty `payload.turn_id` and a `complete` current read. With outer `type = "event_msg"`, `payload.type = "task_complete"` and a valid `payload.completed_at` confirm completion; `payload.type = "turn_aborted"` confirms interruption. Completion time uses Unix seconds, and `payload.duration_ms` is converted to seconds for duration display. A missing interruption timestamp uses reconciliation time for an active task or removal time for a pending task, never earlier than its last activity.

## Task Identity

The task key chooses the most precise available identity:

1. `session ID + turn ID`
2. `session ID`
3. Anonymous project key

A new prompt replaces the old turn in the same session. The old turn waits for an explicit terminal result in the background: fast polling for five seconds, then every 30 seconds, retained for at most 24 hours after removal from the active list.

Subagent events update activity under their parent task and do not create separate top-level cards.

### Identity Precision and Fallback

`session ID + turn ID` precisely distinguishes sequential turns in one session and is preferred.

Some events contain only session ID. A later top-level Hook that matches the task and supplies a turn ID fills the in-memory `associatedTurnId` and terminal alias for rollout lookup and deduplication, retaining the original key and protection hash.

Terminal matching checks exact keys and aliases first, then pending tasks in the session. One pending candidate is selected; several return `ambiguous`. Active tasks are checked only when no pending candidate matches. Candidates must satisfy Hook timestamp ordering and turn identity conditions.

Without a session ID, only a project key remains. It may merge concurrent anonymous tasks in one project, so anonymous tasks provide reversible UI visibility but cannot drive notifications, sleep prevention, or persisted protection.

### Live Task Origin Filtering

`CodexActivityMonitor.apply` checks `WorkflowHookEvent.origin` before task-state transitions. See [Origin Normalization](hook-and-aggregation.md#origin-normalization) for input classification.

The monitor remembers origins in memory for 24 hours by exact `session ID + turn ID`. Codex subagent Hooks reuse the parent session ID, so origin decisions do not apply to an entire session.

| Event origin | Live processing |
| --- | --- |
| `main`, `auxiliary` | Remember the explicit origin and apply normal state-machine rules |
| `autoReview` | Ignore the event and remove the same key's activity, pending terminals, display records, and stalled-task protection; retain origin memory |
| `unknown` with a valid remembered `main` or `auxiliary` origin for the same key | Continue processing with the confirmed origin |
| `unknown` without valid normal-origin memory | Ignore the event |

Events missing a session ID or turn ID do not create origin memory; `unknown` and `autoReview` events are ignored. A task with a confirmed origin survives a temporary rollout read failure. Late events still pass the state machine's timestamp and terminal-deduplication checks.

These rules apply to bootstrap and live reads. Other subagents, including Memories, are classified as `auxiliary` and follow auxiliary-task association rules. Historical aggregation still consumes all raw events. Origin memory is neither persisted nor uploaded.

### New Prompts and Terminal Confirmation

A new prompt moves the previous turn in the same session to `pendingTerminalTasks` while rollout confirms its result:

- Remove it from the active snapshot immediately
- Retain task metadata and start time
- Poll quickly for five seconds, then every 30 seconds for rollout terminal
- Classify accurately as completed or aborted when terminal arrives
- Remove unresolved tasks after 24 hours without inventing completion, termination, notification, or glow events

`SessionEnd` uses the same confirmation window but moves all tasks in the session no later than that event.

### Rejecting Late Events

Tasks store `lastHookEventAt` and `lastProgressAt`; `lastActivityAt` reads the same value as `lastProgressAt`:

| Field | Source and purpose |
| --- | --- |
| `lastHookEventAt` | Latest accepted Hook timestamp, used to reject stale Hook state changes |
| `lastProgressAt` | Latest progress from Hook and rollout, used by inactivity protection |
| `lastActivityAt` | Computed from `lastProgressAt`, used for ordering, retention, and terminal timestamp adjustment |

Rollout progress never advances `lastHookEventAt`. Reading a later rollout record first still allows a slightly earlier, valid permission, tool, compaction, interruption, or new-prompt Hook. Accepting such Hooks keeps `lastProgressAt` and `lastActivityAt` monotonic.

Completion and termination share the in-memory `recentlyEndedTaskAt` map of end times. Their display records remain separate and expire after 10 minutes; deduplication memory lasts 24 hours independently. Removing a record through origin filtering recomputes its session alias from the remaining terminal timestamps.

Late events follow these rules:

- Hook state changes and approval requests use `lastHookEventAt`; an approval request older than the latest Hook progress does not restore waiting
- An exact turn cannot be recreated while terminal memory is retained; session and anonymous keys can be reused only by a newer prompt
- A `Stop` matching several candidates is not guessed
- A key already in terminal deduplication memory clears recovery tasks left by abnormal ordering

These comparisons use event time rather than batch-arrival order because cross-process file writes and rollout polling can deliver old events late.

### Anonymous Tasks

When `WorkflowHookEvent.sessionId` is missing, the key is an anonymous project key. `isAnonymous` propagates through `CodexActivityTaskSnapshot`, `CodexActivityCompletion`, and `CodexActivityTermination`.

Anonymous tasks remain in activity snapshots and recent terminal records. The activity card and Task Center use the orange `person.crop.circle.dashed` icon with help text `Anonymous tasks do not prevent sleep`. The card's `+N` counts all other active tasks only.

Anonymous running tasks do not show precise elapsed time, and anonymous completion and termination records omit precise duration.

They publish no waiting or completion transitions to notification consumers, trigger no task haptics, enter neither the running nor waiting sets for KeepAlive, and do not participate in Stalled Task Protection. `activityProtectionIdentifier` returns `nil` for an anonymous key, so protection state never persists an anonymous task.

## State Machine

Active tasks mainly use these internal states:

| State | Meaning |
| --- | --- |
| `running` | Codex is processing the current turn |
| `waitingApproval` | The current turn is explicitly waiting for user approval |
| `suppressed` | Stalled Task Protection hid the task pending new progress |

`PermissionRequest` enters `waitingApproval` only when the reviewer is the user. Automatic or policy approval does not count as user waiting.

Task endings are handled by signal:

- `Stop` marks the task as finishing while retaining it in the active list
- `Interrupt` records the matching turn as terminated
- Rollout terminal confirms completion or termination
- A new turn or `SessionEnd` removes the old task from the active list and starts background reconciliation; missing terminal evidence stays unresolved until cleanup

### Main Event-to-State Transitions

| Current state | Input | New state | Additional action |
| --- | --- | --- | --- |
| Absent | `UserPromptSubmit` | running | Save trusted `startedAt` |
| Absent | Top-level tool or compact | running | Recover task with unknown `startedAt` |
| running | Tool, compact, or subagent progress | running | Update last progress and generation |
| running | `PermissionRequest` + reviewer user | waitingApproval | Publish live waiting transition |
| waitingApproval | Tool, compaction, or subagent Hook progress | running | Clear the pending approval candidate and update activity and progress |
| running or waiting | `Stop` | running | Show Finishing up and retain the task until rollout confirms its terminal state |
| active | New prompt or `SessionEnd` | pending terminal | Remove from snapshot and begin background terminal polling |
| active, suppressed, or pending terminal | `Interrupt` | terminated | Remove the matching task, record termination, and clear protection state and notifications |
| running | Protection conditions hold and silence reaches threshold | suppressed | Hide and remove sleep-prevention contribution |
| suppressed | Valid tool, compaction, subagent, or `Stop` Hook, or new progress from healthy reconciliation | running | Clear persisted protection and old notification |
| active, suppressed, or pending terminal | Matching rollout terminal from a complete read | completed or terminated | Record the terminal and remove the task; process silently while degraded |

### Two-Stage Approval Confirmation

The task’s `approvalReviewer` comes from Hook records or rollout `payload.approvals_reviewer`, with values `user`, `auto_review`, or `guardian_subagent`.

A `PermissionRequest` enters waiting immediately when the task’s known reviewer is `user`. An unknown reviewer leaves `pendingApprovalRequestedAt` for rollout backfill. Automatic review routes retain the current state and clear the candidate during reconciliation.

Valid tool, compaction, subagent, or top-level `Stop` Hooks restore running and clear the pending candidate. Later reviewer backfill does not reopen cleared waiting. Rollout progress updates timestamps without clearing approval waiting on its own.

Approval waiting is tracked per task. Valid Hook progress from another parallel tool or subagent within the same task also clears waiting.

### Effort Merging

Several context events in one turn may report different reasoning efforts. The task does not silently let the last overwrite the first. It marks `mixed` after observing conflict.

### Subagent Count Reliability

A subagent turn ID belongs to the subagent, so its parent can be associated only by shared session.

Subagent Hooks associate with the session’s sole active parent. With an older pending task present, `SubagentStart` may associate; other subagent events require an `agent_id` already recorded under the active parent. Events with no unique parent are ignored.

Count reliability is initialized from whether the prompt start is known. A missing `agent_id` or a stop first observed for an agent sets reliability to `false`, hiding the count in the UI. Each agent’s running state follows its own event timestamps.

## Snapshot Priority

The activity card selects content through `primaryActivity` in this order:

```text
Waiting for approval > Running > Latest completion or termination > Idle
```

`latestTerminalEvent` selects the latest completion or termination by end time, with termination taking precedence on ties. The activity card, menu bar, and idle task glow share this result. The menu bar uses `primaryActivity` and limits terminal display to 10 seconds after the end timestamp. Task Center retains terminal records for 10 minutes; terminal deduplication memory lasts 24 hours.

The snapshot feeds:

- Menu bar person symbol
- Main-panel task card
- Task Center
- Task glow, receiving snapshots and new terminal events through `presentationPublisher`
- Notification system
- Sleep-prevention controller

### Snapshot Publication

The monitor checks rollout each second and refreshes at cleanup deadlines.

A candidate snapshot is compared with the current value and published only after structural change. Views format elapsed time from the current clock and do not require per-second mutation of task objects.

### Presentation Updates

`presentationPublisher` publishes the current snapshot and the batch's still-valid `terminalEvents` for Task Glow. Presentation events include anonymous tasks; notifications use the separate `transitionPublisher`.

Completion transitions and terminal indicators require an end timestamp no more than 10 seconds old and no earlier than their respective recovery boundaries. Waiting transitions confirmed directly by Hook also use a 10-second limit. Waiting confirmed by rollout reviewer backfill checks only that the request is no earlier than `sessionTransitionNotBefore`.

History reloads, sleep recovery, and source health changes clear pending events and update `terminalPresentationNotBefore`. Publication pauses during bootstrap, recovery reconciliation, and unhealthy source state.

### Stable Ordering

Several tasks in one batch can share a timestamp; comparing timestamps alone does not determine their relative order.

All lists sort by most recent time first and then display UUID string. Stable order keeps SwiftUI diffing from jumping when equivalent tasks randomly exchange positions.

### Cleanup Uses the Nearest Deadline

The monitor manages expiration for pending tasks, active tasks, history, terminal deduplication, and protection records. Menu bar terminal hints and task glow have their expiry managed by `StatusItemController` and `TaskGlowController`, respectively. Hint expiry does not republish activity snapshots.

The cleanup task waits for the nearest future deadline, processes it, then schedules the next.

## System Sleep and Wake

Stalled Task Protection pauses when the system is about to sleep. Full recovery after wake follows this order:

1. Enter recovery and keep protection paused
2. Wait for `HookEventTailReader.drainNow()` to succeed
3. Reset rollout-lifecycle parsing fallback
4. Reconcile from the new Hook and rollout results together
5. Resume Stalled Task Protection

If the Hook barrier returns `sourceUnavailable`, only explicit terminal records for known tasks are reconciled, silently, while protection stays paused. Later polling retries full recovery. Reader replacement or task cancellation discards that round’s results.

### Evaluation Pauses During System Sleep

Silence evaluation stops during system sleep. On recovery, the monitor silently reconciles progress from newly read Hook and rollout data before resuming normal evaluation.

The check task waits with `SuspendingClock`, but silence duration is calculated from `Date` and `lastProgressAt` without subtracting time spent asleep. `will-sleep` enters recovery; `did-wake` reevaluates after a new data read barrier.

### Identity and Generations During Wake Recovery

Full recovery consumes Hook events first to establish task identities created during sleep, then merges rollout lifecycle and progress before resuming protection. Degraded terminal reconciliation handles known tasks only.

`tailReaderGeneration` prevents a returning wake task from using a reader replaced by a Hook settings change. `activityProtectionRecoveryGeneration` prevents an older recovery from unpausing evaluation after two overlapping sleep or settings changes.

If the recovery generation changes while bootstrap awaits rollout, its old lifecycle result is discarded. Bootstrap then enters a fresh read barrier instead of completing the newer recovery generation.

## Stalled Task Protection

Stalled Task Protection works only while Prevent System Sleep is enabled and evaluates only non-anonymous `running` tasks.

Tasks waiting for approval are excluded because waiting is a legitimate no-progress state.

Threshold options are:

- 30 minutes
- 1 hour, the default
- 2 hours
- 4 hours

At the threshold:

1. Update the in-memory protection record and enqueue its serial persistence
2. Start notification submission and a 3-second grace period together
3. Revalidate the candidate after notification completes or grace expires
4. If still valid, hide it from the activity snapshot
5. If new progress appears during or after this process, clear protection and restore display

Hiding does not depend on notification success. The 3 seconds is only the maximum wait for an explanatory notification; sleep-prevention contribution is still released afterward.

Evaluation pauses during:

- Hook bootstrap
- System sleep
- Wake recovery
- Hook data-source unavailability
- Reader replacement

### Purpose of Progress Generation

Timestamps alone cannot protect an asynchronous attempt. Two progress events may share the same second, and the threshold setting may change while notification submission is in flight.

Every valid progress event increments `progressGeneration`. A protection candidate stores:

- Task display ID
- Last-progress timestamp
- Progress generation
- Threshold at the time

All four must still match when notification returns or grace expires. Any new progress or threshold change invalidates the old attempt.

### Protection Record Save Ordering

An attempt updates the in-memory record synchronously, then a task calls `ActivityProtectionStateStore.apply` in sequence. A disk-write failure is logged and does not prevent hiding the task.

Saved records restore protection during the next bootstrap. Hiding does not wait for disk commit, so recovery across restarts depends on the write succeeding.

### Reconciling Threshold Changes

Shortening the threshold immediately reevaluates running tasks already past it.

Increasing the threshold silently restores suppressed tasks that no longer exceed it and clears their records and notifications. Tasks still beyond the threshold remain hidden.

Turning off the sleep-prevention switch disables Activity Protection and restores all suppressed tasks in the current process.

## Protection-State Persistence

[`ActivityProtectionStateStore.swift`](../../../CodexBar/Services/Workflow/ActivityProtectionStateStore.swift) writes:

```text
~/Library/Application Support/CodexBar/ActivityProtection/state.json
```

- Current schema is `1`
- Contains only hashed task identities and timestamps
- File permissions are `0600`
- Debug and Release share it through `flock`
- Records remain at most 24 hours after last progress

Task identity uses a SHA-256 digest; raw session and turn IDs never enter this state file. Anonymous tasks have no protection identity and never enter it.

### Constructing the Hashed Identity

Turn and session keys first become canonical strings with type prefixes and NUL separators, then SHA-256 is applied with the fixed domain separator `CodexBar.ActivityProtection.v1`.

Types and separators prevent boundary ambiguity between concatenated fields. The domain separator prevents directly correlating the same raw ID hashed for another use.

### Cross-Process State Merge

Both app bundle IDs can run together and observe the same Codex Hook data. With separate protection state, a stalled task hidden by one build might still drive sleep prevention in the other.

The state store uses an actor to serialize within one process and `flock` for cross-process read-modify-write. A removal can include `matchingMarkedAt`, preventing a late delete from an old process from removing a new record just written by another.

Writes sort by task identifier, atomically replace the file, and correct final permissions to `0600`.

## Generation and Old-Result Isolation

The monitor maintains generations for readers and asynchronous recovery:

- Discard late results from a replaced reader
- Publish no transition side effects before bootstrap completes
- A canceled drain does not satisfy a recovery barrier
- Explicitly unhealthy source state cannot reuse the last healthy snapshot for silence evaluation

### Main Generations in the Monitor

| Generation | Protected asynchronous path |
| --- | --- |
| `tailReaderGeneration` | Reader batch, rollout polling, and prompt backfill |
| `bootstrapCompletionGeneration` | Bootstrap lifecycle completion and rollout reconciliation results spanning a bootstrap |
| `activityProtectionRecoveryGeneration` | Sleep/wake recovery and rollout reconciliation results spanning recovery generations |
| Task `progressGeneration` | Protection candidate during notification grace |

Task progress invalidates its protection attempt. Reader, bootstrap, and recovery generations each isolate their own asynchronous results.

## Suggested Failure-Scenario Tests

- Continue from a Stop handler, then complete or interrupt, without premature completion notifications
- Interrupt while a Stop handler is running and confirm one termination record and red hint
- Keep rollout unreadable for more than five seconds, then recover and confirm completion once
- Request approval after Stop continuation, then interrupt and clear the waiting task
- Interrupt running, waiting, and suppressed tasks; verify state, duration, protection cleanup, and no completion notification
- Deliver Hook and rollout termination in both orders; verify one record and one hint
- Interrupt an old turn after starting a new one; keep the new turn active
- Replay duplicate Interrupt and late tool/prompt events without restoring the ended turn
- Starting the app while a task is running shows it through bootstrap without replaying notifications
- Bootstrap retries while files continuously append and eventually obtains a stable boundary
- Three unstable attempts enter degraded state without starting silence evaluation
- Replace an old turn with a new prompt and verify classification when the terminal arrives within and after the first five seconds
- A `Stop` is not guessed when one session has several terminal candidates
- Read an approval Hook and slightly later rollout progress in both orders; both show orange waiting and emit one waiting transition
- Advance rollout progress before tool, compaction, or subagent Hooks; those Hooks still clear waiting and update activity. Delayed approval requests or reviewer backfill do not reopen cleared waiting; interruption and `SessionEnd` still end the corresponding task
- Attribute turnless records after a new boundary only to the new turn; late old terminals, incremental reads, and file replacement preserve context isolation
- A missing reviewer enters waiting only after rollout confirms user
- Automatic review never emits a waiting transition
- The UI hides the subagent count when count reliability is `false`
- Calling `drainNow()` during a read forces another new read
- A failed wake drain keeps protection paused; explicit rollout terminals silently end known tasks during Hook corruption, while ordinary progress leaves suppressed tasks hidden
- A silence candidate that progresses within the 3-second window is not hidden, and a late notification is withdrawn
- Lengthening the threshold restores suppressed tasks below the new threshold
- Concurrent Debug and Release updates do not let an old removal delete a new protection record
- Anonymous tasks never enter transitions, KeepAlive, or the protection state file

## Key Source Files

- [`CodexActivityMonitor.swift`](../../../CodexBar/Services/Workflow/CodexActivityMonitor.swift)
- [`CodexActivityTask.swift`](../../../CodexBar/Services/Workflow/CodexActivityTask.swift)
- [`CodexActivityTerminalResolution.swift`](../../../CodexBar/Services/Workflow/CodexActivityTerminalResolution.swift)
- [`HookEventTailReader.swift`](../../../CodexBar/Services/Workflow/HookEventTailReader.swift)
- [`CodexSessionLifecycleReader.swift`](../../../CodexBar/Services/Workflow/CodexSessionLifecycleReader.swift)
- [`CodexActivityProtection.swift`](../../../CodexBar/Services/Workflow/CodexActivityProtection.swift)
- [`ActivityProtectionStateStore.swift`](../../../CodexBar/Services/Workflow/ActivityProtectionStateStore.swift)

# Live Task Monitoring

[简体中文](../../DeveloperGuide/activity-monitor.md) | English

## Design Motivation

A live task is not a direct mapping of Hook events.

One turn may have missing, late, or duplicate events; only a session ID; a new prompt replacing an old turn; `Stop` and rollout terminal arriving in either order; or an app launch after the task has already run for some time.

`CodexActivityMonitor` combines these incomplete observations into a conservative task state machine and produces two different outputs:

- A snapshot describes what can be displayed now
- A transition describes what just happened and may drive a one-time side effect

If every consumer inferred tasks from Hook lists independently, the menu bar, notifications, and sleep prevention would disagree at edge cases.

## Goals

The live-task flow answers four questions:

- Is a task currently running?
- Is a task waiting for user approval?
- Did a recent task complete or terminate?
- Which running tasks have made no progress for too long?

Hook events provide low-latency signals, and rollout files provide authoritative lifecycle context. [`CodexActivityMonitor.swift`](../../../CodexBar/Services/Workflow/CodexActivityMonitor.swift) merges both into the sole task snapshot:

```text
Hook JSONL -> HookEventTailReader -----+
                                      +-> CodexActivityMonitor -> ActivitySnapshot
rollout JSONL -> SessionLifecycleReader+
```

### Division Between Sources

| Information | Primary source | Supplemental source |
| --- | --- | --- |
| Live prompt, tool, compact, and subagent progress | Hook | Rollout progress |
| User-approval candidate | `PermissionRequest` | Rollout reviewer confirmation |
| Turn start | `UserPromptSubmit` | Rollout `startedAt` or historical lookup |
| Completion candidate | `Stop` | Rollout terminal |
| Completion versus termination | Rollout terminal | Grace-expiration fallback |
| Effort | Hook-recorder lookup | Rollout lifecycle backfill |

Hook prioritizes low latency; rollout prioritizes semantic accuracy. They do not simply overwrite by timestamp. Every field has its own trusted source.

### Why Snapshot and Transition Are Separate

A snapshot may be read repeatedly after view reconstruction, a new subscription, or a settings change. A transition may be emitted once from live data only.

For example, bootstrap may recover a task already waiting for approval when the app starts:

- The snapshot should show it waiting
- No waiting transition should be emitted
- The notification service therefore does not replay a historical alert

Completion works the same way. Notifications consume `.completed` transitions rather than scanning `recentCompletions`, preventing reminders on app restart or UI refresh.

## HookEventTailReader

[`HookEventTailReader.swift`](../../../CodexBar/Services/Workflow/HookEventTailReader.swift) is an actor that checks Hook event files every 2 seconds by default.

### Bootstrap

Initial startup reads the latest 24 hours to establish a task baseline:

- Read chunks of at most 512 KB
- Try at most 3 times to obtain stable file boundaries
- Use inode and size to detect replacement or append during reading
- Never trigger historical completion or waiting notifications from bootstrap results

If it cannot obtain a stable boundary, the reader moves to the current file tail and publishes explicit unhealthy state. Incomplete history is not misrepresented as a real task change.

### Bootstrap Is One Logical Transaction

The 24-hour window may span two calendar-day files, and one file may arrive in several 512 KB batches.

At `.bootstrapStart`, the monitor clears previous recovered state and pauses side effects. It consumes every `.bootstrapEvents` batch, then waits until `.bootstrapEnd` to:

- Fill in lifecycle from rollout
- Apply persisted Activity Protection records
- Reconcile silence under the current threshold
- Look up missing prompt starts selectively
- Publish one complete snapshot

Neither UI nor notifications should observe a partially recovered intermediate batch.

### Why Stable Boundaries Retry Three Times

At the start of an attempt, the reader fixes inode and size for all relevant date files and validates them again after reading to those bounds:

- A historical date must retain both inode and size
- The current date may append only beyond the fixed upper bound
- The calendar day must not cross midnight during the read

If any condition fails, the reader retries from a new baseline. After three consecutive failures it moves to the current tail so bootstrap cannot block forever. Degraded health communicates the cost to Activity Protection instead of pretending success.

### Why Offset Advances Only Across Complete Lines

The Hook recorder may be writing the final line. The reader includes only bytes before the last newline in `completeOffset`.

A partial line is neither discarded nor classified as corrupt. The next cycle rereads from the old offset and commits after the line is complete.

### Date Rollover and File Replacement

Normal rollover drains the old date file before switching to the new date. An inode change or file shrink restarts bootstrap instead of reusing the old cursor.

When `UserPromptSubmit` predates the current incremental window, the reader can look backward up to 8 MB to recover the prompt start of an existing task.

### `drainNow()` Read Barrier

`drainNow()` is not an ordinary immediate-refresh hint. Every caller must wait for a read that begins after its request:

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
- Begin with a 512 KB tail window
- Look back at most 8 MB for turn-context fields such as effort
- Parse only lifecycle, turn, progress, effort, and reviewer
- Never read or store conversation content for product presentation

Hook `Stop` is only a completion candidate. Rollout terminal state distinguishes actual completion, user cancellation, and abnormal termination.

### Locating Session Files

The reader checks a few likely directories first:

1. `sessions/YYYY/MM/DD` for the task start date
2. The current date directory
3. `archived_sessions`

A resume can continue a session created long ago. If the fast path misses, each active session lifecycle performs one recursive fallback scan at most, avoiding a full sessions-tree traversal every second.

If a file moves to the archive, a missing cached URL clears its cursor and allows full discovery again.

### Why the Rollout Cursor Starts at the Last 512 KB

Live tasks need lifecycle near an active turn, not a full read of a long-running session. Starting from the last 512 KB reduces resident I/O and discards the first potentially partial line.

If effort remains missing, a targeted lookup for that turn can read up to 8 MB.

Effort backfill applies only to nonterminal tasks that have run for at least 2 seconds and still lack effort, with a 10-second retry interval per turn. This avoids a large search immediately after every task creation.

### Why Only Structural Events Are Parsed

The shared `CodexRolloutLineEnvelope` extracts only fields needed for turn context, lifecycle, and progress. Prompt, response, and tool content never enters the activity model.

This tightens privacy boundaries and reduces decode cost for large rollouts. A new live field should extend the minimal envelope rather than decode the full transcript into a general JSON tree.

## Task Identity

The task key chooses the most precise available identity:

1. `session ID + turn ID`
2. `session ID`
3. Anonymous project key

A new prompt replaces the old turn in the same session. The old turn enters terminal grace for up to 5 seconds so late ending events can reconcile it.

Subagent events update activity under their parent task and do not create separate top-level cards.

### Why Identity Degrades by Precision

`session ID + turn ID` precisely distinguishes sequential turns in one session and is preferred.

Some events contain only session ID. A session key still participates in state, but terminal matching must be more conservative. If one session has several candidates, the monitor returns ambiguous rather than guessing which task ended.

Without a session ID, only a project key remains. It may merge concurrent anonymous tasks in one project, so anonymous tasks provide reversible UI visibility but cannot drive notifications, sleep prevention, or persisted protection.

### Auto-review Origin Filtering

`CodexActivityMonitor.apply` checks `WorkflowHookEvent.origin` before any state transition. At construction and decoding boundaries, `WorkflowHookEvent` prefers an explicit origin and uses an exact `model == "codex-auto-review"` match as the `.autoReview` fallback only when that origin is `unknown`. An `autoReview` event never enters the live-task state machine, so it cannot appear in the menu bar, activity card, Task Center, or task counts and cannot produce notifications, haptics, approval waiting, Stalled Task Protection, or sleep-prevention contribution.

Filtering uses the exact `session ID + turn ID` because Codex subagent Hooks reuse the parent session ID. Filtering by session alone would also hide the real main task.

When an exact Auto-review event arrives, the monitor:

- Removes the active task and terminal-grace candidate for that key
- Removes recent completion, recent termination, and terminal-deduplication memory for that key
- Cancels Stalled Task Protection attempts, persisted records, and pending notifications
- Remembers the exact key in a 24-hour bounded table so later `unknown` events cannot revive the same task

If an explicit `main` or `auxiliary` event later matches the same key, source truth wins and clears that ignored-key inference. An Auto-review event without a turn ID is ignored only for that event and never creates a session-wide blacklist.

Other subagents normalize to `auxiliary` and retain their existing behavior; Memories does not change under this rule. Raw Hook events still enter historical aggregation, so live-task filtering does not change metrics or CloudKit data.

When JSONL omits `origin` or contains an unrecognized origin value, the origin field first decodes as `unknown`. If that record's model exactly equals `codex-auto-review`, the event model normalizes `origin` to `.autoReview`; other records remain `.unknown`. The monitor replays only the most recent 24 hours, does not scan historical rollouts, and does not rewrite raw Hook records.

### Why a New Prompt Does Not Immediately Terminate the Old Turn

Turns in one session run sequentially. When a new prompt arrives, the old turn must leave the active list immediately or the UI briefly shows two top-level tasks.

The new prompt may precede the old turn's rollout terminal, however. Recording termination immediately would misclassify a normally completed task.

The old turn therefore moves to `pendingTerminalTasks`:

- Remove it from the active snapshot immediately
- Retain task metadata and start time
- Wait up to 5 seconds for rollout terminal
- Classify accurately as completed or aborted when terminal arrives
- Converge with a conservative fallback when grace expires without terminal

`SessionEnd` uses the same confirmation window but moves all tasks in the session no later than that event.

### Rejecting Late Events

Tasks store `lastActivityAt`, and terminal memory stores completion or termination time:

- An event older than current last activity cannot overwrite newer state
- A new prompt no later than a remembered terminal cannot revive the old task
- A `Stop` matching several candidates is not guessed
- A key already in terminal deduplication memory clears recovery tasks left by abnormal ordering

These comparisons use event time rather than batch-arrival order because cross-process file writes and rollout polling can deliver old events late.

### Anonymous Tasks

When `WorkflowHookEvent.sessionId` is missing, the key is an anonymous project key. `isAnonymous` propagates through `CodexActivityTaskSnapshot`, `CodexActivityCompletion`, and `CodexActivityTermination`.

Anonymous tasks remain in activity snapshots and recent terminal records. The activity card and Task Center use the orange `person.crop.circle.dashed` icon with help text `Anonymous tasks do not prevent sleep`. The card's `+N` counts all other active tasks only.

Anonymous running tasks do not show precise elapsed time, and anonymous completion and termination records omit precise duration.

They publish no waiting or completion transitions to notification consumers, trigger no task haptics, enter neither the running nor waiting sets for KeepAlive, and do not participate in Stalled Task Protection. `activityProtectionIdentifier` returns `nil` for an anonymous key, so protection state never persists an anonymous task.

### Why Anonymous Tasks Still Appear in the UI

A missing session ID does not mean the task does not exist. Dropping it entirely would show Codex working while CodexBar appears idle.

Keeping visibility while forbidding high-impact side effects is a layered response to uncertain identity:

- Later events can correct a visibility error
- A false notification interrupts the user
- Incorrect sleep prevention may last for hours
- Persisting an anonymous project key might suppress a different real task later

The orange dashed-person icon therefore communicates limited capability instead of presenting an anonymous task as precise.

## State Machine

Active tasks mainly use these internal states:

| State | Meaning |
| --- | --- |
| `running` | Codex is processing the current turn |
| `waitingApproval` | The current turn is explicitly waiting for user approval |
| `suppressed` | Stalled Task Protection hid the task pending new progress |

`PermissionRequest` enters `waitingApproval` only when the reviewer is the user. Automatic or policy approval does not count as user waiting.

Terminal signals reconcile by reliability:

- `SessionEnd` ends the session
- Rollout terminal distinguishes completion from termination
- `Stop` creates a completion candidate without stronger evidence
- A new prompt may end the display lifecycle of the old turn

### Main Event-to-State Transitions

| Current state | Input | New state | Additional action |
| --- | --- | --- | --- |
| Absent | `UserPromptSubmit` | running | Save trusted `startedAt` |
| Absent | Top-level tool or compact | running | Recover task with unknown `startedAt` |
| running | Tool, compact, or subagent progress | running | Update last progress and generation |
| running | `PermissionRequest` + reviewer user | waitingApproval | Publish live waiting transition |
| waitingApproval | New progress | running | Clear pending approval and protection record |
| running or waiting | `Stop` | terminal candidate | Retain completion or wait for rollout reconciliation |
| active | New prompt or `SessionEnd` | pending terminal | Remove from snapshot and begin 5-second grace |
| running | Silence exceeds threshold | suppressed | Hide and remove sleep-prevention contribution |
| suppressed | New progress | running | Clear persisted protection and old notification |

### Why Waiting for Approval Uses Two-Phase Confirmation

`PermissionRequest` indicates an approval flow, but reviewer may be user, policy, or automatic review.

If the Hook event includes reviewer, the task can confirm immediately. If reviewer is missing, it saves `pendingApprovalRequestedAt` and waits for rollout polling to fill it in.

Only an explicit user reviewer emits a waiting transition. Remaining running while uncertain is more truthful than falsely telling the user Codex is waiting for them.

### Why Effort Can Become `mixed`

Several context events in one turn may report different reasoning efforts. The task does not silently let the last overwrite the first. It marks `mixed` after observing conflict.

This tells the UI that several values genuinely appeared over the task lifecycle rather than displaying a precise-looking value from only the final observation.

### Why Subagent Count Can Be Unknown

A subagent turn ID belongs to the subagent, so its parent can be associated only by shared session.

Active subagent count is reliable only when exactly one active parent exists in that session, no pending-terminal ambiguity exists, and start/stop events carry stable agent IDs.

With missing IDs, stop-before-start, or several candidates in one session, the monitor lowers reliability and the UI omits a falsely precise number.

## Snapshot Priority

When several tasks and temporary states coexist, the outward snapshot uses this priority:

```text
Waiting for approval > Running > Recently completed > Recently terminated > Idle
```

Completion remains green in the menu bar for 30 seconds. Task Center retains recent tasks for 10 minutes, while terminal deduplication memory lasts 24 hours.

The snapshot feeds:

- Menu bar status dot
- Main-panel task card
- Task Center
- Notification system
- Sleep-prevention controller

### Why Recent Completion and Termination Have Different Weight

Completion produces a 30-second green menu bar highlight as short positive feedback. Termination appears only in recent records, emits no completion transition, and has no green state.

Task Center retains terminal items for 10 minutes, while keys preventing duplicate completion from late events remain for 24 hours. Display retention and deduplication retention solve different problems and must not be combined into one cache.

### Why Publish Only When the Snapshot Changes

The monitor polls rollout each second and also updates itself at several deadlines. Assigning the same value to `@Published` on every cycle would make SwiftUI and all Combine consumers recalculate unnecessarily.

A candidate snapshot is compared with the current value and published only after structural change. Views format elapsed time from the current clock and do not require per-second mutation of task objects.

### Stable Sorting Tie-Breaker

Several tasks in one batch can share timestamps, and Swift sorting is unstable.

All lists sort by most recent time first and then display UUID string. Stable order keeps SwiftUI diffing from jumping when equivalent tasks randomly exchange positions.

### Cleanup Uses the Nearest Deadline

The monitor manages completion highlight, terminal grace, activity retention, history retention, terminal deduplication, and protection-record expiration.

It does not scan everything on a fixed high-frequency timer. It gathers future deadlines and schedules one `Task` for the nearest. After it fires, it recalculates the next.

This reduces meaningless wakeups for a resident menu bar app and lets every retention period take effect on time even without a new Hook event.

## System Sleep and Wake

Stalled Task Protection pauses when the system is about to sleep. Wake follows a strict recovery order:

1. Enter recovery and keep protection paused
2. Wait for `HookEventTailReader.drainNow()` to succeed
3. Reset rollout-lifecycle parsing fallback
4. Reconcile from the new Hook and rollout results together
5. Resume Stalled Task Protection

If the new read fails, the reader is replaced, or the source is unavailable, evaluation must not continue from the pre-sleep snapshot.

### Why Silence Timing Pauses During System Sleep

Neither Hook nor rollout produces normal progress during system sleep. Comparing wall time alone would classify every running task as stalled immediately after a two-hour sleep.

Protection schedules its next check with `SuspendingClock`, but system-time changes and data-source recovery still require explicit recalculation. `will-sleep` enters recovery first; `did-wake` restores evaluation only through a new data read barrier.

### Why Wake Order Cannot Be Reversed

Rollout reconciliation must occur after a successful Hook drain.

Reading rollout first may find lifecycle data whose task key has not yet been added to the monitor from Hook events written during sleep. Resuming protection first could hide tasks from a pre-sleep last-progress time.

`readerGeneration` prevents a returning wake task from using a reader replaced by a Hook settings change. `recoveryGeneration` prevents an older recovery from unpausing evaluation after two overlapping sleep or settings changes.

## Stalled Task Protection

Stalled Task Protection works only while Prevent System Sleep is enabled and evaluates only non-anonymous `running` tasks.

Tasks waiting for approval are excluded because waiting is a legitimate no-progress state.

Threshold options are:

- 30 minutes
- 1 hour, the default
- 2 hours
- 4 hours

At the threshold:

1. Persist a protection record first
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

### Failure Model Addressed by Protection

After Hook or Codex exits abnormally, `Stop`, `SessionEnd`, and rollout terminal may all be missing. A task can remain running indefinitely and keep sleep prevention active forever.

Protection does not decide whether Codex is “truly stuck.” It handles one observable fact: a non-anonymous running task made no Hook or rollout progress beyond the threshold while sources were trusted.

Waiting tasks are excluded because waiting for the user is legitimate silence. Anonymous tasks are excluded because a project key cannot prove which specific task a persisted record belongs to.

### Purpose of Progress Generation

Timestamps alone cannot protect an asynchronous attempt. Two progress events may share the same second, and the threshold setting may change while notification submission is in flight.

Every valid progress event increments `progressGeneration`. A protection candidate stores:

- Task display ID
- Last-progress timestamp
- Progress generation
- Threshold at the time

All four must still match when notification returns or grace expires. Any new progress or threshold change invalidates the old attempt.

### Why Persist Before Hiding

After a task disappears from the snapshot, the app may immediately exit or the system may sleep. Without a queued persistence write, restart bootstrap could show it again and let it support sleep prevention.

The attempt therefore writes the record first, waits for notification submission, then hides. Failed notification permission or service does not block suppression because releasing erroneous sleep prevention is the protection's core purpose.

### Meaning of the 3-Second Notification Grace

The protection notification is useful explanation but cannot block sleep restoration indefinitely:

- Suppress immediately when notification submission succeeds
- Suppress after 3 seconds if it has not finished
- If notification succeeds later but the attempt is invalid, withdraw it immediately
- New progress within grace cancels the attempt and persisted record

This window constrains the notification side effect only; it does not alter the silence threshold.

### Reconciling Threshold Changes

Shortening the threshold immediately reevaluates running tasks already past it.

Lengthening it silently restores suppressed tasks that no longer exceed the new threshold and clears their records and notifications. Tasks still beyond the new threshold remain suppressed without duplicate alerts.

Turning off Prevent System Sleep disables Activity Protection and restores all suppressed tasks because protection exists to prevent incorrect sleep blocking, not to hide tasks permanently.

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

This does not resist brute force when the session ID is already known. It prevents readable identity from appearing directly in the state file and limits cross-purpose correlation.

### Why Debug and Release Share a Locked File

Both app bundle IDs can run together and observe the same Codex Hook data. With separate protection state, a stalled task hidden by one build might still drive sleep prevention in the other.

The state store uses an actor to serialize within one process and `flock` for cross-process read-modify-write. A removal can include `matchingMarkedAt`, preventing a late delete from an old process from removing a new record just written by another.

Writes sort by task identifier, atomically replace the file, and correct final permissions to `0600`.

## Generation and Old-Result Isolation

The monitor maintains generations for readers and asynchronous recovery:

- Discard late results from a replaced reader
- Publish no transition side effects before bootstrap completes
- A canceled drain does not satisfy a recovery barrier
- Explicitly unhealthy source state cannot reuse the last healthy snapshot for silence evaluation

These constraints prevent false completion alerts and incorrect release during system wake, Hook reinstall, or `CODEX_HOME` change.

### Main Generations in the Monitor

| Generation | Protected asynchronous path |
| --- | --- |
| `tailReaderGeneration` | Reader batch, rollout polling, and prompt backfill |
| `bootstrapCompletionGeneration` | Asynchronous lifecycle completion after repeated bootstrap attempts |
| `activityProtectionRecoveryGeneration` | Sleep, wake, and data-source recovery |
| Task `progressGeneration` | Protection candidate during notification grace |

Each answers a different “is this current?” question and cannot become one global counter. A task making progress without a reader change should invalidate only its protection attempt, not the entire reader.

## Steps to Extend the Task State Machine

1. Classify new input as fact, metadata, progress, or terminal
2. Define whether bootstrap and live input produce the same snapshot and whether either may emit a transition
3. Define degradation when turn or session ID is missing
4. Define how timestamp, terminal memory, or generation rejects late and duplicate input
5. If reading a new rollout field, extend the minimal envelope rather than reading content
6. Keep per-task domain state in `CodexActivityTask` and cross-task association in the monitor
7. Before changing the snapshot, decide whether notifications and sleep prevention should consume the new state
8. Define recovery for system sleep, reader replacement, and unhealthy sources
9. By default, anonymous tasks gain no new high-impact side effect unless identity reliability changes fundamentally

## Suggested Failure-Scenario Tests

- Starting the app while a task is running shows it through bootstrap without replaying notifications
- Bootstrap retries while files continuously append and eventually obtains a stable boundary
- Three unstable attempts enter degraded state without starting silence evaluation
- A new prompt immediately replaces the old turn, and rollout terminal within 5 seconds classifies it correctly
- A `Stop` is not guessed when one session has several terminal candidates
- A missing reviewer enters waiting only after rollout confirms user
- Automatic review never emits a waiting transition
- The UI omits a falsely precise subagent count when association is unreliable
- Calling `drainNow()` during a read forces another new read
- Protection remains paused after a failed wake drain
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

# Data and Privacy Boundaries

[简体中文](../../DeveloperGuide/data-and-privacy.md) | English

## Data Classification Model

Classifying data during development helps determine its storage and propagation scope:

| Class | Examples | Default handling |
| --- | --- | --- |
| Content | Prompts, responses, tool arguments, and output | Do not collect |
| Identity and context | Session IDs, full paths, project names | Minimize use to necessary flows; redact or remove before upload |
| Aggregated metrics | Daily event counts, model counts | May persist locally; upload only specified fields after explicit opt-in |

## Trust Boundaries

```text
Codex hook stdin / rollout / app-server
                  |
                  v
        User-privileged CodexBar
           |                    |
           v                    v
   CloudKit private DB    Constrained XPC interface
                                |
                                v
                       root CodexBarHelper
```

These boundaries mean:

- Codex input files and protocol data are external input; decode failure must not expand into arbitrary file access or command execution
- CloudKit is a user-enabled remote boundary; even a private database may receive only the specified aggregate fields
- The root helper is a privilege-escalation boundary whose capabilities must be narrower than the app's business capabilities
- Debug and Release are separate app identities but intentionally share some local files, requiring process locks and compatible schemas

## Minimize at the Capture Boundary

CodexBar narrows data in this order:

1. The Hook recorder extracts only allowlisted structural fields from stdin
2. The rollout reader uses minimal Codable structures that omit content
3. The aggregator reduces older identity details to counts
4. The sync model projects again into CloudKit-allowed fields
5. Logging records only stages, classifications, and nonsensitive counts

## Data-Flow Overview

| Source | Use in CodexBar | Persisted? | Uploaded to CloudKit? |
| --- | --- | --- | --- |
| app-server account, rate limits, and Reset Credits | Main panel, notification decisions, and user-enabled Automatic Reset | Short-lived state only | No |
| Structured Hook events | Historical aggregation and live tasks | Yes, up to 210 days | Daily aggregations only |
| Rollout lifecycle | Terminal and progress reconciliation | Not persisted separately | No |
| App settings | Feature switches and thresholds | UserDefaults | No |
| Activity Protection | Stalled-task recovery | Hashed identity, up to 24 hours | No |
| CodexBarHelper ownership | System-sleep recovery | Root-owned state file | No |
| Automatic Reset wake schedule | Fixed owner, `wake` type, and next time | System power management | No |

## Local Reads

### Codex app-server

The app launches local `codex app-server --listen stdio://` to obtain account data, rate limits, token usage, Reset Credits details, and Codex configuration. After the user explicitly enables Automatic Reset, it also calls the Reset Credit redemption method through the same stdio session.

CodexBar does not implement account sign-in. Whether app-server accesses OpenAI services follows normal Codex CLI authentication and protocol behavior.

CodexBar communicates with the local process only over stdio and does not copy authentication material from app-server responses. The request log stores normalized complete request and response JSON only in current-process memory. It may contain account responses, opaque credit IDs, and idempotency keys and must not be treated as a redacted summary.

### Hook Events

The Hook subprocess extracts from stdin:

- Time and event type
- Working directory
- Tool, model, and effort
- Permission and reviewer
- Session, turn, and agent identities

The Hook subprocess first extracts and normalizes origin from the first complete `session_meta` record in the rollout referenced by `transcript_path`. When the rollout origin is `unknown`, the model already extracted from stdin classifies the event as `autoReview` only if it exactly equals `codex-auto-review`. The JSONL origin field persists only `main`, `autoReview`, `auxiliary`, or `unknown`; rollout reading uses 32 KiB chunks with a total limit of 256 KiB.

It does not write prompt text, responses, tool arguments, or tool output to CodexBar Hook files.

The working directory is used only to derive a project display name and live-task ownership. Raw Hook JSONL may still include `cwd`, making it sensitive local context subject to retention and file-permission limits. Rollout paths, raw source values, and arbitrary subagent `other` values are not persisted. CloudKit uploads only derived project-name counts and only after explicit opt-in.

### Rollout Files

The Hook recorder reads the current rollout through `transcript_path`, and the live-activity reader also accesses `$CODEX_HOME/sessions` and `$CODEX_HOME/archived_sessions`.

These reads parse only structural fields such as origin classification, lifecycle, time, turn context, progress, effort, and reviewer. They neither copy conversation text into CodexBar storage nor present it in the UI.

The rollout reader scans backward from file tails under a budget. This reduces I/O and limits how much unrelated historical content enters process memory. Parsing DTOs declare only required fields, and `JSONDecoder` ignores everything else.

### Reset Credits Details

`account/rateLimits/read` returns the Reset Credits count and optional details in the app-server response.

- `availableCount` is authoritative for the available total
- `credits == nil` means the server provides a count only
- An empty details array means the server read details but returned no available credit
- The details list may be truncated and its length must not overwrite the total count
- The menu and expiration notifications use only `available` credits with a future `expiresAt`
- Automatic Reset processes only `available + codexRateLimits + expiresAt` details explicitly listed in a fresh response
- Opaque credit IDs and deterministic idempotency keys exist only in current-process memory, including app-server responses and cache, quota snapshots, the Automatic Reset state machine, and the in-memory request log; they are neither persisted nor uploaded
- Automatic Reset notification deduplication keys in UserDefaults contain only a SHA-256 combination of the account and credit ID, never raw values

A rate-limit response from stale cache may remain visible but cannot trigger a new expiration notification or redemption. Automatic Reset settings and scheduling state do not enter CloudKit; Macs converge only through deterministic idempotency keys at the server redemption interface.

## Local Persistence

### App User Directory

```text
~/Library/Application Support/CodexBar/
  HookEvents/
    events/YYYY-MM-DD.jsonl
    daily.jsonl
    maintenance.json
    stats.lock
    Sync/
  ActivityProtection/
    state.json
```

| Path | Contents | Lifetime |
| --- | --- | --- |
| `HookEvents/events` | Raw structured Hook events | 210 days |
| `HookEvents/daily.jsonl` | Daily aggregations | 210 days |
| `HookEvents/maintenance.json` | File cursors, generation, and maintenance state | Continuously updated |
| `HookEvents/Sync` | CloudKit cache and cursor | While sync state remains valid |
| `ActivityProtection/state.json` | Hashed task identities and timestamps | Up to 24 hours after the last progress |

Daily aggregations for the latest 3 days may retain session and turn ID details for exact deduplication. Older data retains counts only.

Anonymous tasks do not create Stalled Task Protection identifiers and therefore never write to `ActivityProtection/state.json`.

### UserDefaults

UserDefaults stores:

- Feature switches and options
- Notification thresholds and sound names
- Global shortcut
- Proxy enabled state, protocol, server, port, authentication username, and password
- Menu bar display selection
- Automatic Reset switch and lead time
- Bounded notification deduplication keys
- Runtime configuration such as the CodexBarHelper fingerprint

Changes to persistence keys, data structures, enum raw values, or defaults for missing values require an agreed migration and downgrade strategy before implementation.

The `CodexProxy.configuration` key stores one JSON data value containing `configuration` and `password`. Passwords are stored in plain text in local UserDefaults and removed when settings are saved with authentication disabled or the configuration is cleared. Debug and Release use separate preference domains:

- Debug: `~/Library/Preferences/app.zabrian.codexbar.debug.plist`
- Release: `~/Library/Preferences/app.zabrian.codexbar.plist`

`CodexProxyStore` distinguishes a missing record from a decoding failure. A failed record remains available for the configuration dialog’s clear action.

### CodexBarHelper Directory

```text
/Library/Application Support/CodexBar/helper-state.json
```

The file stores only the recovery transaction describing whether CodexBarHelper owns `SleepDisabled`. It contains no Codex task, account, or Hook data.

System power management stores the Automatic Reset wake schedule, which contains only a fixed CodexBar owner, `wake` type, and next time. The helper neither receives nor stores account data, `creditId`, idempotency keys, or network data.

The directory and file are root-managed. See [Sleep Prevention System](sleep-prevention.md) for permissions and recovery.

## In-Memory and System Logs

The in-app [`RequestLog.swift`](../../../CodexBar/Services/CodexStatus/RequestLog.swift) is an in-memory ring buffer of at most 500 entries and disappears when the process exits.

It diagnoses the app-server protocol. Even in memory, it must not contain OAuth tokens or Hook content.

The unified logging subsystem is `app.zabrian.codexbar`, with a `.debug` suffix in Debug builds.

System logs may contain only:

- Operation stage and result
- State classification
- Nonsensitive counts
- Errors that identify a module

System logs must not contain:

- OAuth tokens
- Prompts, responses, or tool content
- Session, turn, or agent IDs
- Full project paths or sensitive project names
- Account rate-limit or token-usage details

Fixed `CodexProxyError` messages go to the `settings` system-log category without configuration values. Before app-server responses enter the app interaction log, JSON escapes are decoded and HTTP/HTTPS URL credentials in string values are redacted. Other account and protocol fields retain the existing request-log behavior.

## Network Access

| Destination | Purpose | Trigger |
| --- | --- | --- |
| CloudKit private database | Sync daily Hook aggregations | User explicitly enables sync |
| Codex service, through the app-server subprocess | Authentication, rate limits, usage, and Reset Credit consumption | Regular refreshes, proxy tests, or Automatic Reset |
| Sparkle appcast and update resources | Check for or install updates | Automatic check or manual user request |

Account data, rate limits, token usage, Reset Credits details, and explicitly enabled Reset Credit redemption use local app-server stdio. CodexBar does not add a separate HTTP client for Automatic Reset.

CodexBarHelper performs no network access.

When a proxy is enabled, its address and optional credentials are passed through environment variables to app-server processes started by CodexBar. This does not configure system networking, Sparkle, CloudKit, or other Codex processes. Connection tests use a temporary app-server, close it afterward, and do not write app interaction logs.

## CloudKit Boundary

CloudKit uploads only daily aggregate fields:

- Device pseudonym
- Date and source generation
- Hook event counts
- Session and turn counts
- Project display-name counts
- Model counts
- Update time

CloudKit does not upload:

- Raw Hook JSONL
- Session, turn, or agent IDs
- Full working directories
- Prompts, responses, tool arguments, or output
- Codex account, rate-limit, or token usage data
- Reset Credits details, Automatic Reset settings, or redemption state
- Access tokens
- App request logs
- Activity Protection state
- Proxy settings and passwords

A project display name may derive from a directory name and still contain sensitive information. Sync must remain an explicit user choice.

## Root Helper Data Isolation

CodexBarHelper needs only four kinds of state:

- Which verified client holds which lease generation
- The currently measured `SleepDisabled` value
- Whether CodexBar owns restoration responsibility
- A bounded Unix timestamp for the Automatic Reset wake schedule and the current connection owner

It does not need task IDs, project names, Hook paths, account state, `creditId`, or complete user settings. XPC carries only Boolean requests, client session ID, generation, update identifier, and a bounded Unix timestamp.

The helper target contains restricted power operations and the shared XPC protocol; it does not link the app’s business services.

The helper ownership file is a crash-recovery transaction record, not a user preference. It must be root-owned, reject group- or world-writable directories, and use full sync plus atomic rename so a restart can decide whether restoration is required.

## File Security

- Hook subprocesses and the app aggregator coordinate writes with `flock`
- JSONL appends complete lines only
- Aggregation and state files use recoverable write workflows
- Activity Protection files have `0600` permissions
- CodexBarHelper state commits with root ownership, permission checks, full sync, and atomic rename
- Data shared by Debug and Release uses locking and compatible schemas

## Checklist Before Adding a Data Field

1. State the product goal and the behavior that is impossible without the field
2. Classify it as credential, content, identity context, or aggregate metric
3. Define its capture boundary and the earliest layer that can discard the raw value
4. Define whether and where it exists in memory, UserDefaults, Application Support, system logs, and CloudKit
5. Define retention, deletion triggers, and cleanup after failure
6. Check whether Debug and Release share its file or identity
7. Distinguish missing from explicitly empty values
8. Check whether logs or error objects copy the raw value indirectly
9. If it affects CloudKit, network access, or logs, update the privacy explanation and obtain an explicit product decision first
10. If it affects a schema or old-version coexistence, agree on compatibility before changing code

## Suggested Privacy-Failure Tests

- Run a task with a conspicuous marker in the prompt and tool arguments; confirm the marker is absent from Hook JSONL, app logs, and CloudKit cache
- Put a sensitive test term in a project directory name; confirm it appears only in allowed local presentation and opt-in aggregate fields
- Simulate a failed Reset Credits request and confirm that access tokens do not enter the in-memory or unified logs
- Confirm CloudKit records contain no session, turn, or agent IDs or full paths
- As a non-root user, verify that the helper-state directory is not writable
- Corrupt each cache type and confirm the system degrades or rebuilds rather than broadening fallback data collection

## Key Source Files

- [`WorkflowHookEventRecorder.swift`](../../../CodexBar/Services/Workflow/WorkflowHookEventRecorder.swift)
- [`WorkflowService.swift`](../../../CodexBar/Services/Workflow/WorkflowService.swift)
- [`CodexSessionLifecycleReader.swift`](../../../CodexBar/Services/Workflow/CodexSessionLifecycleReader.swift)
- [`WorkflowSyncService.swift`](../../../CodexBar/Services/Workflow/WorkflowSyncService.swift)
- [`ActivityProtectionStateStore.swift`](../../../CodexBar/Services/Workflow/ActivityProtectionStateStore.swift)
- [`RequestLog.swift`](../../../CodexBar/Services/CodexStatus/RequestLog.swift)
- [`CodexBarHelper/main.swift`](../../../CodexBarHelper/main.swift)

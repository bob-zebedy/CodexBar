# app-server Data Flow

[简体中文](../../DeveloperGuide/app-server.md) | English

## Responsibilities

The app-server flow reads Codex account and server state:

- Current account and plan
- Rate-limit groups and windows returned by Codex
- Token usage and usage history
- Reset Credits state
- Hook feature flags, handler lists, and configuration-write capabilities

It does not own historical Hook metrics or live task state.

### Input and Output Boundaries

```text
CodexCLIResolver
  -> AppServerCommand
  -> CodexStatusService actor
      -> AppServerSession
          -> Process + stdin/stdout/stderr
      -> CodexQuotaSnapshot
  -> CodexStatusViewModel
  -> Menu bar and main panel
```

`CodexStatusService` owns the connection and same-account cache. `CodexStatusViewModel` owns only UI loading state, automatic-refresh timing, and the latest connection information.

Settings reuses this session for Hook and TUI configuration.

## Locating Codex CLI

[`CodexCLIResolver.swift`](../../../CodexBar/Services/CodexCLI/CodexCLIResolver.swift) first searches the process `PATH` for global `codex`, then checks bundled paths:

```text
/Applications/ChatGPT.app/Contents/Resources/codex
/Applications/Codex.app/Contents/Resources/codex
```

A menu bar app launched from Finder may lack the complete `PATH` of an interactive shell, so the resolver also adds common installation directories:

```text
/opt/homebrew/bin
/usr/local/bin
~/.npm-global/bin
~/.local/bin
~/.volta/bin
/usr/bin
/bin
/usr/sbin
/sbin
```

The data directory uses `CODEX_HOME` when set and otherwise uses `~/.codex` under the real user's home directory.

### Process Environment Normalization

An `LSUIElement` app launched from Finder or Login Items usually lacks the complete `PATH` injected by an interactive shell. Calling only `/usr/bin/env codex` would make Homebrew, Volta, or global npm installations work in Terminal but disappear from CodexBar.

The resolver normalizes in three layers:

1. Resolve the real login user's home with `getpwuid(getuid())`, avoiding an incorrect `HOME` inherited from Xcode or a container
2. Preserve the existing `PATH`, then append common directories in order and deduplicate
3. Resolve symlinks and standardized URLs for candidates so one bundled binary is not identified as both global and bundled

`CodexCLISourceSelection.automatic` prefers the global CLI and falls back to the bundled CLI when none is found. Selecting `global` or `bundled` uses only that source and returns `sourceUnavailable` if it is missing. `CodexStatusService` saves the selection and reuses it when rebuilding the connection.

### Disk and Running Versions

Settings may read versions from both CLI candidates on disk, but minimum-version checks for the primary flow and Hook use only the app-server `userAgent` returned by `initialize`.

A connection may be reused for up to 1 hour. If the user upgrades the on-disk binary while it remains alive, the current process is still the old version. Checking the disk value would let the UI claim a capability is available while the running app-server does not support its method.

## In-App Proxy

The proxy is implemented by four types:

| Type | Responsibility |
| --- | --- |
| [`CodexProxyConfiguration`](../../../CodexBar/Models/CodexProxyConfiguration.swift) | HTTP/HTTPS settings, input validation, and child-process environment |
| [`CodexProxyStore`](../../../CodexBar/Services/Settings/CodexProxyStore.swift) | Settings and password stored under `CodexProxy.configuration` in UserDefaults |
| [`CodexProxySettings`](../../../CodexBar/Services/Settings/CodexProxySettings.swift) | Saved configuration, editing draft, toggle commits, and test state |
| [`CodexProxyConnectionTester`](../../../CodexBar/Services/CodexStatus/CodexProxyConnectionTester.swift) | Independent test process using the draft |

Without an enabled configuration, the regular connection uses `CodexCLIResolver.environment`. Enabling a proxy sets `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `WS_PROXY`, `WSS_PROXY`, and their lowercase forms. `NO_PROXY` and `no_proxy` become `localhost,127.0.0.1,::1`. Only custom-proxy processes append `-c features.respect_system_proxy=false`; the configuration is not written to global Codex files.

Loading preserves decodable raw input. Enabling the proxy and saving an edited form validate the server, port, and authentication username; disabling it permits invalid fields to remain stored. Undecodable records still have a clear action.

The toggle updates its displayed state and sets `isSaving` before creating the asynchronous task; repeated toggles are ignored while it runs. `CodexStatusService.applyProxy` serially saves settings, closes the old connection, and clears supplemental caches. Completion restores interaction and triggers a refresh; failure restores the previous toggle state. The dialog edits a separate draft, committed only by Save or Clear.

### Connection Tests

Testing temporarily enables the draft, resolves the selected Codex source, and calls `AppServerSession.initializeAccount()` for the same handshake and account checks used by regular connections. It then calls `account/rateLimits/read`. Regular connections continue with rate limits and usage after the handshake.

Test requests share an eight-second deadline, do not retry server business errors, and do not record interaction logs. The temporary process is closed on exit using the session’s shutdown wait budget. Editing fields, canceling a test, or closing the dialog cancels both the outer task and its worker; canceled results cannot update the UI.

## Process and Protocol

CodexBar launches this command and communicates over stdio:

```bash
codex app-server --listen stdio://
```

The protocol is line-delimited JSON-RPC. A connection sends `initialize`, then `initialized`, then reads the account:

```text
Start subprocess
  -> initialize(clientInfo)
  -> Validate actual version >= 0.143.0
  -> initialized
  -> account/read
  -> account/rateLimits/read
  -> account/usage/read
```

stdout may contain non-JSON output. The pipe reader continuously reads complete lines and forwards only messages that decode and match the response ID of a pending request. stderr is drained separately so the subprocess cannot block on a full pipe.

### Complete Connection Transaction

```text
Resolve executable
  -> Create stdin/stdout/stderr pipes
  -> Start Process
  -> initialize(clientInfo)
  -> Save actual version from userAgent
  -> Validate actual version >= 0.143.0
  -> initialized notification
  -> account/read(refreshToken: false)
  -> Account exists: commit connection
  -> Account missing: close process and return notLoggedIn
```

A connection enters service state only after the actual version passes the global threshold and both handshake and first account read succeed. A version below `0.143.0` or an unparseable version is treated as unsupported; the half-initialized session closes without further account requests.

### Stdout Framing and Response Matching

app-server frames one JSON message per line. A `Data` block delivered to the pipe callback may:

- Contain half a line
- Contain several lines
- Mix ordinary logs between JSON lines
- End with an unterminated final line when the process exits

`PipeReadBuffer` maintains a byte buffer, emits nonempty newline-delimited lines during reading, and flushes a nonempty trailing fragment at EOF or when stopped. The session first decodes the response ID and fully decodes the result or error only for a matching ID.

This avoids treating logs as protocol errors and fully decodes a large response only once.

### Stderr Draining

Even though CodexBar does not display stderr content, it must drain the pipe. A subprocess pipe buffer is finite; if the parent never reads stderr, app-server eventually blocks while writing and no later stdout response can arrive.

`PipeDrain` does not parse content; it continuously drains stderr.

### Shutdown Strategy

A session shuts down in this order:

1. Stop stdout and stderr readers
2. Close the stdin writer
3. Send `SIGTERM` if the process is still running and wait up to 1 second
4. If still running, send `SIGKILL` and wait another 0.5 seconds
5. Record a diagnostic error if it remains alive

Writing after an early process exit may raise `SIGPIPE`. The service ignores that signal during initialization so the write returns a Swift error and follows the transport-rebuild path instead of terminating the entire menu bar app.

## API Surface

| Method | Purpose |
| --- | --- |
| `account/read` | Read account, plan, and authentication state |
| `account/rateLimits/read` | Read rate-limit windows |
| `account/rateLimitResetCredit/consume` | Use a specified Reset Credit |
| `account/usage/read` | Read tokens and usage history |
| `config/read` | Read Codex configuration |
| `hooks/list` | Validate Hook source and event capabilities |
| `config/batchWrite` | Change Hook or TUI notification configuration |

Each session caches unsupported methods. After app-server explicitly returns method unsupported, that connection does not request the method again.

### Session Capability Cache

Method unsupported usually means the running app-server lacks a capability. Calling it again every minute only adds logs and latency.

The conclusion must not persist to UserDefaults, however, because a new connection may come from an upgraded binary. The unsupported set belongs only to `AppServerSession` and is probed again after reconstruction.

## Session Lifecycle

[`CodexStatusService.swift`](../../../CodexBar/Services/CodexStatus/CodexStatusService.swift) is an actor that owns the connection and refresh state:

- One request times out after 20 seconds
- Connection age is checked on requests; a connection aged 1 hour is rebuilt
- A business error retries at most once in the same session
- A transport failure rebuilds the connection at most once
- When authentication requires refresh, `account/read` retries with `refreshToken = true` at most once
- Closing or releasing a connection terminates its subprocess; a request that encounters a closed reader reports a connection error

Business and transport errors are separate. The former may be a temporary failure of one method; the latter makes the current stdio session untrustworthy.

### Connection State Machine

```text
no connection
  -> resolve CLI
  -> open and initialize
  -> ready

ready
  -> age < 1h and process alive: reuse
  -> process exited: close and rebuild
  -> age >= 1h: close and rebuild
  -> transport failure: close and rebuild once
  -> account missing after refresh: close and notLoggedIn
```

One hour is the reuse limit checked at request time. The next request after that limit rebuilds the connection using the Codex binary then on disk; no independent timer destroys the connection.

Manual reconnection, source changes, and expired-connection rebuilding all close the old connection first; a failed replacement leaves the app disconnected. Source selection is saved only after successful manual reconnection. Automatic refresh and manual reconnect errors both update `CodexStatusViewModel.connectionErrorMessage`, which About displays.

### Error Classification Matrix

| Error | Current request | Current connection | Full refresh |
| --- | --- | --- | --- |
| Retriable server error | Retry the same method once | Preserve | Continue from second result |
| Method unsupported | Mark unsupported for this session | Preserve | Corresponding field is missing |
| Ordinary business failure | Do not retry | Preserve | Same-account cache may degrade |
| Authentication required | Refresh the token once for the cycle, then retry | Preserve or become signed out | At most one refresh overall |
| Timeout, pipe close, invalid transport | Fail | Discard immediately | Rebuild once only when reusing a connection |

Limiting reconstructions prevents a fault from repeatedly launching subprocesses. The next normal timed refresh still gets a new attempt after the current cycle ends.

### Authentication Refresh Budget

One refresh reads account, rate limits, and usage; Reset Credits details are included in the rate-limit response. Several interfaces may detect an expired token in the same cycle.

`fetchData` uses one `didRefresh` latch for the entire cycle. The first authentication failure triggers `account/read(refreshToken: true)`, and later methods reuse that result. A second authentication requirement is classified as signed out.

## Refresh Model

The status view model refreshes every 60 seconds by default. Users can double-click the account icon in the main panel to request an immediate refresh.

Each refresh resolves the account first, then reads rate limits and usage. Supplemental caches are strictly bound to account identity:

- If the account is unchanged and a supplemental request fails, cached values may remain visible
- If the account changes, the old-account cache is cleared immediately
- An explicitly unsupported method appears as a missing source
- A missing source must not become the business value `0`

Ordinary refresh triggers are ignored during a refresh or reconnect. Operations requiring a follow-up use `refreshAfterCurrent` to retain one pending trigger until the current request ends; the coordinator handles cancellation and stale-result checks.

### Building One Snapshot

```text
Confirm or create connection
  -> On reuse, account/read
  -> Confirm account identity
  -> account/rateLimits/read (including Reset Credits details)
  -> account/usage/read
  -> Build CodexQuotaSnapshot
  -> Commit loadState and connection info on MainActor
```

Rate limits and usage are supplemental. As long as the account is valid, CodexBar still creates a snapshot when both interfaces return no data so the UI can show the account and an explicit “No Data.”

### Cache Decision Table

| Current result | Same-account cache | Output | stale |
| --- | --- | --- | --- |
| Success | Any | New value and cache update | `false` |
| Ordinary request failure | Yes | Cached value | `true` |
| Ordinary request failure | No | `nil` | Not applicable |
| Method unsupported | Any | `nil` | Not applicable |
| Account changed | Old-account cache | Clear all first | Not applicable |

Method unsupported does not use old cache because it is an explicit capability result. Ordinary failure does because the source may be transiently unavailable for one cycle.

### How Stale State Affects Consumers

- The UI may display old values but reduces menu bar and progress-bar opacity
- `hasTrustedData` counts only non-stale rate-limit or usage data as trusted
- Rate-limit notifications skip stale rate limits entirely
- System logs record only a `cached` step, never actual rate-limit values

Stale is part of data confidence. A new presentation must not copy the value while dropping the marker.

### Refresh Generation Checks

An `isRefreshing` guard prevents ordinary duplicate triggers, but cancellation and object lifecycle may still let an old `Task` return.

`RefreshTaskCoordinator` advances its generation at each start, cancels the old task, and allows only a result satisfying `canCommit(generation)` to update UI. “Last requested refresh wins” becomes an explicit rule.

Automatic refresh waits for the remaining interval since the last completion. After a manual refresh, the countdown realigns naturally rather than letting the old timer refresh again a few seconds later.

### Data Models and Display Projection

`CodexUsageSnapshot` aggregates potentially repeated daily buckets into `tokensByDate` during initialization.

A heatmap queries dates repeatedly during one render. Building an optional index up front avoids a linear scan for every cell and limits snapshot equality to summary metrics, daily-data availability, and aggregated daily tokens. Raw bucket ordering or partitioning does not affect the rendered result or independently trigger animation.

The `summary` object from `account/usage/read` is required, but every summary metric and `dailyUsageBuckets` may be absent or null. The model preserves those states: a missing summary metric renders as `--`; `dailyUsageBuckets == nil` means daily data is unavailable, while an empty array means the read succeeded with no records. A valid partial response is not filled from older values. A business payload decoding failure is handled as a supplemental-read failure without rebuilding the app-server session or clearing rate-limit data.

Rate-limit ordering is also centralized in the model:

- The primary limit referenced by the top-level app-server `rateLimits` comes first
- Remaining limits use a stable sort by localized name and limit ID
- Stable enums distinguish primary and secondary; views do not infer window type from label strings

## Reset Credits

The UI labels the available count “Banked Resets” or “留存重置”, using the localization key `banked-reset.count`. The protocol field remains `rateLimitResetCredits`.

`rateLimitResetCredits` from `account/rateLimits/read` provides both an available count and optional details:

- `availableCount` is the authoritative total
- `credits == nil` means only the count is known
- An empty array means the server obtained details but returned no available credit
- The server may truncate details, so their length can be less than `availableCount`
- Each detail includes an opaque `id`, `status`, and optional Unix-seconds `expiresAt`
- Each detail also includes `resetType`; Automatic Reset accepts only `codexRateLimits`

The model retains expiration dates only for entries with `status == available` and a time later than snapshot creation, then sorts them by time. The count still comes independently from `availableCount` and cannot be inferred from filtered dates.

Expiration details are supplemental. With `credits == nil`, the main panel still shows the available count and details show an unknown expiration time without affecting rate limits or usage. When rate-limit data comes from same-account cache, the UI may display old details, but notifications never use stale data for new expiration alerts.

### Automatic Reset

After the user explicitly enables Automatic Reset, [`AutoResetController.swift`](../../../CodexBar/Services/CodexStatus/AutoResetController.swift) processes only credit details explicitly returned by the latest `account/rateLimits/read`:

- It never calls consume for a stale snapshot, `credits == nil`, missing `expiresAt`, non-`available` state, or a `resetType` other than `codexRateLimits`
- Details may be truncated; it processes only returned credits and never guesses unlisted `creditId` values from `availableCount`
- It selects only the earliest-expiring returned credit at a time, then selects the next after completion or disappearance
- After entering the user-selected lead-time window, it forces another account and credit read before redemption
- The request always passes an explicit `creditId`; the backend never chooses implicitly
- It reads rate limits again immediately after a redemption result
- `reset`, `alreadyRedeemed`, and `noCredit` request a full rate-limit refresh; `nothingToReset` schedules another attempt if the target remains, otherwise it requests a full refresh

The call has this shape:

```text
account/rateLimitResetCredit/consume
  creditId: <exact opaque id>
  idempotencyKey: <deterministic UUIDv5>
```

Results have these semantics:

| `outcome` | Conclusion | Next action |
| --- | --- | --- |
| `reset` | This call redeemed the credit | Success notification, rate-limit refresh, stop retrying this credit |
| `alreadyRedeemed` | The same idempotency key redeemed it previously | Treat like `reset` and as success |
| `nothingToReset` | No rate-limit window can currently be reset | Credit remains unredeemed; retry with the same idempotency key |
| `noCredit` | The account currently has no available credit | Force refresh; stop silently if the target disappears, otherwise retry as temporary inconsistency |

`alreadyRedeemed` confirms that the same logical request previously succeeded. It stops retries and sends a local success notification according to notification settings.

### Cross-Device Idempotency Contract

The same Codex account may run CodexBar on several Macs. Devices do not coordinate through CloudKit. They calculate the exact same UUIDv5 for the same `creditId`:

```text
namespace = c2904ab3-0a87-5648-997d-bd8515edd401
name      = raw UTF-8 bytes of creditId
output    = lowercase UUID string
```

The namespace is UUIDv5 of the URL namespace and `https://codexbar.zabrian.app/idempotency/auto-reset/v1`. This URL determines the namespace only and does not represent a runtime network request.

The fixed test vector is:

```text
creditId       = RateLimitResetCredit_123
idempotencyKey = 4035685d-9ca4-524f-8193-6e0ae2a7b3b9
```

The namespace, UUID version, raw UTF-8 input, and lowercase output form a cross-version compatibility protocol and must not change in an ordinary refactor. The first successful device redeems the credit; other devices calling with the same key receive `alreadyRedeemed` or discover during preread that the credit disappeared.

Disappearance cannot distinguish manual use, use by another device, or server expiration. The local task therefore stops without an Automatic Reset success notification. Only a device that explicitly receives `reset` or `alreadyRedeemed` sends one.

### Scheduling and Retry

The Automatic Reset state machine and network requests remain in the regular app process. CodexBarHelper owns only a constrained system wake schedule:

- Enabling the feature reuses existing CodexBarHelper registration and approval without depending on Prevent System Sleep
- The app submits only the nearest threshold or retry time; the helper replaces only CodexBar's own event with a fixed owner and `wake` type and accepts no arbitrary event type
- After setting or canceling, the helper reads back system events and reports success only if exactly one target-time event exists or the event is confirmed absent
- After a timer or wake, the app holds `PreventUserIdleSystemSleep` only during fresh reads and redemption; it does not keep the display awake or change `SleepDisabled`
- A task change, feature disable, app exit, or corresponding XPC disconnect cancels CodexBar's wake event
- On startup, the helper removes stale events for its fixed owner before accepting connections; if cancellation fails, it abandons the invalid connection owner and retries internally
- Normal app exit waits for cancellation read-back; a forced exit or XPC disconnect makes the helper cancel immediately, while a sudden-power-loss event converges at next helper startup, after which the app reschedules from fresh details
- On app launch, feature enable, or system wake, the app performs a fresh read first; it attempts immediately if the credit is inside its lead-time window and unexpired, otherwise it schedules for that window
- The app does not persist raw `creditId` after exit; next launch rebuilds tasks and the same deterministic idempotency key from fresh details
- When `expiresAt` changes for the same `creditId`, it preserves idempotent identity but cancels the current threshold or retry and reschedules; if the new lead-time point has passed, it rechecks immediately
- A retry wake event requires a known `creditId + expiresAt`; a count-only or failed read never wakes the Mac merely to query again
- Network, timeout, disconnect, or temporary service errors use `15s, 30s, 1m, 2m, 5m` backoff but never schedule a retry at or after the current 5-minute deadline
- At round timeout, local work and the system wake event are canceled without marking the target failed; a later normal rate-limit refresh may start a new round for it
- `nothingToReset` waits a fixed 60 seconds when expiration is less than 10 minutes away and the round remains active; otherwise it uses general backoff
- Authentication failure first uses the service's single token refresh; if still unsuccessful, it pauses the current credit and notifies according to settings, then resumes after a trusted snapshot proves recovery
- Parameter, protocol, or method errors stop the current credit without meaningless retries

When Automatic Reset requests a full rate-limit refresh while an ordinary refresh is in progress, the new refresh queues behind it and must not be dropped by the `isRefreshing` guard.

## Hook Version and Configuration Validation

Hook settings reuse the app-server flow but maintain independent availability state:

- `isEnabled` tracks enabled state for the current process, initially restored from an existing handler; configuration lost during runtime triggers repair
- `isVerified` defaults to `true`, then retains the latest explicit validation result
- `isOperable` is true only when both are `true`
- A transient RPC failure preserves the last explicit validation result

Enabling or validating Hook requires the actual app-server version to be at least `0.145.0`.

See [Hook Capture and Historical Aggregation](hook-and-aggregation.md) for the full configuration flow.

### Timing of the Actual-Version Check

Enabling or validating Hook calls `readyConnectionInfo()`:

- If no connection exists, it establishes one first
- If a connection exists, it reuses the actual current process
- It parses the running version from the handshake user agent
- An unparseable version is treated as unsupported rather than allowed optimistically

## Request Logs

[`RequestLog.swift`](../../../CodexBar/Services/CodexStatus/RequestLog.swift) keeps the latest 500 request records in memory for the in-app Logs window.

It helps inspect process startup, JSON-RPC methods, retries, and error classifications. It must not contain access tokens or Hook prompt content.

`CodexProxyError` configuration failures go to the `settings` category in system logs without creating app-server request-log entries. Before RPC responses and errors enter the interaction log, JSON escapes are decoded and string values are traversed to redact HTTP/HTTPS URL credentials. Non-JSON messages use text redaction.

### Request and System Logs

Unified system logs retain only control-flow classifications and support long-term diagnosis of whether refresh ran and which stage failed.

The in-app `RequestLog` keeps previews of at most 500 request interactions in current-process memory for user-initiated protocol inspection.

Reset Credits details include opaque credit IDs. Unified logs must not record IDs or raw responses; the in-app request log remains current-process-only under its existing rules. Before logging a new RPC, check whether its payload can contain credentials or content fields.

## Suggested Failure-Scenario Tests

- A Finder launch still finds Codex installed by Homebrew, npm, or Volta
- When the global CLI is absent, fallback correctly uses the binary bundled with ChatGPT App or Codex App
- Ordinary text mixed into stdout does not prevent matching the correct response ID
- Continuous stderr output does not stall requests through pipe backpressure
- A transport failure on a reused connection rebuilds only once
- After an on-disk CLI upgrade, the current connection version remains distinct from the disk version
- app-server below `0.143.0` blocks the primary account flow and asks for an upgrade
- app-server `0.143.x` or `0.144.x` supports the primary account flow while Hook still requires `0.145.0`
- app-server `0.145.0` or later supports both the account flow and Hook validation
- A failed rate-limit read with same-account cache displays stale data without triggering notifications
- An account switch clears old rate-limit and usage data immediately
- An unsupported method is not retried every minute
- Reset Credits with `credits == nil` preserve the authoritative count and show unknown expiration
- Empty or truncated Reset Credits details do not redefine the available count from array length
- Expired or non-available Reset Credits do not enter details or notifications
- Stale rate limits may show old details but do not trigger expiration notifications
- Automatic Reset does not call consume while off; a missing setting defaults off and lead time defaults to 30 minutes
- Automatic Reset does not consume stale, detail-less, expiration-less, or unlisted credits
- Two devices derive the same idempotency key for a fixed `creditId`, matching the fixed test vector
- Changing expiration earlier or later for the same `creditId` reschedules while preserving the idempotency key
- Both `reset` and `alreadyRedeemed` stop retries and send success notifications
- `nothingToReset` retains the credit and retries under backoff
- With sleep prevention off, the helper can still register and receive approval, and a future threshold writes a fixed-owner `wake` event
- A scheduled time during system sleep wakes the Mac and triggers a reread; natural wake and app launch run the same catch-up check
- Disabling the feature, changing the target, or quitting cancels the wake event without affecting other apps' scheduled events
- Count-only or failed reads with no specific target do not schedule a query-retry wake event
- A known target stops continuous retries 5 minutes after the near-expiration trigger; a later normal refresh may start a new round
- A full rate-limit refresh after redemption is not dropped behind a concurrent ordinary refresh
- The 60-second countdown realigns after manual refresh

Proxy checks also cover disabling invalid settings, clearing corrupt records, isolating canceled test results, submitting only once during rapid toggles, rolling back failed commits, and redacting credentials in plain and JSON-escaped URLs.

## Key Source Files

- [`CodexCLIResolver.swift`](../../../CodexBar/Services/CodexCLI/CodexCLIResolver.swift)
- [`AppServerSession.swift`](../../../CodexBar/Services/CodexStatus/AppServerSession.swift)
- [`AppServerPipeReaders.swift`](../../../CodexBar/Services/CodexStatus/AppServerPipeReaders.swift)
- [`CodexStatusService.swift`](../../../CodexBar/Services/CodexStatus/CodexStatusService.swift)
- [`CodexStatusViewModel.swift`](../../../CodexBar/Services/CodexStatus/CodexStatusViewModel.swift)
- [`AutoResetController.swift`](../../../CodexBar/Services/CodexStatus/AutoResetController.swift)
- [`AutoResetIdentity.swift`](../../../CodexBar/Services/CodexStatus/AutoResetIdentity.swift)
- [`AutoResetWakeScheduler.swift`](../../../CodexBar/Services/KeepAlive/AutoResetWakeScheduler.swift)
- [`CodexBarHelperXPC.swift`](../../../Shared/CodexBarHelperXPC.swift)

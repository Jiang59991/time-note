# Time Note 1.0 implementation contract

This is the current delivery architecture: native AppKit + bundled WKWebView interface, no server or runtime dependency. This replaces the earlier unimplemented SwiftUI/SwiftData UI plan for the first usable release. Keep the existing pure Swift core package and prototype as reference. Native actor is the sole writer, with versioned atomic JSON, backup, and exclusive single-process file lock. Times below are epoch milliseconds; UI uses the user's local timezone and Calendar day boundaries (never fixed UTC+8 or 24h assumptions).

## Frontend to native

`await window.webkit.messageHandlers.timeNote.postMessage(payload)` resolves a JSON object. Only bundled main-frame messages are accepted. On failure reject with user-readable error; never claim a mutation saved before successful reply.

- `{action:'load'}` -> Snapshot
- `{action:'command', command: Command}` -> Snapshot
- `{action:'view', view:'day'|'week'|'record'}` -> `{ok:true}` (native remembers per-view sizes)
- `{action:'settings'}` opens native preferences/menu help -> `{ok:true}`
- `{action:'export', format:'json'|'csv'|'markdown'}` -> `{ok:true,cancelled?:true}` (native SavePanel; JSON is complete backup)
- `{action:'import'}` opens native OpenPanel with validation + replacement confirmation -> Snapshot or `{cancelled:true}`
- `{action:'notifications'}` requests permission and syncs schedules -> `{status:string}`

Native pushes committed snapshots via `window.timeNote.receiveSnapshot(snapshot)` and exposes menu focus entry via `window.timeNote.openRecord()`; both functions must exist when page is ready. Snapshots are applied only if revision >= current. Native polling/reconcile once per second or lifecycle resume handles due timers; web tick only renders current wall time. Startup uses real current date, no demo data, demo clock, or test global. Frontend may save unsubmitted form drafts in localStorage (optional), never canonical records.

## Snapshot

```
{schemaVersion:1, revision:0, records:[], todos:{}, categoryMemory:{}, now:1730000000000}
```
`now` is generated at response, not persisted truth. categories keys and order: work 科研, create 自媒体, move 运动, rest 娱乐, sleep 睡眠, dining 餐饮, life 杂事, other 其他.

Record:
```
{id:UUID, runID:UUID|null, title:string, category:key, categoryManual:bool,
 start:epochMS, end:epochMS|null, mode:'countup'|'pomodoro', minutes:integer,
 deadline:epochMS|null, revision:integer, finishReason:string|null}
```
Every timer start has its own runID and record id; manual history has null runID. End null means running. Only a timer can be running. UUIDs are native generated. Pomodoro minutes 1...240. Duration is end-start; active pomodoro capped at deadline, ordinary at current time. Date is only presentation.

Todo is `{id:UUID,title:string,done:bool,revision:integer}` stored under YYYY-MM-DD date keys; separate from timer facts. Native reconciliation moves all unfinished Todos from earlier local Gregorian calendar dates to today (oldest date first, ahead of today’s existing items), preserving IDs and incrementing item revisions. Completed Todos stay on their original date and do not carry over; future Todos stay scheduled. Snapshot/load, lifecycle polling, commands and backup import all reconcile, including after multiple days offline. Repeated reconciliation does not duplicate items. Stale commands targeting the previous day are rejected; refresh before retrying. categoryMemory maps exact normalized trimmed titles to a user-selected category. Editing with categoryManual=true updates that mapping; automatic recognition never overrides explicit choice. Null/unknown categories cannot create an ninth category.

## Commands

Every command includes `{operationID: UUID, type: string}`. A repeated identical operationID must not repeat a mutation; different content with the same ID is an error. All target mutation commands use expectedRevision to reject stale UI.

- `start`: title, category, categoryManual, mode, minutes. Native sets start=now, end=null, own IDs and deadline.
- `manual`: title, category, categoryManual, start, end. Both finite; end>start and <= now.
- `edit`: id, expectedRevision, title, category, categoryManual, start, end (null allowed only for currently running), minutes, completionIntent (`preserve` | `finish` | `deadline`). Recompute active pomodoro deadline=start+minutes*60000. If the newly recomputed deadline has passed and no explicit manual end is supplied, require intent deadline and persist end=deadline. An explicit intent finish with a valid end is a manual historical correction and may end at that time even if the newly recomputed deadline is past; it never keeps the run alive. If original deadline already elapsed, reconcile original first and return conflict; never revive it. Explicit end requires finish. Completed record stays completed and cannot be cleared to running. Metadata-only edits preserve exact timestamps.
- `finish`: id, expectedRevision, optional end. Default end=now, expiry always original deadline. Only target run affected.
- `delete`: id, expectedRevision. Remove record atomically; schedule sync removes its notification. UI confirm for this destructive operation, especially active run. Prior full store backup keeps recovery copy.
- `todoAdd`: day, title
- `todoSet`: day, id, expectedRevision, done (set, not toggle)
- `todoDelete`: day, id, expectedRevision

No whole-snapshot frontend save. Do not add an unsafe undo command that resurrects expired timers. This release uses delete confirmation and file backups; keyboard undo can remain standard text editing.

## Store Swift interface (engine owner)

`actor StoreEngine`
- `init(url: URL) throws` load/create versioned store, exclusive nonblocking lock held for engine lifetime; error rather than overwrite corrupt/unsupported files. Do NOT seed records. Directory created as necessary.
- `func snapshot(now: Date = Date()) throws -> Data` reconciles expired pomodoros once, persists updates, returns Snapshot JSON.
- `func execute(_ payload: Data, now: Date = Date()) throws -> Data` validates, reconciles, atomically commits then returns Snapshot JSON; no await between validation and commit.
- `func exportBackup() throws -> Data` full versioned backup readable by import.
- `nonisolated static func validateBackup(_ data: Data, now: Date = Date()) throws -> (records: Int, todos: Int)` pure validation for native import preview; never touches store.
- `func importBackup(_ data: Data, now: Date = Date()) throws -> Data` validates every row/schema/ID/references/date, backup existing before replacement, reconcile and return snapshot; malformed input never changes current store.

Use `LocalizedError` for clear Chinese errors. Persist the most recent 4,096 operation receipts and retain 20 full recovery backups. Compare command payloads canonically regardless of JSON key order; replay returns the current snapshot. Revisions stay within JavaScript's safe integer range and reject overflow. Import commits at a revision higher than both the local previous revision and imported revision, so frontend stale-result protection remains valid. Keep on-disk backup before replacement; failed write leaves old state both in memory and disk. Native schedules notification requests only after committed snapshot. Internal engine tests use temporary directory + injected dates.

## Build and ownership

- Engine: Native/StoreEngine.swift and tests/app/store-tests.swift, own test runner.
- Shell: Native/AppMain.swift and other Native files except StoreEngine; scripts/build-app.sh, Info.plist/resources, native settings, scheduling, export/import and app lifecycle.
- Frontend: Web/index.html, Web/app.js (or self-contained), tests/app/web-check.cjs. Reuse prototype style/functionality, real commands, local calendar logic.
- Root: integration, docs, release packaging, final checks and project sync.

Compiler: Swift 6.2.3 with macOS26.2 Command Line Tools SDK; build target macOS14+. `swiftc` standalone acceptable, no full Xcode dependency. Ship .app with bundled resources and ad-hoc signature; do not claim Apple notarization. App is `Time Note.app`, bundle id `local.zoey.time-note`. Default store path `~/Library/Application Support/Time Note/store.json`. Test env `TIME_NOTE_DATA_DIR` overrides directory (and disable automatic permission prompts in test). App close hides, menu-bar stays; explicit Quit preserves records and scheduled notifications; launch/wake reconcile deadlines. Avoid forcefully terminating user's apps. User's real store must remain empty until they use it, tests always isolated.

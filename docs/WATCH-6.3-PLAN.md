# Watch Phase 6.3 — execution lifecycle slice plan

**Status:** 6.3a and 6.3b complete (2026-11-11); 6.3c not started. The owner approved the
approach in this document.

**Authority:** the canonical requirements are the portfolio contract
[iOS Phase 6 — watchOS companion](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-WATCH-CONTRACT.md)
(§8, §10.7, §11, §12.2, §12.3, §13, §17) and the 6.3 bullet of the
[iOS client plan](https://github.com/georgesdib/strength-app/blob/main/docs/plans/IOS-CLIENT-PLAN.md).
This document records slice boundaries, file-level work, tests and the approved decisions. It
never overrides or restates the contract.

## Decisions taken 2026-11-11

1. **HealthKit anchor.** 6.3 starts and ends a real `HKWorkoutSession` for liveness and enforces
   the workout-authorisation start gate, behind a `WatchLivenessAnchor` protocol. Heart rate,
   `HKLiveWorkoutBuilder` collection, the external-UUID save and finalisation remain 6.5.
   6.3 **saves no HealthKit workout**: until 6.5 a watch session leaves no HealthKit record, and
   the acceptance script says so explicitly.
2. **6.3/6.4 boundary.** 6.3 owns one durable queue for the current session: persist-first,
   per-operation acknowledgement, ordered prefix flush, the 5s/15s/60s/5min ladder and the finish
   queue. 6.4 adds relaunch reconciliation against `GET .../execution`, replay guarantees,
   stale-revision application, `plan_item_mismatch`/off-plan preservation and the §11.5
   recovery cards.
3. **UI scope.** 6.3 ships the Set screen, a minimal Session screen (elapsed, sets done/total,
   pending count) and the end flow with the sRPE Crown picker. The Plan screen, Refresh, the
   "Plan updated" marker and tonnage-so-far arrive with 6.6, the slice that consumes revisions.
4. **Telemetry in, form ratings out.** 6.3 emits `execution-events` with the original
   `occurred_at` for every captured action. Form ratings stay with 6.6 and are a recorded gap:
   until then a watch-owned session has no form rating and the phone mirror cannot add one.
5. **Clock.** The watch reads `bootstrap` once when a session starts, derives the offset,
   persists it with the session and clamps any stamp more than 60s ahead of adjusted server time.
   No server change is needed, so 6.3 stays iOS-only.
6. **Evidence.** 6.3 closes on package/unit tests plus the watch simulator build that
   `scripts/ci.sh` already performs. Dim/background/termination/relaunch on hardware is
   owner-run in 6.7; a simulator is not proof.
7. **Slices.** Three reviewable chunks, each stopping for review (below).
8. **Idle warning (3h) and abandonment surfacing** stay with 6.6.
9. **Retry window.** Automatic flush retries stop after 15 minutes from the first failure of a
   burst, with the final wait clamped to the boundary; a new burst starts only on foreground, a
   network-path change or an explicit retry. Authentication failures are not retried — they clear
   to "credentials missing" and leave the queue intact.

## 6.3a — StrengthCore execution primitives (no app wiring) — complete 2026-11-11

Additive only: the phone keeps its current behaviour and its tests stay green.

| File | Work |
|---|---|
| `Sources/StrengthCore/Execution/NetworkState.swift` | `HomeNetworkState` (`unknown`/`online(home)`/`offline`); only a successful Home call marks online; path change and foreground retry; cellular never counts. |
| `Sources/StrengthCore/Execution/RetryLadder.swift` | 5s/15s/60s/300s ladder, reset on success, injected clock, next-attempt deadline. |
| `Sources/StrengthCore/Execution/ServerClock.swift` | Offset from `server_time` plus receipt instant, adjusted stamping, 60s-future clamp. |
| `Sources/StrengthCore/Execution/RestInterval.swift` | Persisted end date, remaining/expired, extend and skip. |
| `Sources/StrengthCore/Execution/FinishIntent.swift` | `{endedAt, sRPE, hkState, serverAcked}` codable record. |
| `Sources/StrengthCore/Offline/OfflineCapture.swift` | Additive fields: `planRevision`, `sessionUUID`, `startedAt`, `restEndsAt`, `finishIntent`; decode defaults keep existing files valid. |
| `StrengthAppTests/WatchExecutionCoreTests.swift` | Ladder and reset, offset and clamp, rest across a reload, persist-before-send ordering, finish intent surviving reload, legacy capture file decoding. |

## 6.3b — watch wiring, liveness and screens — complete 2026-11-11

What shipped: `WatchExecutionEngine` (state machine, persist-first queue, start, set capture,
rest, finish, discard, restore) in `StrengthCore`; `WatchExecutionController` plus the root,
set/session, finish and RIR views in the watch target; a `WatchLivenessAnchor` protocol with
the real `HKWorkoutSession` implementation and a no-op for simulators.

Decisions taken while implementing: the clock offset is derived from `started_at` in the start
response, so no separate `bootstrap` call is needed; start already returns the full snapshot, so
a "started but plan unavailable" state is unreachable and logging is gated only by start success;
sets are logged as prescribed and adjusted on the Set screen (Crown load, ± reps) with RIR chosen
on completion (0–6 or not recorded); "Undo last set" cancels only a set that was never sent;
`Discard session` sits behind a confirmation on the finish screens. The watch gained HealthKit
usage strings, the `workout-processing` background mode and a HealthKit entitlement; a device
build needs the HealthKit capability on the signing team.

## 6.3b (original file plan)

| File | Work |
|---|---|
| `StrengthWatch/WatchWorkoutStore.swift` | Atomic single-writer session record on disk (Application Support), injected URL, no partial writes. |
| `StrengthWatch/WatchLivenessAnchor.swift` | Protocol plus a no-op anchor so the state machine runs in the simulator. |
| `StrengthWatch/WatchHealthKitAnchor.swift` | Real `HKWorkoutSession` start/end, authorisation status, revoked-mid-session handling; no workout save. |
| `StrengthWatch/WatchExecutionController.swift` | `idle → fetching → ready → starting → active(running/resting) → finishing → finished`, flush loop, scene-phase and path-change retries, duplicate-tap suppression. |
| `StrengthWatch/WatchExecutionView.swift`, `WatchSetView.swift`, `WatchFinishView.swift` | Set screen, minimal Session screen, captured/pending confirmation, offline and pending banner, sRPE end flow. |
| `StrengthWatch/WatchTodayView.swift` | Start for a watch-targeted plan with Health authorisation; phone-targeted plans stay read-only. |

The project uses folder-based target membership (`project.xcproj` `"kind": "folder"`), so new
files need no project-file edit. `scripts/ci.sh` already builds the watch scheme and asserts the
embedded watch app.

## 6.3c — telemetry and documentation — complete 2026-11-11

Observed events only, from the same durable queue and in original order: `set_started` (an
explicit **Start set**), `set_completed`, `rest_started` (`prescribed_rest_s`),
`rest_completed` and `rest_extended` (`added_s`). No `rest_skipped`: the watch has one
deliberate way to end rest, and the server derives duration and deviation from the timestamps.
No `workout_paused`/`workout_resumed`: the watch has no pause concept, so emitting them would
invent state. `set_completed` is persisted with its `local_set_id` and given `set_id` only
after the matching add-set is acknowledged; a missing mapping sends no set id rather than a
guess. Telemetry batches merge only into the newest queued operation, so a completion can never
move ahead of the set it describes. "Pending" in the UI counts user work, not telemetry batches.

`WATCH-ACCEPTANCE.md` gained the owner-run 6.3 section. The portfolio plan status update stays
open until this slice is reviewed.

## 6.3 fixups — complete 2026-11-11

Review findings closed after 6.3c, all within the slice (nothing here is 6.4 conflict or revision
work):

- **One write per action.** `OfflineCaptureStore.perform` applies the outbox operation, the
  session-record change and the telemetry event in a single save, so a termination cannot leave a
  queued set beside a stale active set or a set without its completion event.
- **Finish closes what is open.** Finishing during a rest emits `rest_completed` at the finish
  timestamp; finishing during an unlogged set drops the queued `set_started`, because a set that
  never happened leaves no record.
- **Rest follows a durable set.** `logSet` returns a capture result separate from the flush
  result, and rest starts only when the set was persisted locally.
- **Elapsed time is server-adjusted** through the persisted offset, so a fast or slow watch clock
  cannot distort the session clock. A derived offset larger than a day is treated as a wrong watch
  clock and ignored rather than shifting captures out of the replay window.
- **Network-path changes retry** through `NWPathMonitor`; together with foreground and the manual
  retry this satisfies contract §10.7 after the 15-minute window is spent.
- **The set draft survives termination**: load and reps are persisted into `ActiveSet` (throttled)
  and restored on relaunch; screen seeding is keyed by plan item, not exercise id.
- **Liveness is confirmed, not assumed.** `WatchHealthKitAnchor` now waits for the
  `HKWorkoutSession` delegate to report `.running` (8-second timeout) and treats a session that
  never runs as a hard start failure.
- **Exercise telemetry and the end of an exercise**: `exercise_started` on the first set of an
  item, `exercise_completed` on **Done with exercise**, on the next item's first set, or at
  finish. **Done** on an item that never started emits nothing, and wasted time between exercises
  is the gap between a completion and the next start.

## 6.3 UI follow-up — gated flow and the exercise list

Owner decision 2026-11-11: the watch selects an exercise and gates each set behind **Start set**;
it never edits the plan. Shipped as:

- **Read-only exercise list** as the main screen, with per-exercise progress, chosen out of order.
  The selection is persisted, so a relaunch returns to the same exercise.
- **One exercise at a time**: Start set → running set with its own timer and adjustable load/reps →
  **End set** opens the RIR sheet and saves. **Add set** appears only on the last prescribed set and
  starts an extra set from the previous values. **End exercise** closes the exercise early.
- **The separate Log set control is gone**, so the unpaired "set without a start" path is no longer
  reachable from the UI (the engine still tolerates it defensively).
- Session details — elapsed, sets, pending, retry, undo, finish — moved to a Session sheet, which
  leaves three controls plus the rest bar on the exercise screen.
- Selecting an exercise emits nothing; `exercise_started` belongs to the first set. Switching
  exercises, End exercise and finish all close the started exercise.

## Phase 6.4 — reconciliation, revision and conflicts

Completed 2026-11-12 (client) against the new execution envelope.

- **Reconciliation** on launch and foreground: flush first, then compare status and ownership;
  in-progress and owned by this watch resumes, the phone's session becomes read-only, and a
  completed, abandoned or missing workout becomes an ended state with the local snapshot kept.
- **Recovery states**: `readOnly` ("Logging moved to the phone") and `ended(reason)`; both stop
  writes and flushes, and clearing the local record never abandons the server session.
- **Revision**: the envelope carries `plan_revision` and the current plan; a newer one is applied
  only when idle, held as **Plan updated** while a set is in progress, and an older one is ignored.
- **Off-plan preservation**: `409 plan_item_mismatch` triggers exactly one retry with
  `plan_item_index = null`, the same operation id, and unchanged performed data; the original
  index rides in the `set_completed` payload as `original_plan_item_index`, and the summary
  shows the note.
- **Queue**: one flush pass at a time, reloaded each iteration so a rewritten operation is what
  gets sent, no cross-session mixing, and no flushing into a session the server has ended.
- **Config deferral**: a home-server change waits while a session is active or work is queued
  (contract §7.8) and is retried when the watch is free.

## Phase 6.4 corrective fixes — 2026-11-12

- **Exercise navigation gate:** an exercise is active from its first started set until End
  exercise; `selectItem` refuses a different exercise and `clearSelection` refuses while one is
  active, so no UI path can bypass it. Ending an exercise during an unlogged set cancels that set
  and drops its start event.
- **Single-flight flush:** the engine owns a flush task; concurrent callers await it, and one
  follow-up pass runs when work was queued during the pass. No operation is submitted twice.
- **Revision after commit, not after drain:** a newer revision is applied as soon as no set is
  active, even with queued operations; only an active set defers it.
- **One clock domain:** set duration, rest countdown and completion are computed against the
  persisted server offset, like session elapsed time.
- **Ownership fails closed:** missing owner or missing device identity is read-only, queued work is
  kept, and confirmed ownership restores writing. A start response without a confirmed owner is
  read-only rather than writable.

## Phase 6.5 — heart rate and HealthKit save — 2026-11-12

- **Recorder.** `WatchHealthKitRecorder` owns the session, the live builder, the data source and
  the heart-rate statistics; it maps HealthKit errors into definitive or transient save failures.
- **Finaliser in core.** `HealthKitFinalizer` implements the exactly-once rules: an existing
  workout with the session UUID wins; a live builder is finished with the original end; otherwise
  one minimal backdated workout is saved. Transient failures stay pending and count attempts;
  five attempts or a definitive error become unsaved; a manual **Try again** is the only path out
  of unsaved. Nine unit tests cover that matrix with a fake recorder.
- **State and UI.** `FinishIntent` carries `hkAttempts` and `hkNoticeDismissed` (optional for
  older records). The summary shows saving/saved, and on unsaved shows **Try again** and
  **Dismiss**; Done is unaffected.
- **Effort.** The session RPE is written as a `workoutEffortScore` sample after the workout;
  failure to write it never invalidates the workout.
- **Limits.** No simulator or physical acceptance was performed in this slice. The §22.2 device
  spike (backdated minimal workout, UUID query, forced finish failure) remains owner-run.
- **Deferred to 6.7:** the watchOS unit-test target and the §17 simulator smoke (fetch → start →
  log → finish). Both are test infrastructure and belong with the acceptance/CI slice.

### HealthKit spike results — 2026-11-12, watchOS simulator

Run with a throwaway harness (branch deleted afterwards). Probes and results:

1. Live session + builder, 10 s of collection, save with an external UUID: **pass**, start/end
   11 seconds apart, metadata persisted. The effort sample failed with `HKError` code 5
   (authorization not determined) because the harness never requested effort write — the app does.
2. Query by metadata UUID: **count 1**, same dates. The exactly-once mechanism works.
3. Minimal backdated workout, start 30 minutes in the past: **pass**, saved with the requested
   start and end. §12.3's crash-recovery path is viable; no design change needed.
4. Forced finish failure: `HKError` code 3 (invalid argument, "not currently ended"), then a
   retry with the same UUID produced **count 1**. Our mapping classifies code 3 as definitive,
   which matches the policy; the retry does not duplicate.

The simulator cannot enforce the HealthKit entitlement, prompt as a device does, or provide HR,
so the device re-run is folded into 6.7 physical acceptance rather than kept as a separate gate.
6.5 is therefore verified to the extent the simulator allows; physical acceptance is outstanding.

## 6.5 corrective fixes — 2026-11-12

- **Relaunch safety:** a `.finishing` session never starts a new builder; finalisation runs first,
  so recovery uses the existing workout or the minimal backdated one, never a builder created at
  relaunch.
- **Startup coordination:** `HealthKitStartGate` requires both the session reaching `.running`
  and collection beginning; either failure tears the session down and fails the start.
- **Existence check fails closed:** `hasWorkout` throws; a failed query is transient and never
  precedes a save.
- **Nil finish is a failure:** a nil `finishWorkout` result is transient, and a failed live save
  ends the session so the next attempt takes the minimal path.
- **Single-flight finalisation** with pending-only retry on foreground; `.unsaved` stays manual.
- **One clock domain for HealthKit:** start is derived from `bootstrap` server time (start fails
  closed if it cannot be confirmed), so collection start and the server-derived end agree.
- **Effort delivery is its own durable state** (`pending`/`saved`/`unavailable`) with a retry
  that saves only the sample for the existing workout, and a summary notice when it cannot be
  written.
- **Heart-rate freshness:** readings are timestamped; anything older than 30 seconds is cleared and
  never rendered as zero.

## Verification

```bash
# narrowest first (either slice)
xcodebuild test -project StrengthApp.xcodeproj -scheme StrengthApp \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -only-testing:StrengthAppTests/WatchExecutionCoreTests 2>&1 | tail -40

# full gate: watch scheme build + embed assertion + full unit suite
./scripts/ci.sh
```

Toolchain and pseudo-terminal requirements are in `docs/AGENT-WORKFLOWS.md`; no build surprises
are recorded yet for 6.3.

## Not changed in 6.3

- `strength-training-app/` (no route, schema, config or migration change).
- The contract text and the portfolio plan's status table (portfolio branch at closure only).
- HealthKit workout saving and finalisation (6.5), revision application and the phone mirror (6.6).

## Risks

- Extending `OfflineCapture` touches the phone's offline store; it is additive with decode
  compatibility covered by a legacy-file test, and reverted alone if parity fails.
- A liveness-only HealthKit session in 6.3 records no workout; during development a finished
  session therefore looks incomplete in Health. This is expected and documented until 6.5.
- A simulator cannot prove suspension behaviour, so 6.3 claims no lifecycle proof beyond unit
  tests and the build.

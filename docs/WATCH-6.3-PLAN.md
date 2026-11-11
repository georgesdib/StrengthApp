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

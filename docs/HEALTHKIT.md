# HEALTHKIT — CURRENT STATE

**Status:** describes the development behaviour on 2026-11-23; physical acceptance of the
active-energy read scope and saved-workout calories was closed by owner decision (see
`DEVICE-ACCEPTANCE.md` record 14). The cardio stage is
**implemented and deployed**, not proposed. This is a client-owned document: it describes what the
phone and watch do with HealthKit. Server behaviour is owned by the backend and the shared contract
in the [Phase 3A contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-PHASE-3A-CONTRACT.md).

Read this before changing any HealthKit code.

## 1. What the app touches today

| Surface | Reads | Writes |
|---|---|---|
| iPhone — readiness | HRV (SDNN), resting heart rate, body mass | Nothing |
| iPhone — recorded activity | Workouts, heart rate, active energy, VO₂max, workout effort score, Apple's average METs, step count, standing time | One strength-training workout when a session finishes |
| Watch — workout execution | Heart rate and active energy, during a running workout session | One strength-training workout, one workout effort score |

Because read authorisation cannot be queried per type, the watch requests its full read scope at
every session start; HealthKit prompts only for types that are still undetermined. That is how a
newly added scope (active energy) reaches someone who already granted workout access.

The phone now saves one workout when it finishes a session, through `PhoneHealthKitWorkoutWriter`;
the watch keeps its per-device finaliser. Both may save, and neither deletes, merges or corrects a
HealthKit record. The phone write requires workout write permission granted through the HealthKit
opt-in; a denial is logged, not deferred.

## 2. iPhone — readiness reads

- Read-only adapter (`HealthKitReadinessService`): no writes, no observer queries, no background
  delivery.
- Query window: 30 days back to five minutes ahead of now; at most one sample per field per day,
  Apple Watch winning only when positively classified.
- Fields report `eligible`, `stale` or `missing`; an empty result is never treated as denied access
  and never as zero.
- Uploaded to `POST api/ios/v1/healthkit/readiness` with sample identity and source provenance; the
  backend stores them append-only and rejects a reused identity with changed immutable fields.

## 3. iPhone — recorded activity (incremental, post-cutoff only)

`HealthKitActivityService` implements the sync:

- **Backend scope.** The workout cursor, sample cursor, uploaded intervals and both quarantines
  describe what one backend database already has, so they are scoped to the backend identity the
  server issues at pairing (`HealthKitActivityServerIdentity`, derived from the paired device id,
  not the base URL). Home and Away are two routes to the same database and share one identity, so
  changing route keeps the cursors; pairing with a different database clears all five pieces of
  state, and a sync whose scope changed mid-flight cannot commit its batch. A missing stored
  identity (fresh install or upgrade) clears once, which costs one idempotent re-sync.
- **Workouts** since the workout cursor minus one day (idempotent re-send), never before
  `history_cutoff`; the server also rejects pre-cutoff workouts as defence in depth. The cursor
  advances after the server answers. A rejected workout key is quarantined and skipped, so one
  immutable conflict cannot stall every later workout. An older server that returns only a count
  keeps the conservative behaviour: hold the cursor and defer samples.
- **Active energy** is read from each uploaded workout's statistics and sent as
  `active_energy_kj`; absence is recorded as absence, never zero.
- **Uploaded workout intervals** are persisted (HealthKit UUID, start, end, ten-minute tail) so a
  sample that arrives after its workout has left the 24-hour workout query can still be attached.
  The first run after this build backfills the interval store from the sample window once.
- **Heart rate** inside each uploaded or previously uploaded workout and for ten minutes after its
  end, so recovery HR can be computed later. Samples after the workout end are labelled
  `association = "tail"`; the server retains them but excludes them from workout classification and
  time-in-zone. Background samples are never uploaded. A rejected sample key is quarantined and the
  sample cursor advances past it; without keys the cursor is held.
- **VO₂max** as a standalone metric, sent without a cutoff because the server deduplicates on time,
  value and method — that lets a sync fill a gap in the exported history without duplicating it.
- **Workout effort** (`HKMetadataKeyAverageMETs` and the effort score, 1–10) read from metadata and
  matched to its workout by interval; stored as `avg_mets` and `srpe`. Apple supplies them only for
  some recordings (the effort score is athlete-rated on the watch), so a missing value is stored as
  absent and the backend's cardio classification falls back to heart rate.
- **Steps per day and sitting time** as one already-averaged measurement per completed calendar
  week (Monday–Sunday), sent in the metrics array. Daily totals come from a
  `HKStatisticsCollectionQuery` (`cumulativeSum`) over that week. The window digest is the key, so
  a re-sync of the same week is a server-side no-op and a daily sync changes nothing until the week
  rolls over — a rolling window would mint a new row every day. Sitting has no HealthKit type: it
  is `24 h − appleStandTime`, clamped, with the derivation carried in `method`, and an iPhone-only
  athlete writes no row at all. A day without data is absent rather than zero, and a failed query
  yields no metric instead of an empty week.
- Uploads go to `POST api/ios/v1/healthkit/workouts` then `.../samples` (samples and metrics in the
  second call), each device-authenticated and idempotent on the HealthKit UUID. The response reports
  `created`, `existing`, `rejected`, `rejected_keys` (plus nested
  `metrics.written`/`metrics.skipped` on the sample call). The app inspects both responses and
  quarantines the named keys: their workout intervals and samples are filtered from later batches,
  while the cursors advance past them. A skipped metric is surfaced but does not hold a cursor
  because metrics are re-read on every sync. The Cardio and Settings screens show the partial counts
  and quarantined keys with a warning; the last partial sync and the quarantine survive relaunches.
  "Dismiss warning" clears the local skip list only — it does not restore the missing records.

The **Cardio overview** (`CardioOverviewView`, Progress → Cardio activity) reads
`GET api/ios/v1/healthkit/activity/summary`: last 7 days, last 28 days, twelve weeks, recent
workouts, and a sync button. Windows are calendar windows ending today, not windows ending at the
last workout.

## 4. Privacy limits that shape every design

- Read authorisation cannot be queried per type: a denied read is indistinguishable from an empty
  result. Missing data is therefore modelled as unknown, never as zero.
- Write authorisation *is* queryable and is used.
- The app cannot enumerate what was granted; coverage is established by what arrives.
- Values cross the trusted home LAN to the local server; nothing is sent anywhere else.

## 5. Entitlements and usage strings

- `StrengthApp.entitlements`: `com.apple.developer.healthkit`,
  `com.apple.developer.healthkit.background-delivery`, `healthkit.access = health-records`.
- `StrengthWatch.entitlements`: `com.apple.developer.healthkit` only.
- Both extra capabilities are owner-confirmed as intentional; no code uses background delivery or
  clinical records yet. Verify both still validate at submission when something depends on them.
- `NSHealthShareUsageDescription` covers the full read scope (HRV, resting heart rate, bodyweight,
  workouts, heart rate, active energy, VO₂max, steps and standing time). The watch string covers heart rate and active energy during a
  workout, and one saved workout.

## 6. What is not implemented

- **Deletion detection.** A workout deleted in Health is never removed; the web panel's **Hide**
  action is the substitute.
- **Per-workout heart-rate charts on the phone**, and the web time-in-zone chart. Detailed traces
  remain a web concern that is not built. The phone shows aggregated time-in-zone with covered and
  unobserved minutes; zone time is elapsed-time integration over workout-interval samples, so a
  sparse recording reports less coverage rather than being spread across the workout.
- No sleep, clinical records or background delivery.

## 7. Behaviour authority and tests

- `StrengthAppTests/HealthKitReadinessTests.swift` — readiness selection and the empty-never-denied
  rule.
- `StrengthAppTests/WatchHealthKitFinalizerTests.swift` — the watch's exactly-once workout save.
- `StrengthAppTests/FakePhoneHealthKitWorkoutWriter.swift` and the Phase 2 suite — the phone saves
  one workout at finish, and no save happens without write authorisation.
- `StrengthAppTests/HealthKitActivityTests.swift` — independent cursor advancement, persisted
  workout-interval association, partial-response handling, the `rejected`/`skipped` decoding and
  backend scoping (same identity keeps state, a different identity clears it, a mid-sync scope
  change discards the batch, Home/Away keep one identity).
- `StrengthAppTests/HealthKitWindowMetricsTests.swift` — the completed-week window and its roll on
  Monday, window-key stability, the mean that skips days without data, and the sitting clamp.
- The watch's active-energy scope and the saved workout's calorie statistic are physical-device
  behaviour; the simulator cannot create a HealthKit workout session. The check lives in the 6.5
  record linked from `WATCH-ACCEPTANCE.md`.
- The activity sync's contract is also enforced backend-side by `tests/test_ios_workflow.py`.

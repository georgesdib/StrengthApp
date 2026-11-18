# HEALTHKIT — CURRENT STATE

**Status:** describes shipped behaviour on 2026-11-18 (backend 1.7.1). The cardio stage is
**implemented and deployed**, not proposed. This is a client-owned document: it describes what the
phone and watch do with HealthKit. Server behaviour is owned by the backend and the shared contract
in the [Phase 3A contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-PHASE-3A-CONTRACT.md).

Read this before changing any HealthKit code.

## 1. What the app touches today

| Surface | Reads | Writes |
|---|---|---|
| iPhone — readiness | HRV (SDNN), resting heart rate, body mass | Nothing |
| iPhone — recorded activity | Workouts, heart rate, VO₂max, workout effort score, Apple's average METs | Nothing |
| Watch — workout execution | Heart rate, during a running workout session | One strength-training workout, one workout effort score |

There is still no write path from the phone to HealthKit beyond the watch's single saved workout.

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

- **Workouts** since the workout cursor minus one day (idempotent re-send), never before
  `history_cutoff`; the server also rejects pre-cutoff workouts as defence in depth.
- **Heart rate** inside each uploaded workout and for ten minutes after its end, so recovery HR can
  be computed later. Samples after the workout end are labelled `association = "tail"`; the server
  retains them but excludes them from workout classification and time-in-zone. Background samples
  are never uploaded.
- **VO₂max** as a standalone metric, sent without a cutoff because the server deduplicates on time,
  value and method — that lets a sync fill a gap in the exported history without duplicating it.
- **Workout effort** (`HKMetadataKeyAverageMETs` and the effort score, 1–10) read from metadata and
  matched to its workout by interval; stored as `avg_mets` and `srpe`.
- Uploads go to `POST api/ios/v1/healthkit/workouts` then `.../samples` (samples and metrics in the
  second call), each device-authenticated and idempotent on the HealthKit UUID. The response reports
  `created`, `existing`, `rejected` so a partial write is visible.

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
- `NSHealthShareUsageDescription` covers the full read scope (HRV, resting HR, bodyweight, workouts
  and heart rate). The watch string covers heart rate during a workout and one saved workout.

## 6. What is not implemented

- **Deletion detection.** A workout deleted in Health is never removed; the web panel's **Hide**
  action is the substitute.
- **Observed METs/effort on a new upload.** The fields are read and stored, but no post-cutoff
  workout has been uploaded yet, so their presence is unconfirmed.
- **Per-workout heart-rate charts on the phone**, and the web time-in-zone chart. Detailed traces
  remain a web concern that is not built. The phone shows aggregated time-in-zone with covered and
  unobserved minutes; zone time is elapsed-time integration over workout-interval samples, so a
  sparse recording reports less coverage rather than being spread across the workout.
- No sleep, clinical records or background delivery.

## 7. Behaviour authority and tests

- `StrengthAppTests/HealthKitReadinessTests.swift` — readiness selection and the empty-never-denied
  rule.
- `StrengthAppTests/WatchHealthKitFinalizerTests.swift` — the exactly-once workout save.
- The activity sync's contract is enforced backend-side by `tests/test_ios_workflow.py`; the iOS
  side has no equivalent tests yet.

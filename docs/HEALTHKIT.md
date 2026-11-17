# HEALTHKIT — CURRENT STATE

**Status:** describes the shipped behaviour on 2026-11-17 (v1.0 plus the watch 6.7 record). This is a
client-owned document: it describes what the phone and watch do with HealthKit. The server side of the
readiness path is owned by the backend and the shared
[Phase 3A contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-PHASE-3A-CONTRACT.md).

Read this before changing any HealthKit code. The import work described in the
[cardio stage plan](https://github.com/georgesdib/strength-app/blob/main/docs/plans/CARDIO-STAGE.md) is
**proposed and not implemented**; nothing below is waiting on it.

## 1. What the app touches today

| Surface | Reads | Writes |
|---|---|---|
| iPhone — readiness | Heart-rate variability (SDNN), resting heart rate, body mass | Nothing |
| Watch — workout execution | Heart rate, during a running workout session | One strength-training workout, one workout effort score |

There is no other HealthKit surface. No sleep, no clinical records, no other workout types, no
heart-rate time series, no background refresh.

## 2. iPhone — readiness reads

- Read-only adapter (`HealthKitReadinessService`). It performs no writes, no observer queries and no
  background delivery.
- Query window: 30 days back to five minutes ahead of now.
- At most one sample per field per day. Apple Watch wins only when it is positively classified;
  otherwise the newest eligible sample wins with deterministic ties.
- Each field is reported as `eligible`, `stale` or `missing`. An empty result is never treated as
  denied access and never as a zero reading.
- Selected observations are uploaded to `POST api/ios/v1/healthkit/readiness` with sample identity
  (`sample_id`, `sample_at`) and source provenance (`source_name`, `source_bundle_id`,
  `source_class`, model, manufacturer). The backend stores them append-only and rejects reuse of the
  same sample identity with changed immutable fields (409).
- Gated twice: HealthKit is off by default in Settings, and the server must report the
  `healthkit_readiness` capability before the app offers the import.

## 3. Watch — workout recording

- `HKWorkoutSession(.traditionalStrengthTraining, .indoor)` with `HKLiveWorkoutBuilder` and
  `HKLiveWorkoutDataSource`. Heart rate is consumed for liveness (keeping the screen awake while sets
  are logged); the app stores no heart-rate samples of its own.
- Shared to HealthKit: the workout type and `workoutEffortScore`. The effort score is attached with
  `relateWorkoutEffortSample`; a score that cannot be related is deleted rather than left orphaned.
- The saved workout carries `HKMetadataKeyExternalUUID` set to the watch-local `sessionUUID` — the
  same UUID that is the idempotency key of the finish request. The server does not persist it, so a
  session row cannot currently be traced back to its HealthKit workout. That is the gap the cardio
  stage's reconciliation work exists to close.
- Exactly-once save rule lives in `StrengthCore` (`HealthKitFinalizer`), not in the HealthKit adapter:
  up to five automatic attempts, then the save is terminal `unsaved` and only an explicit retry runs
  again. Duplicate prevention checks for an existing workout by the metadata key before saving.

## 4. Privacy limits that shape every design here

- Read authorisation cannot be queried per type. A denied read is indistinguishable from an empty
  result, so the app cannot know whether "no data" means "no data exists" or "no access granted".
  Every surface must therefore treat missing data as unknown, never as zero activity.
- Write authorisation *is* queryable and is used (`sharingAuthorized`, `sharingDenied`,
  `notDetermined`).
- The app cannot enumerate what the user granted. Coverage is established by what arrives, not by
  what was requested.
- HealthKit values cross the trusted home LAN to the local server over the existing plain-HTTP model.
  Nothing is sent anywhere else.

## 5. Entitlements and usage strings

- `StrengthApp.entitlements`: `com.apple.developer.healthkit`,
  `com.apple.developer.healthkit.background-delivery` and
  `com.apple.developer.healthkit.access = health-records`.
- `StrengthWatch.entitlements`: `com.apple.developer.healthkit` only.
- **Discrepancy to resolve before relying on it:** no code path uses background delivery or clinical
  records today. The phone's declared capability is broader than its behaviour. Either justify the
  records access or remove it; verify the background-delivery entitlement still validates at
  submission before the import work depends on it.
- `NSHealthShareUsageDescription` on the phone names HRV, resting heart rate and bodyweight only. It
  must be rewritten in the same change that widens the read scope, and the widened prompt must be
  re-presented to existing installs (a granted scope is not silently extended).

## 6. What is not implemented

Workout import of any kind; heart-rate series; VO₂max, exercise minutes, distance, active energy or
power; historical backfill; anchored incremental sync; workout deletion handling; reconciliation
against strength sessions; cardio dashboards. The cardio stage plan scopes these across C0–C7 and none
of it is delivered.

## 7. Behaviour authority and tests

- `StrengthAppTests/HealthKitReadinessTests.swift` — selection, staleness and the empty-never-denied
  rule.
- `StrengthAppTests/WatchHealthKitFinalizerTests.swift` — the exactly-once save rule.
- Both encode behaviour that this document describes; a change to one without the other is a bug.

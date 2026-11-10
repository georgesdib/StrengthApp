# Native iPhone Client — Online-First Implementation Plan

> This is the client-side plan and lives with the iOS client. The server API contracts remain in
> the `strength-training-app` repository because the server is authoritative for training
> decisions; links below point there.

**Status:** Phase 0 complete 2026-11-07 (owner-confirmed); **Phase 1 complete 2026-11-07**
(owner-confirmed on the physical iPhone); **Phase 2 complete and closed 2026-11-07**
(simulator-verified and owner-confirmed on the physical iPhone). The server side is migrations 0052_ios_device, 0053_ios_workflow and
0054_healthkit_readiness and 0055_healthkit_bodyweight, the ios CLI, the bearer-authenticated
/api/ios/v1/ facade, and its tests;
the Swift client in this repository has pairing, Today, History,
Settings/Forget, readiness entry, Workout ready/start-by-id, active workout,
completion/abandon, Progress, opt-in HealthKit HRV/RHR/bodyweight readiness, Keychain storage,
Home/Away server routing by Home Server reachability with a Prefer Home manual override (no
Wi-Fi SSID, Location or Access Wi-Fi Information entitlement), Settings Exercise Library with read-only configurations, e1RM and paginated
working-set history,
102 unit tests
after R1/R3/R5/Phase 3A and optional live UI smoke tests. Phase 3A is closed 2026-11-08; physical
HealthKit acceptance was owner-confirmed and Phase 3B is out of scope. R7 (asynchronous
prescription request with session-type and minimum-session settings) is **implemented and closed
2026-11-08**: the app builds with an iOS 27.0 deployment target and 102 client tests pass on the
available iOS 27.2 simulator; the app launches, and the live UI flow passed twice — once with the resolver off and once with it on against a copy of the
real database. R2 is closed as absorbed by R7's `plans/current` read. R8 (active-workout plan editing) is **closed 2026-11-08**;
its authenticated exercise-catalogue, online-only and no-solved-load decisions are recorded; R8 is
closed.
Server contracts:
[`design/IOS-R7-CONTRACT.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-R7-CONTRACT.md) and
[`design/IOS-R8-CONTRACT.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-R8-CONTRACT.md). Later phases remain proposals and need
separate approval. **Phase 6 (watchOS companion) is in progress: 6.0 shared core, 6.1 server
contract, 6.2a watch target, 6.2b credential handoff and 6.2c read-only Today are complete; 6.3+ is
planned, not started**:
[`design/IOS-WATCH-CONTRACT.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-WATCH-CONTRACT.md); the watch cannot start or log a workout yet.

**Purpose:** deliver a practical iPhone interface for one person's existing strength-training workflow, without porting the training method or making a public cloud service a prerequisite. Start with an ordinary, connected strength session. Add offline capture, HealthKit, and Apple Intelligence only after the smaller client proves useful and reliable.

## 1. Recommendation and first-release acceptance

Build a modest SwiftUI client that calls the existing Python application through a small, versioned `/api/ios/v1/` facade. Python remains the sole authority for readiness scoring, prescription generation, exercise selection, loads, sets, RIR, validation, and training decisions. The phone presents server results and records the user's actions; it does not construct or change a prescription.

The **first useful release** is the following connected strength-training slice:

1. Pair the iPhone with the owner's local server over the trusted home LAN.
2. Show today's readiness and relevant training/workout status.
3. Enter and save a manual readiness check-in.
4. Request and display a server-generated prescription and its warnings.
5. Start the server-authorized workout.
6. Log sets against the returned plan.
7. Complete or abandon the workout.
8. Record manual session RPE, or explicitly mark it not recorded.
9. Read basic workout history and existing progress summaries.
10. Record each lift's optional 1–5 form rating inline; open the post-workout rubric review if the build includes it, otherwise enter marks later in the web UI.

**Acceptance:** the owner can complete a normal strength session from the iPhone without opening the web UI, while every training decision and validation result remains server-authoritative. The client receives an acknowledgement before displaying a mutation as saved. Existing web and CLI flows continue to work unchanged.

Form ratings and the post-session review use existing server review/form contracts. Form ratings are optional and captured inline; the rubric review screen may follow the first release, with marks entered in the web UI until then. Neither is needed to complete a workout, and neither may be calculated by the phone or an LLM.

### Explicitly not a first-release prerequisite

HealthKit readiness (Phase 3A) and offline capture (Phase 4) were not first-release prerequisites and are now closed. Apple Workout import (Phase 3B), manual cardio, advanced Longevity analytics, background processing, Apple Intelligence, and PCC remain deferred. Basic history/progress means read-only use of existing summaries, not a new dashboard or analytics engine. Keep the remaining items as later phases below rather than quietly adding them to the release gate.

## 2. Architectural invariants

- **Python is authoritative.** The client cannot construct, modify, select, or override a prescription. Readiness scores, exercise choices, load, sets, RIR, business validation, and training decisions come from Python.
- **No duplicate methodology.** Swift may validate form presentation (required fields, sensible number formatting), but the server repeats all domain validation. It must not reproduce training calculations.
- **No AI training decisions.** Apple Intelligence or any LLM may not generate/alter readiness scores, prescriptions, loads, RIR, exercise selections, form/rubric ratings, or other training decisions.
- **Keep existing clients compatible.** Add a versioned facade incrementally; do not change existing unversioned routes in a way that breaks the web UI or CLI.
- **Local-first, not cloud-dependent.** The normal product path is the owner's local server. No public endpoint, account, remote database, analytics, telemetry, or third-party exporter is required. PCC is a separate optional future AI exception, never a core dependency.
- **No transport-security claim.** The first release speaks plain HTTP on the owner's trusted home LAN and does not terminate TLS. LAN traffic, including the per-device credential, is unencrypted; the deployment assumes a trusted network and no public exposure. TLS is a separate decision if that threat model changes.
- **HealthKit is opt-in and read-only.** It is a measurement source, not a training authority. Preserve source, date/time, units and coverage. Python applies only its already documented readiness rules.
- **Manual values win.** When HealthKit is added, a manual value takes precedence per field and cannot be erased by a later import. Keep both values and provenance where correction/audit requires them.
- **Do not silently merge records.** Ambiguous HealthKit workouts remain separate until the owner explicitly associates them with an app session.
- **Append-only where the domain requires it.** Corrections/reviews follow existing append-only or superseding-record paths rather than editing history invisibly.
- **No scope drift into** vector databases, RAG, autonomous agents, time-decaying fatigue models, duplicated training logic, or sleep duration/Apple sleep-score features. Sleep remains outside this plan.

## 3. Existing implementation to reuse

| Area | Current implementation and implication for iOS |
|---|---|
| Readiness | `docs/READINESS.md`, `features/readiness.py`, `features/readiness_score.py`, `readiness_day`, `readiness_entry` and `readiness_override`. Five subjective values are 1–5, higher-is-better; fields may be partial. The server owns the score, minimum-data gate and overrides. HRV/RHR use existing baselines only when their requirements are met. |
| Prescription | `/api/prescribe` and existing deterministic prescription/rules stack. A new iOS facade must call it with model selection disabled, return the exact plan/warnings, and bind workout start to that server-issued plan. Do not accept client-authored loads, sets, RIR or a replacement plan. |
| Workout lifecycle | `strength_coach/workout.py`; current routes cover start, active/detail, set add/remove/correction, end and abandon. Sets and corrections have domain validation; ending requires session RPE 1–10 or an explicit not-recorded choice. Use those services, not a Swift workout engine. |
| History/progress | Existing history, progress and outcomes queries are descriptive. Reuse a small read-only subset; no duplicated analytics in Swift. Dates follow server-local date semantics unless a future profile/time-zone decision changes this. |
| Session RPE and review | Workout completion accepts manual session RPE. `session_feedback.srpe` accepts 1–10 and is append-only; current schema does not preserve whether a value came from a person or Apple Health. The review route returns server-built rubric items and writes marks/feedback. Form self-ratings have existing workout/history paths. The iOS client must not compute rubric values or calibration; preserve the server's rubric version and confidence semantics (see [`RUBRIC-CALIBRATION.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/RUBRIC-CALIBRATION.md)). |
| Security | Current web server is unauthenticated HTTP on the home LAN (`LIM-57`). The iOS facade adds per-device credentials before any personal data is sent; transport stays plain HTTP on the trusted home LAN (unencrypted by design). Do not expose the port publicly. |
| Web/CLI | These remain supported, current ways to use the application. The iOS project is a thin additional client, not a replacement or administrative console. |

## 4. Phased implementation plan

Each phase is separately reviewable. Add only the endpoints, migrations, client screens, and tests needed for that phase. The first connected vertical slice was implemented before any offline queue, HealthKit importer, or model feature. Phases 0–2, Phase 3A, Phase 4, and R1–R5, R7 and R8 are closed; Phase 3B and Phase 5 need separate approval before they start.

**Implementation order (owner decision, 2026-11-07):** Phases 0–2, 3A and 4 are complete; next are
3B (Apple Workout imports) and Phase 5. Phase numbers stay stable so existing references do not move;
the order reflected an always-on home server, where offline capture was optional and HealthKit
readiness was the reason to build the app.

### Phase 0 — Preconditions (no app code)

**Status:** complete 2026-11-07 (owner-confirmed): an empty SwiftUI app is signed and launches on the target iPhone under the personal team, the HealthKit capability is verified, the iPhone reaches the server over plain HTTP on the home LAN, and CLI-only pairing was chosen. Network details stay private; the pairing code length, TTL, attempt limit and token lifetime are fixed in the Phase 1 design.

**Goal:** settle the environment facts that can invalidate the architecture before any Swift or
server work starts. This phase writes no application code, adds no route and changes no data.

- **Signed empty app (toolchain sanity check):** confirm the target iPhone, the minimum iOS version
  the owner can run, the Mac/Xcode used to build, and a personal (free-provisioning) team. Build,
  sign and launch an empty SwiftUI app and note the seven-day signature expiry and the weekly
  re-sign routine. Moving to a paid team later changes the Keychain access group, so expect exactly
  one re-pair at that point. Include the HealthKit capability in this build only to prove it signs
  under the personal team; no HealthKit code is written here. If it cannot sign, decide then
  between a paid account and deferring the HealthKit phase.
- **Server host and LAN path:** the always-on Odroid Linux box, not the Mac. Record its LAN address
  and the port the Python server already binds, and confirm the iPhone can reach it on home Wi-Fi
  over plain HTTP. No port-forwarding, no VPN and no Tailscale.
- **Pairing choices:** the CLI entry point ('strength-coach ios pair'), code length, TTL and attempt
  limit, and long-lived token handling (Keychain on the phone, verifier only on the server).
- **Rollback:** stop. Phase 0 has no route, migration or data write to undo.

**Exit criteria:** every item is settled or explicitly deferred; a signed app launches on the target
phone; the phone reaches the server on the home LAN; the owner has approved Phase 1.

### Phase 1 — Native Foundation and Read-Only Views

**Status:** **complete 2026-11-07.** Server facade, migration, CLI and contract tests are
implemented; the Swift pairing/today/history/settings shell passed on the iPhone 18 Pro simulator
and the owner confirmed the device checklist on the physical iPhone. The client repository carries
`DEVICE-ACCEPTANCE.md` with the completed record.

**Contract:** [`design/IOS-PHASE-1-CONTRACT.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-PHASE-1-CONTRACT.md) — routes, auth
flow, migration, tests and acceptance for this phase.

**Goal:** install a small app that pairs with the owner's server and reads current server information.

**Steps:**

1. Confirm the target iPhone/iOS, available Mac/Xcode path, and the server's LAN address and port (plain HTTP on the trusted home network).
2. Implement a minimal SwiftUI shell and one-time pairing flow. A short-lived pairing code generated locally by the server/CLI authorizes exchange for a random per-device credential; there is no open device registration.
3. Store the credential in Keychain. Add a simple local revoke/re-pair procedure. Store only a verifier/hash server-side where practical; never log the credential.
4. Add the `/api/ios/v1/` namespace and only the first-phase read contracts: bootstrap/capabilities, today's status, and read-only history/progress summaries. Retain canonical server date/timezone semantics and response units.
5. Add device authentication and server-side checks for every iOS request. Pairing-code exchange is protected by the one-time code; there are no unauthenticated write endpoints.
6. Add the minimum API contract/integration tests for authentication, revocation, read-only status/history and errors. Do not define or implement the entire future API up front.

**Acceptance:** the paired iPhone can retrieve relevant server information over the home LAN (plain HTTP); an unpaired or revoked device is rejected; credentials do not appear in logs; existing web and CLI behavior is unchanged.

**Scope note:** showing cached read-only information is allowed only when clearly marked with its last successful refresh time. Offline mutation is not promised in this phase.

### Phase 2 — Core Strength Training Workflow

**Goal:** complete a typical strength session entirely on the iPhone, online.

**Steps:**

1. Add manual readiness entry for the five existing subjective fields, preserving partial/missing values and displaying the returned server result. The phone does not calculate a score.
2. Add a prescription request that uses the current deterministic Python path, disables model-based selection for this client, stores the exact returned plan as an issued-plan record with a short expiry (for example, two hours or the end of the server-local day), and displays the plan and warnings without editing them.
3. Start only by issued-plan identifier. The server loads the stored plan itself, rechecks expiry, readiness acknowledgement and conflicts, starts the workout and marks the plan consumed in the same transaction. The client never submits plan content, so a forged or altered plan is not a reachable input.
4. Build a focused exercise-first workout logger: select an exercise, show its planned sets, mark a performed set done with load/reps/RIR/velocity, and keep plan editing on the workout overview. Performed sets can be added or removed, including exercises outside the plan through the authenticated catalogue. Start a local rest timer for working sets only, using the plan item’s `rest_s`, and keep it available while navigating. Show an explicit saved/failed state based on the server response.
5. Complete or abandon through existing services. Capture manual session RPE 1–10 or a single Not recorded choice, optional productivity 1–5, and preserve server-measured duration or clearly identified manual duration.
6. Show recent workout history and a small set of existing progress summaries. No comprehensive dashboard or new calculation.
7. Add a read-only Settings Exercise Library: searchable catalogue, configuration details, server-computed e1RM and paginated working-set history. Cache the catalogue/configuration for the app session; fetch e1RM and history on detail entry; refresh explicitly. Do not edit taxonomy or calculate e1RM in Swift.
8. Capture each lift's optional 1–5 form rating inline in the workout screen while the session is open; the existing contract accepts ratings only for an in-progress workout. The post-session rubric review stays optional and may ship after the first release, in which case marks are entered in the existing web UI. Keep review skippable, distinct from session RPE, and never a gate for completion. Do not invent marks.
9. Add idempotency receipts from the start, not as part of the offline phase: a per-device operation id plus a request hash, the stored response, and a conflict when the same id arrives with a different body. Cover readiness save, set add/update/remove, end and review. Reconcile a retried start by reading the active workout instead of issuing a receipt. Keep the mechanism specific to these operations, not a generic replication framework.

**Acceptance:** on the target iPhone, a user can save readiness, request the server prescription, start it, log sets, record optional inline form ratings, end it with manual session RPE (or explicitly not recorded), submit the optional rubric review when it exists, and view the completed session/history without opening the web UI. Tests establish that the client cannot submit plan content at all, an issued plan cannot be replayed or used twice, duplicate requests do not duplicate records, and existing web/CLI tests remain green.

**Boundary:** this is an online workflow. If connectivity fails, the UI must not claim a set, readiness entry, or completion has been saved when it has not. Durable offline capture is Phase 4.

### Phase 3 — HealthKit

HealthKit is optional and read-only. Ask permissions only when the owner enables the related feature. Never require HealthKit permission to enter readiness or complete a workout.

**Phase 3A: HRV, resting heart rate and bodyweight.** The authoritative specification is
[design/IOS-PHASE-3A-CONTRACT.md](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-PHASE-3A-CONTRACT.md). The owner approved the scope
and implementation on 2026-11-08; the server migration, canonical merge, import route and client
HealthKit path are implemented. Unit, simulator and live-server workflow verification pass;
physical HealthKit acceptance is owner-confirmed and Phase 3A is closed. Do not duplicate or vary
the contract rules here.
Phase 3B remains separate below.

**Phase 3B: Apple Workout summaries and related cardio data, if useful**

1. Import completed HealthKit workout summaries only after the HRV/RHR slice is stable. Preserve workout type, start/end, duration, source/device and HealthKit object identity where available.
2. Preview before materializing/importing. Keep Apple strength workout summaries as summaries: never infer exercises, sets, repetitions, loads or RIR.
3. Do not merge an Apple workout into an app session based only on time overlap. Offer an explicit association with a displayed existing app session; ambiguous records remain separate.
4. Add cardio records only through the existing descriptive cardio contract, with explicit provenance. No cardio prescription or fatigue model is introduced.
5. Keep HealthKit source deletion/updates and duplicate protection auditable. Do not retain raw sample time series unless a separate user-facing need justifies it.

#### Apple Workout Effort Score and session RPE

When supported effort data is available for an Apple workout that the owner has explicitly associated with an application session, it **may populate the effective session sRPE only when no manual sRPE already exists**. It is an optional source, not a requirement for Phase 2 or the first release.

- Preserve the exact HealthKit effort identifier (`workoutEffortScore` versus `estimatedWorkoutEffortScore`), source/device, value, timestamp and whether it is estimated or user-entered where the API exposes that distinction.
- Do not overwrite a manual value. If a manual value is later entered, it takes precedence; keep the Apple record and provenance rather than deleting it.
- Add source-aware persistence/read behavior before mapping Apple data into the app's effective `session_feedback.srpe`; the current table has no source field. A linked immutable HealthKit record plus an explicit selected-source field, or a small additive schema, is preferable to treating imported Apple data as manual.
- Accept only a supported value already compatible with the app's 1–10 session-RPE range; do not infer, rescale, average, or fill a missing score with a default.
- Keep session sRPE distinct from cardio-log sRPE, exercise-level RIR, workout metrics, the post-workout critique composite, and per-item rubric marks. Apple effort does not write or change those values.
- Late import may update a descriptive session feedback value only through an auditable source-aware path. It must not regenerate or retroactively alter a prescription.

**Acceptance:** unlinked Apple workouts stay separate; repeated imports are idempotent; strength details are never fabricated; imported effort retains its Apple/estimated/manual provenance; manual sRPE wins; unsupported or absent effort remains missing; prescriptions and critique/rubric calculations are unaffected.

### Phase 4 — Reliable Capture and Offline Support

**Status:** **closed 2026-11-08.** Chunks 1–4 are implemented (timestamps, durable outbox, offline
capture, ordered replay and conflict handling); physical offline acceptance was owner-confirmed.

**Goal:** add offline resilience only after the online strength flow is stable.

**Steps:**

1. Persist an active workout and mutation outbox locally before acknowledging offline capture to the user.
2. Give each queued mutation a stable client operation identifier; preserve per-workout ordering and the original local date/time/time zone.
3. Reuse the Phase 2 receipts for offline replay. Extend them only if a new retriable operation appears; a repeated identifier with the same body returns the original result and a different body is a conflict.
4. Retry safely with bounded backoff and expose `pending`, `synced`, and `failed/needs attention` states. Do not discard queued work on a timeout or app restart.
5. Support explicit reconciliation for server conflicts, including a workout edited through another client. Never silently merge, overwrite or delete an event.
6. Add set correction/removal only through append-only event paths, with undo where it can be represented safely.
7. Keep fresh readiness scoring, prescription generation, workout authorization, and conflict resolution online/server-authoritative. Offline records are performed-work capture, not a new prescription and not proof of a server-completed workout until acknowledged.
8. Avoid a generic “sync every object” framework. Implement the smallest durable outbox that fits these workout/readiness operations.

**Acceptance:** capture can survive server disconnection, app termination and restart; reconnecting synchronizes each operation at most once; order and local-date context are preserved; partial failures remain visible/actionable; a fresh prescription is unavailable offline; no offline result is represented as server-authoritative.

### R9 — Execution telemetry and timeline

**Status:** server and client implemented on `development`; simulator/unit gates pass. Physical-device
acceptance remains an owner step before this section is marked closed.

The additive server stream (`workout_execution_event`, migration 0057) records explicit set/rest/
exercise start and completion events without changing `workout_set` or `workout_event`. Events are
batched through the existing Phase 4 outbox and rendered as a read-only History execution section.
The server derives durations, prescribed-versus-actual rest, transitions and missing coverage; it
never infers a set duration from completion alone and never backfills historical workouts.

The optional heart-rate phase is **not implemented**. The current HealthKit path reads HRV, resting
heart rate and bodyweight for readiness only; it does not request or expose workout heart-rate
samples. Adding workout HR would require a separate opt-in, separate samples, provenance and
feature gate, and would remain observational rather than a fatigue or readiness input.

### Phase 5 — Optional Enhancements

Only pursue after the core app is useful and stable, with a separate scope/approval decision for each feature:

- **Apple Intelligence:** optional tools may parse a spoken/typed set entry into an uncommitted draft, explain a server-produced prescription, summarize completed training, or structure free-text notes. The user reviews/accepts any draft before it reaches server validation. The model never controls training decisions or computes numbers.
- **PCC:** an explicitly selected Apple Private Cloud Compute option for a user-invoked AI task; disabled by default, visibly identified as Apple server processing, with a preview of the context and consent before personal workout/health data is included. It is not used by pairing, readiness, prescription, capture, or sync; no automatic fallback from on-device mode; core functionality remains available with PCC disabled or offline.
- Additional HealthKit observations (steps, body mass, VO₂max), richer cardio imports, richer but descriptive Longevity views, background delivery, or historical XML backfill only when a concrete use case justifies their added privacy/schema/testing cost. The watchOS companion is Phase 6, not part of this bucket.
- Do not add sleep duration, sleep stages, or Apple Sleep Score under this plan.

**Acceptance:** each enhancement is independently disableable and does not become a dependency of pairing, readiness, prescription, workout capture, or review. On-device AI and PCC outputs are suggestions/text only; all numeric training data still pass through explicit user review and existing server validation.

### Phase 6 — watchOS companion (6.0–6.2b complete; 6.2c+ pending)

The phone plans; the watch executes. Full contract:
[`design/IOS-WATCH-CONTRACT.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-WATCH-CONTRACT.md). Decisions locked 2026-11-09 and
remediated the same day for extraction, credential handoff, the home-server config, offline-first
execution, lifecycle, offline conflicts, HealthKit idempotency and acceptance. Targets:
**iOS 27.0** and **watchOS 27.0**. The 6.0 shared-core extraction (S1–S4), 6.1 server contract,
6.2a watch target and 6.2b credential handoff are complete, including migration
`0058_watch_companion.sql`; 6.2c (read-only Today) and later are not started.

**Scope.** The phone requests a plan with an explicit `execution_target` (`phone` or `watch`);
the watch fetches the plan targeted for it, starts the session, logs sets, rest, form ratings and
finish with sRPE, shows heart rate, and writes exactly one HealthKit strength workout. It has its
own paired device token, minted by the phone, and is pinned to the phone's **home** server via
`homeBaseURL` + `configVersion`; it never follows the Away route. Start is the only online gate in
v1; after it, every set/form/telemetry/finish is local-first with opportunistic partial flushes and
backoff, and HealthKit is local. Plan fetch and start need connectivity, and a watch session
requires HealthKit workout authorisation so the app can stay alive. During a watch session the
watch is the only set writer; the phone edits the plan and shows a read-only mirror with a
take-over action. Readiness, history, progress, settings and the exercise library stay on the phone.

**Shared core.** `StrengthCore` is extracted in five reviewable stages, each keeping the iPhone
suite green: S1 models, S2 API client, S3 persistence/credentials, S4 session engine one operation
at a time, S5 the watch target. The package contains no UI, HealthKit, WatchConnectivity or
`#if os()` code; iPhone views and iOS-only services stay in the app. Contract §6 is authoritative
on boundaries and per-stage acceptance.

**Work packages.**

1. **6.0 StrengthCore extraction (iOS first) — complete 2026-11-10.** S1 models, S2 API client,
   S3 journal/Keychain/offline capture and S4 session reducer are in the package; the iPhone app is
   the adapter. Parity was proved per stage. Acceptance: the 102 existing iPhone tests stayed green,
   five reducer tests were added (107 total at 6.0; 172 today with 6.2b/6.2c coverage), no view changed,
   and the package builds for iOS 27.0 and watchOS 27.0. S5 (the watch target) is 6.2a.
2. **6.1 Server contract — complete 2026-11-10.** `0058_watch_companion.sql` adds watch kind,
   parent, monotonic `credential_epoch`, the one-active-watch index, `target_device_id` and
   `execution_target` on issued plans, and owner/revision/activity on workouts. Mint/list/revoke,
   target routing and `409 wrong_execution_target`, owner checks and takeover,
   `409 plan_item_mismatch`, idle warning and 24h lazy abandonment, 4h plan TTL and
   `watch_enabled` are implemented with migration, device, routing, ownership, revision, mismatch,
   idle and regression tests.
3. **6.2 Watch shell, credentials and read-only Today — complete.** 6.2a created the embedded
   watch target, scheme and CI build. 6.2b added the WatchConnectivity credential handoff with
   epoch, `configVersion`, `homeBaseURL`, bounded retry, 401/revocation recovery and Home-only
   API sessions. 6.2c adds the read-only plan fetch and watches-targeted Today display; it does
   not start or log a workout.
4. **6.3 Execution lifecycle.** HK-session-anchored state machine, persist-first set capture, rest
   timer persistence, offline-first network policy with partial flushes and 5s/15s/60s/5min backoff,
   finish queue and foreground retry, dim/background/termination/relaunch behaviour, and execution
   telemetry with original `occurred_at` values.
5. **6.4 Offline and conflicts.** Session-scoped outbox, ordered replay, relaunch recovery,
   flush-before-revision on reconnect, off-plan preservation on `plan_item_mismatch`, and no
   stale-snapshot overwrite.
6. **6.5 Heart rate and HealthKit.** `HKWorkoutSession` and builder, live HR, the external-UUID
   exactly-once save, crash/relaunch finalisation, real start/end timestamps, and permission
   handling.
7. **6.6 Phone mirror and plan revision.** Mirror mode with set logging disabled and a take-over
   confirmation, phone push on edit, watch refresh points, stale-revision rejection, and
   non-interruption of a set in progress.
8. **6.7 Acceptance and CI.** Watch build and deployment-target assertion in `ios-ci`, the twelve
   scenario tests in contract §17, physical Ultra acceptance, docs and rollback notes.

**Acceptance.** The physical script in contract §17 plus the required scenarios: delayed/failed
credential delivery, relaunch with pending mutations, backgrounding and returning mid-session,
phone plan modification while the watch is offline, stale-revision rejection, take-over and
read-only state, HealthKit finish retry without duplication, clock skew and original timestamps,
execution-target enforcement, patchy Wi-Fi with partial flushes and an offline finish, home
`configVersion` refresh, and the watchOS 27.0 deployment/CI build.

**Deferred:** the pending-session shell for offline start and the “Send to iPhone” relay are
explicitly out of v1; contract §21 records what each would require.

## 5. Offline behavior — explicit contract

| Action | Phase 1–2 behavior | Phase 4 (offline) behavior |
|---|---|---|
| View previously fetched status/history | May show cache, clearly labelled with refresh time and stale state. | Same. |
| Enter readiness | Requires an online server acknowledgement; an unsent form is not recorded/scored. | May queue a clearly labelled manual entry if included in the outbox; it is not scored until Python receives it. |
| Start a workout or request a fresh prescription | Requires server connectivity. | Still requires server connectivity and a current server-issued plan. |
| Log an in-progress set / finish | Requires server acknowledgement; do not claim saved on failure. | Can be durably captured locally and queued; show pending until server acknowledgement. |
| Synchronize pending changes | Immediate request/response; no offline queue guarantee. | Ordered, idempotent retry/reconciliation. |
| Readiness score/prescription while offline | Not available as a fresh result. | Still unavailable; no on-device substitute. |

## 6. API and data approach

Preserve `/api/ios/v1/` as the future facade namespace, but implement endpoints only when a phase needs them. Existing web/CLI routes remain intact and authoritative. Do not prebuild the earlier proposed full route inventory or generic `/sync/all` framework.

| Increment | Contract needed | Notes |
|---|---|---|
| Phase 1 | Protected pairing exchange; `GET bootstrap/today`; read-only recent history and a server-only progress summary | Return server/API version, server-local date/timezone, capabilities, readiness/workout status and small existing summaries. No config paths or secrets. The `progress` route is implemented and tested server-side; the Phase 1 client has no Progress screen (deferred to Phase 2). |
| Phase 2 | Read/write readiness; request prescription; read active workout; start by issued-plan id; add set; complete/abandon; read history/progress; optional inline form ratings; optional review | Mutations require authentication and an idempotency receipt. The prescription is stored at issue and the client starts by id only, so plan content never comes from the phone. Validate every field via existing Python services. |
| R7 (implemented and closed) | Asynchronous prescription request; optional session type, minimum session and top-set/straight-set structure; authoritative `GET plans/current`; start that writes the prescription | Returns `202` and builds in one bounded dispatcher on the shared CPU slot; two deadlines (build vs startable); legacy `ios_issued_plan` rows preserved by an explicit mapping; prescription persistence moves to start. |
| Phase 3 | HRV/RHR provenance; HealthKit record import and optional workout association | Add only the source/provenance fields and routes needed by enabled types; keep user-consented HealthKit read-only. |
| Phase 4 | Add/correct/remove set and offline event replay/reconciliation | Reuse the Phase 2 receipts; add a conflict response only where replay needs it. |

All dates use server-local calendar semantics for readiness/prescription. Preserve timezone/absolute timestamps for captured workout events; do not infer training date from a UTC date slice. Use the server's canonical units and validation. Return stable, useful validation/conflict errors without exposing file paths, stack traces or secrets.

### Minimal data changes anticipated

- **Phase 1:** per-device authorization record and a revocable credential verifier; avoid a user/account system.
- **Phase 2:** a short-lived issued-plan record storing the exact plan JSON (the prescription tables do not retain warm-ups, notes or the resolver snapshot) with expiry and consumption, plus an operation-receipt table for retry safety. Reuse current append-only workout, readiness and feedback services.
- **Phase 3:** HealthKit source-object identity/provenance and field-level source precedence. For Apple effort, source-aware session RPE is necessary because current `session_feedback` rows do not identify their source.
- **Phase 4:** the outbox is client-side; no server schema is needed for the queue itself. Reuse the Phase 2 receipts; add a conflict response only where replay needs it.

Review exact migration sequence against the implementation branch at coding time. Do not change core methodology or current web/CLI data behavior as a side effect.

## 7. Security and deployment — adequate, not a separate project

The present home-LAN server has no authentication and uses HTTP (`LIM-57`). The iPhone must not send credentials or personal workout data through the existing unauthenticated interface. Add the smallest defensible iOS boundary before personal use:

- Authenticate all iOS requests with a per-device random credential; protect it in Keychain, keep only a verifier/hash server-side, and provide a clear revoke/re-pair command.
- Pair only with a short-lived, one-use code generated locally by the owner. The code protects against guessing, not against someone who can observe the LAN; there is no open registration or unauthenticated data mutation.
- **Transport is plain HTTP on the trusted home LAN.** This is a personal deployment on the
  owner's own network and does not terminate TLS. LAN HTTP traffic — including the device
  credential and workout data — is unencrypted, so anyone who can observe or reach the home LAN
  could read it or reuse the token. The deployment assumes a trusted network with no untrusted
  devices or guests. Do not port-forward, expose the API publicly, or add remote access.
- **HTTPS is out of scope unless the threat model changes.** No Caddy, reverse proxy, internal CA,
  certificate installation, pinning or certificate management is required. Reconsider TLS only if
  the network stops being trusted, the server becomes reachable from outside the LAN, or remote
  access is added; that is a separate decision.
- **No remote-access dependency.** Tailscale or a VPN is not required. Adding one later does not
  replace app-level authentication and must not create an unauthenticated mutation path.
- Do not build elaborate DNS-rebinding, public-IP-audit, packet-capture, Internet-disabled or
  general egress test programs as release gates. Basic tests still verify authentication and
  revocation, that no secret is logged, and that the app talks only to the paired LAN address
  rather than a public server.
- No analytics, telemetry, advertising SDK, remote crash reporting, cloud database, or automatic Internet fallback. Core features use the local Python server. The optional later PCC AI call is the only app-level non-local exception in scope, and is fully separate from core API traffic.

**Stop condition:** if the home network cannot be treated as trusted, or the server must be reachable from outside it, stop at the disposable Phase 1 spike and revisit transport (TLS or a private tunnel) before sending personal data. Do not invent custom cryptography.

## 8. Swift client structure

Keep the app simple and testable. The client lives in its own repository, not inside the server
repository; the owner's workspace holds the two side by side:

```text
strength-app/                    # workspace root; not itself a git repository
  strength-training-app/         # Python server and web UI (this repository)
  StrengthApp/                   # SwiftUI client (separate git repository)
    StrengthApp.xcodeproj/
    StrengthCore/                # local Swift package shared with watchOS (Phase 6)
      Sources/StrengthCore/      # models, API client, outbox, session engine
      Tests/StrengthCoreTests/
    StrengthApp/                 # iPhone app sources
      App/
      Features/
        Today/
        Readiness/
        Workout/
        History/
      Core/                      # iPhone view state and iOS-only services
      Networking/                # thin adapters over StrengthCore
      Persistence/
      HealthKit/                 # Phase 3, read-only readiness
      Tests/
    StrengthWatch/               # watchOS app target (Phase 6, planned)
      App/
      Features/
      HealthKit/
      Tests/
```

The two repositories are independent: separate history, remotes, CI and releases. A change that
crosses the API boundary lands in the server repository first, then in the client; there is no
atomic cross-repository commit.

Use SwiftUI views for presentation, small observable feature state for user interaction, one API client for DTO/network handling, and a local persistence component only when needed by the phase. Add protocol abstractions when they make a boundary testable or are used by multiple features; do not require a distinct repository, service, and use-case layer for every screen. Keep business rules in Python. The initial app can be mostly online and need not ship a complex local database/outbox.

Phase 6 moves the platform-neutral half into `StrengthCore`: models, the API client, the
outbox/journal and the session state machine. Both the iPhone and watch targets import it and keep
only platform services and views. The package must not import SwiftUI, UIKit, WatchKit, HealthKit
or WatchConnectivity (contract §6); platform differences are injected, not branched with
`#if os()`.

## 9. Tests and quality gates

Prioritize server contract/domain tests; keep UI tests focused and robust. Add coverage with each phase, not speculative tests for unimplemented features.

### Phase 1–2

- Pairing: one-use code, rejected invalid/reused code, auth required, revoked credential rejected, no secret in logs.
- Contract tests for each implemented versioned endpoint, date/timezone/units, useful validation/conflict responses, and stable server-issued plan reference.
- Prescription boundary: the client cannot submit plan content at all; an issued plan cannot be replayed, cross-used or started after expiry; an iOS request cannot enable a configured external LLM; existing web/CLI requests remain unchanged.
- Workout integration: start, set add, completion, duplicate/retry, explicit not-recorded sRPE, and history retrieval against temporary SQLite.
- Idempotency: the same operation id returns the stored result, a different body conflicts, and a retried start adopts the active workout instead of creating a second session.
- Manual iPhone acceptance: a normal session can be completed without opening the web app; accessible set entry and clear server-acknowledged save state.
- Run existing readiness, prescription, workout, history, session-feedback, docs-manifest and docs-consistency tests unchanged.

### Phase 3

Phase 3A: the contract's section 7 traceability and section 8 acceptance are authoritative; do
not duplicate that matrix here. The minimum gates are the observable states (featureDisabled,
unavailable, enabled, noEligibleSample, eligibleSample, staleSample, importError), manual-over-
HealthKit precedence through the canonical effective-readiness merge, sample identity and
single-flight import, authoritative refresh after acknowledgement, and no sleep/score changes.
Phase 3B, a separate contract, must additionally prove repeated workout import idempotency, no
inferred strength sets, separate ambiguous association, explicit Apple-effort provenance, manual
sRPE precedence and no prescription/rubric changes.

### Phase 4

- Kill/relaunch and disconnect at each queue state; verify durable ordering, idempotent retry, partial acknowledgement and visible conflict.
- A stale cached plan cannot authorize a new session; queued performed work is not presented as a fresh server prescription or completed server session.
- Manual corrections append; no queued mutation is silently dropped or duplicated.

### Phase 5

- Apple Intelligence is disabled by default. On-device and PCC choices are explicit; PCC requires a user action and context consent, has no automatic fallback, and is unnecessary for all core flows.
- Model-generated text/drafts cannot write a prescription, set, readiness score, RIR, form rating, rubric mark, or policy value without explicit user action and normal server validation.

## 10. Risks and decisions to settle during implementation

| Question/risk | Recommended handling |
|---|---|
| Target phone, OS, Xcode/signing | Confirm before Phase 1; keep the initial OS target to what the owner can run. Do not choose a higher OS solely for optional HealthKit effort or AI APIs. |
| Private server transport | Plain HTTP on the trusted home LAN, with no TLS, proxy, CA or certificate work; revisit only if the network stops being trusted or remote access is added. App authentication remains required. |
| Existing unauthenticated HTTP API | Add an authenticated versioned facade before iPhone mutations; do not retrofit/break existing web/CLI routes in this task. |
| Plan staleness or concurrent web use | Server validates at start and on mutation; return a clear conflict. Client refreshes and asks the owner, never silently overwrites. |
| Partial or missing readiness | Show the server's status and warnings; no Swift score and no missing-as-zero behavior. |
| Session RPE source | Manual remains first choice. Future Apple effort is source-labelled, only associated after confirmation, and usable only when no manual value exists. Current storage needs additive provenance. |
| Rubric use | Reuse server's current review payload and rubric version. Marks are human optional feedback; do not implement scoring or calibration logic in Swift. |
| HealthKit scope | HRV/RHR/bodyweight first; all other types later by explicit scope. No sleep/sleep score in this plan. |
| PCC privacy and availability | Separate future decision; disabled by default, user-invoked, context preview/consent, no health data by default, no core dependency. |
| Offline complexity | Defer durable offline mutation until an online session loop is proven. Cached reads do not imply the ability to prescribe or sync offline. |

## 11. Status and next task

Phases 0–2, Phase 3A, Phase 4, and the R1–R5/R7/R8 reliability work are complete. Phase 2 delivered
the online strength workflow (readiness write, server-issued prescription, start by issued-plan id,
active workout, add set, complete/abandon, session RPE, optional form ratings, history/progress,
manual VBT and idempotency receipts) under
[`design/IOS-PHASE-2-CONTRACT.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-PHASE-2-CONTRACT.md). Phase 3A is closed under
[`design/IOS-PHASE-3A-CONTRACT.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-PHASE-3A-CONTRACT.md); physical HealthKit acceptance
was owner-confirmed. Phase 4 is closed under
[`design/IOS-PHASE-4-CONTRACT.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-PHASE-4-CONTRACT.md); physical offline acceptance was
owner-confirmed.

Phase 6 (watchOS companion) has an agreed plan and contract
([`design/IOS-WATCH-CONTRACT.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-WATCH-CONTRACT.md)). Its 6.0 shared-core extraction,
6.1 server contract, 6.2a watch target and 6.2b credential handoff are complete; 6.2c (read-only
Today) and later are **not started** and need a separate go-ahead.

Phase 3B (Apple Workout summaries and related cardio data) remains a separate proposal and needs
its own approved contract. Phase 5 remains optional and separately approved. The agreed next plan
is Phase 6, starting at 6.2. R7 and R8 are recorded in section 4.30 and their contracts rather
than as pending next steps.

Do not begin Phase 3B, cardio, PCC or Phase 6.2c+ work without separate approval. Phase 4 is
closed; Phase 3B remains a separate contract; Phase 6 has 6.0–6.2b complete, with 6.2c+ planned
but not started.

## 12. References

### Existing application contracts

- [`API.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/API.md) — current routes, limits, local network security state and date semantics.
- [`READINESS.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/READINESS.md) and [`READINESS-SCORE.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/READINESS-SCORE.md) — readiness merge, manual precedence, baselines, score/gates.
- [`DATA-MODEL.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/DATA-MODEL.md) and [`DATA-QUALITY.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/DATA-QUALITY.md) — persisted fields, append-only records and missingness.
- [`METHODOLOGY.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/METHODOLOGY.md) — authoritative decisions and exclusions, including sleep/cardio boundaries.
- [`RUBRIC-CALIBRATION.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/RUBRIC-CALIBRATION.md) — current B1 review outcome and the limits/gates on interpreting rubric agreement.
- [`LONGEVITY-REVIEW.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/LONGEVITY-REVIEW.md) — evidence limits for any later descriptive display.
- [`REFERENCES.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/REFERENCES.md) #104–105 — session RPE context.

### Apple platform documentation for later phases

- [HealthKit data types](https://developer.apple.com/documentation/healthkit/data-types), [authorizing access](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data), and [HealthKit queries](https://developer.apple.com/documentation/healthkit/queries) — read permissions and query patterns.
- [HKWorkout](https://developer.apple.com/documentation/healthkit/hkworkout), [HKWorkoutEffortRelationship](https://developer.apple.com/documentation/healthkit/hkworkouteffortrelationship), [HKWorkoutEffortRelationshipQuery](https://developer.apple.com/documentation/healthkit/hkworkouteffortrelationshipquery), and [Workout Effort Score](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/workouteffortscore) — workout and effort records. Confirm API availability and source semantics against the selected OS/device at implementation time.
- [Protecting user privacy](https://developer.apple.com/documentation/healthkit/protecting-user-privacy) — HealthKit obligations.
- [Foundation Models](https://developer.apple.com/documentation/foundationmodels), [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel), and [Private Cloud Compute integration](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute) — optional later Apple on-device/PCC modes.
- [App Transport Security](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity) and [local-network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) — the app may need the documented local-networking allowance for plain-HTTP LAN access, depending on whether the server is addressed by IP or a .local hostname; confirm at implementation. A deployment setting, not an instruction to build a TLS stack.

## 13. Rollback gates

Every phase must be reversible without touching stored training history beyond the rows it added.

### 13.1 Backup precondition

The iOS migrations are applied to the owner's **single live database**, `data/coach.db`, the same
file the web UI and CLI use. A wrong or failed migration therefore has the whole training history as
its blast radius, not just the handful of rows the phase adds. There is no separate iOS database to
throw away.

Before applying any iOS migration to a live database, and before any rollback that drops tables:

1. Stop `strength-coach web` and any CLI run. While the server holds the database, SQLite keeps
   `data/coach.db-wal` and `data/coach.db-shm` beside it, and a copy of `coach.db` alone can miss
   committed transactions that still live only in the WAL.
2. Take a consistent backup through SQLite's backup API, never a raw file copy:
   `python tools/db_transfer.py export --db data/coach.db` (archive under `data/exports/`, which is
   git-ignored) or `python tools/backup_app.py`. `db_transfer` snapshots with
   `sqlite3.Connection.backup`, so WAL contents are included, and it refuses to import over a target
   whose `-wal`/`-shm` sidecars still exist.
3. Run `PRAGMA quick_check` against the snapshot and record the archive path and the
   `schema_migration` version in the phase's completion record.

This applies on the always-on host too, where `data/coach.db` is the live database the phone writes
to. A backup is a precondition of the phase, not an optional extra.

### 13.2 Schema rollback is a paired operation

Dropping the iOS tables alone leaves their `schema_migration` row in place. `migrate()` then treats
`0052`/`0053`/`0054`/`0055` as applied and skips them forever, so re-enabling the feature later
yields a database with no iOS tables and no migration that will recreate them. Roll a schema change back as
one operation, with the server stopped:

```sql
BEGIN IMMEDIATE;
DROP TABLE IF EXISTS healthkit_readiness;
DROP TABLE IF EXISTS ios_operation_receipt;
DROP TABLE IF EXISTS ios_issued_plan;
DROP TABLE IF EXISTS ios_pairing_code;
DROP TABLE IF EXISTS ios_device;
DELETE FROM schema_migration WHERE version IN ('0052', '0053', '0054', '0055');
COMMIT;
```

Order matters: `healthkit_readiness` and `ios_issued_plan` reference `ios_device`, so they are
dropped before the device table. Remove the Phase 3A canonical-merge integration before dropping
`healthkit_readiness`; do not leave code querying a dropped table. Removing the `schema_migration` rows is what makes a later re-apply work;
neither statement touches a training, readiness, prescription or workout row. Restoring the §13.1
backup is the fallback when the rollback itself went wrong.

| Phase | Rollback | What stays |
|---|---|---|
| 0 | Stop. No code, route or data. | Nothing. |
| 1 | Remove the iOS facade routes and delete device rows (§13.2); the existing server is untouched. | Nothing. |
| 2 | Disable the facade; the issued-plan and receipt tables are additive and can be dropped (§13.2). The web/CLI path never depended on them. | Prescriptions and workouts already committed remain valid. |
| 3A | Disable the feature and remove the canonical-merge integration; drop `healthkit_readiness` with the paired migration row (§13.2). Manual readiness and prior readiness history remain. | Manual entries and prior readiness history; no HealthKit observation survives. |
| 3B | Separate contract; not implemented by Phase 3A. | — |
| 4 | The queue is client-side; disabling it returns the Phase 2 online behavior. Server receipt rows can be pruned. | Any acknowledged server records remain. |
| 5 | Each enhancement is independently disableable; removing one leaves the core flows intact. | Everything core. |

Do not change the training methodology, existing web/CLI contracts, or stored append-only records
as part of a rollback.

### 13.3 Live-phone acceptance runbook (Phase 3A)

This is the canonical procedure for testing the opt-in HealthKit HRV/RHR/bodyweight slice on the owner's
physical iPhone against the live local server. It includes the database backup, migration,
pairing-code and rollback steps. The client checklist is
`StrengthApp/DEVICE-ACCEPTANCE.md` in the separate client repository; this section is the
server-side source of truth for commands.

Run it only on the trusted home LAN. Do not expose port 8000, forward it, or use a public
address. The database and backup contain health data.

#### 0. Set the shell variables

From the server repository:

```bash
cd /Users/georgesdib/Dev/strength-app/strength-training-app
export REPO="$PWD"
export DB="$REPO/data/coach.db"
export BACKUPS="$HOME/strength-app-backups"
export PORT=8000
```

If the server uses a different database path, set `DB` to that path before continuing.

#### 1. Stop the server and take a verified full backup

Stop the running `strength-coach web` process using the same method that started it (foreground
Ctrl-C, service manager, or the managed process). Confirm nothing is listening on the port before
backing up.

```bash
lsof -nP -iTCP:$PORT -sTCP:LISTEN || true
mkdir -p "$BACKUPS"
.venv/bin/python tools/backup_app.py "$BACKUPS"
```

Record the archive path and checksum. Verify it immediately:

```bash
LATEST=$(ls -t "$BACKUPS"/strength-training-app-*.tar.gz | head -1)
echo "$LATEST"
(cd "$BACKUPS" && shasum -a 256 -c "$(basename "$LATEST").sha256")
sqlite3 "$DB" "SELECT version FROM schema_migration ORDER BY version DESC LIMIT 1;"
```

The full archive includes a consistent SQLite snapshot plus source/docs/config and is mode 600,
but it is not encrypted. Keep it off the phone and out of git. Do not continue if the checksum or
snapshot verification fails.

#### 2. Apply migrations 0054/0055 and start the server

Start the server exactly as it is normally run. On startup it applies the additive
`0054_healthkit_readiness.sql` and `0055_healthkit_bodyweight.sql` migrations:

```bash
.venv/bin/strength-coach --db "$DB" web --host 0.0.0.0 --port "$PORT"
```

In another terminal, verify the schema and health:

```bash
sqlite3 "$DB" "SELECT version FROM schema_migration ORDER BY version DESC LIMIT 1;"
sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='healthkit_readiness';"
sqlite3 "$DB" "PRAGMA quick_check;"
```

Expected: latest version `0055`, one `healthkit_readiness` row from the table query, and
`ok` from `quick_check`.

#### 3. Mint a one-use pairing code

Get the server's LAN address (macOS example):

```bash
ipconfig getifaddr en0
```

Then mint a code:

```bash
.venv/bin/strength-coach --db "$DB" ios pair --label "iPhone Phase 3A"
```

The CLI prints a grouped 8-digit code (for example `1234 5678`) and a 300-second expiry. The code
is shown once, works once, allows five attempts, and is never written to the app log. Mint it only
when the phone is ready; if it expires, mint a new one. Do not paste the code into chat, a ticket,
a screenshot or a commit.

In the app:

1. If the phone is already paired, use the existing pairing; do not mint a code unless you are
   testing the pairing flow. To test a fresh pairing, use Settings -> Forget this device first.
2. On the Pairing screen enter the server URL, for example
   `http://<LAN_IP>:8000`, the code (spaces are accepted), and the label.
3. Tap Pair. A success returns to Today. An invalid, expired, reused or attempt-exhausted code
   stays on Pairing with the server's error.

#### 4. Build and install the physical client

From the client repository:

```bash
cd /Users/georgesdib/Dev/strength-app/StrengthApp
open StrengthApp.xcodeproj
```

Select the physical iPhone (iPhone 16 Pro Max, iOS 27.2 in the accepted environment), the personal
team, and Run. Confirm the local-network permission is allowed. The HealthKit capability is already
part of the app; Phase 3A adds only read access for HRV, resting heart rate and bodyweight.

#### 5. Enable HealthKit and import

1. Settings -> HealthKit -> enable **Readiness from HealthKit**.
2. Grant read access to HRV, Resting Heart Rate and Body Mass. Do not grant write access; the app does not
   request it. The permission sheet is not proof of a grant after it closes.
3. Return to Today and tap **Import from HealthKit** (or pull to refresh).
4. If no eligible sample exists, the UI must say that no eligible sample was returned and that
   this can mean no data or that read access was not granted. It must not say "denied" or show
   zero.

#### 6. Acceptance checks

- [ ] The HealthKit section appears only when the server reports `healthkit_readiness: true`.
- [ ] Enabling the toggle requests read access for HRV, resting heart rate and bodyweight only; no sleep,
      workout, general heart-rate or write access is requested.
- [ ] An eligible HRV sample is the newest within 48 hours; an eligible RHR sample is from the
      current server-local date.
- [ ] Today shows the effective HRV/RHR/bodyweight values, the effective source, sample age, and the
      score/status/basis returned by Python.
- [ ] The stored `healthkit` provenance is visibly distinct from the effective values; a manual
      value can win while the HealthKit observation is still shown.
- [ ] Importing the same sample twice does not create a duplicate observation (sample identity is
      device + field + sample UUID).
- [ ] A manual HRV/RHR/bodyweight entry made after an import remains selected after a later import.
- [ ] A stale sample or no sample does not appear as zero and does not silently become today's
      readiness.
- [ ] Partial availability is independent: HRV eligible + RHR stale, RHR eligible + HRV missing,
      both missing/stale, and both eligible each show the correct per-metric wording.
- [ ] If the POST succeeds but the authoritative GET fails, the import is accepted with a refresh
      error; no duplicate import is attempted.
- [ ] Force-quit/relaunch keeps the HealthKit toggle and the server remains the source of truth.
- [ ] No sleep, workout, cardio or Apple effort data is requested or displayed by this slice.
- [ ] The existing manual readiness, prescription, workout, completion and Progress flows still
      work.

Optional SQL spot checks while the server is stopped (use a read-only copy or accept that SQLite
allows a read while the server is running):

```bash
sqlite3 "$DB" "SELECT COUNT(*), MIN(on_date), MAX(on_date) FROM healthkit_readiness;"
sqlite3 "$DB" "SELECT field, value, source_class, sample_at FROM healthkit_readiness ORDER BY imported_at DESC LIMIT 5;"
sqlite3 "$DB" "SELECT COUNT(*) FROM readiness_entry;"
```

#### 7. Record and rollback

Record the archive path, checksum, schema version, device, iOS version, sample dates and the
result in the Phase 3A acceptance table. A rejected slice can be handled without touching manual
readiness:

1. Stop the server.
2. Turn the client HealthKit toggle off. The observations remain dormant and manual readiness is
   unaffected.
3. If a full schema rollback is required, remove the client importer and canonical-merge
   integration first, then drop `healthkit_readiness` and delete the `0054`/`0055` schema_migration
   rows together (§13.2). Do not leave code querying a dropped table.
4. If restoring the pre-test database is safer, extract only the snapshot from the verified
   archive and replace `data/coach.db` with the server stopped:

```bash
mkdir -p /tmp/strength-phase3a-restore
tar -xzf "$LATEST" -C /tmp/strength-phase3a-restore
cp /tmp/strength-phase3a-restore/strength-training-app/data/coach.db "$DB"
rm -f "$DB-wal" "$DB-shm"
```

Restoring the pre-test database also discards any training recorded after the backup. Do not do
that without checking. The additive table can otherwise remain while the client feature is off.

## Related server documents

- [`ROADMAP.md`](https://github.com/georgesdib/strength-training-app/blob/development/ROADMAP.md) §4.29 — approval status and phase tracking.
- [`WEB-UI.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/WEB-UI.md) and archived [`UI-MOBILE-AUDIT.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/archive/UI-MOBILE-AUDIT.md) — existing responsive client.
- [`DECISIONS.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/DECISIONS.md), [`PRIVACY.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/PRIVACY.md), [`OPEN-QUESTIONS.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/OPEN-QUESTIONS.md), and [`manifest.yaml`](https://github.com/georgesdib/strength-training-app/blob/development/docs/manifest.yaml).

## Completion state

**Phase 0 complete 2026-11-07. Phase 1 complete 2026-11-07. Phase 2 complete and closed
2026-11-07**, simulator-verified and owner-confirmed on the physical iPhone. Phase 3 requires its
own approved contract and has not started.

### Phase 1 completion record

- **Server:** migration `0052_ios_device`; the `strength-coach ios pair/devices/revoke` CLI; the
  bearer-authenticated, read-only `/api/ios/v1/` facade (`pair`, `bootstrap`, `today`,
  `history`, `progress`); `tests/test_ios_api.py`. The default suite is 1604 tests and
  `ruff` passes. Existing unversioned routes and stored training data are unchanged.
- **Client:** pairing, Today, History and Settings/Forget in the separate `StrengthApp`
  repository; Keychain token storage; 29 unit tests; optional live UI smoke test.
- **Verification:** the live test passed on the iPhone 18 Pro simulator against a temporary SQLite
  database; the owner then confirmed the device checklist on the physical iPhone. The checklist is
  `StrengthApp/DEVICE-ACCEPTANCE.md`.
- **Progress:** `GET /api/ios/v1/progress` is server-only in Phase 1 and is covered by the
  server contract tests. The client screens are Pairing, Today, History and Settings; a Progress
  screen is deferred to Phase 2 and was not added under the Phase 1 contract.
- **Post-acceptance remediation:** the redirect guard is now same-origin (scheme, host and effective
  port) and has dedicated unit tests for cross-port, scheme-changing, host, userinfo and
  delegate-rejection cases. The device pass preceded this transport-internal hardening.
- **Rollback:** drop `ios_device` and `ios_pairing_code`, remove the `/api/ios/v1/` routes and
  the `ios` CLI group, and forget/uninstall the client. No prescription, workout, readiness or
  review row is touched.
- **Residual limitations:** plain HTTP on the trusted LAN only; Phase 1 has no writes, HealthKit,
  offline capture, review or prescription UI; personal-team signing expires after 7 days.

### Phase 2 completion record

- **Server:** migration 0053_ios_workflow.sql; config/ios.v1.yaml; ios_config.py; the
  issued-plan/receipt store; the Settings -> iOS settings panel (validated atomic edit of
  `mutations_enabled`, issued-plan TTL, plan-request TTL and receipt retention; effective on the
  next request without a restart); authenticated readiness, prescription issue, start-by-id, add-set,
  form-rating, complete and abandon routes; tests/test_ios_workflow.py. The default suite is 1632
  tests and ruff passes. The normal prescription is persisted at issue. The phone starts by
  issued-plan id only and cannot supply prescription content. Every mutation requires a UUID
  Idempotency-Key with a 30-day receipt. The receipt lookup and mutation share one BEGIN IMMEDIATE
  transaction, so concurrent duplicates replay instead of executing twice; a receipt uniqueness
  race is re-read rather than returned as 500. The mutation switch fails closed to 503 while reads
  stay available.
- **Client:** readiness form, Workout ready card, active workout, optional manual mean velocity,
  optional form ratings, session RPE or explicit not-recorded completion, abandon, and the Progress
  screen; 43 unit tests at Phase 2 closure (51 after R1); optional live UI smoke tests; Release
  build passes. Plan-item attribution is sent only for a unique exercise; repeated exercises
  remain nil. Retry keys are body-aware, duplicate UI mutations are guarded, and an ambiguous
  finish locks the exact completion body.
- **Verification:** the live UI test passed on the iPhone 18 Pro simulator against a temporary
  SQLite database, covering pair -> readiness -> issue -> start -> add VBT set -> force-quit/
  relaunch recovery -> finish -> Progress. Lost-response and concurrent duplicate tests cover
  readiness, start, set and completion at the real HTTP boundary. The simulator test used a
  temporary SQLite database. The owner confirmed the physical-iPhone Phase 2 checklist on
  2026-11-07 (iPhone 16 Pro Max, iPhone17,2, iOS 27.2). The live data/coach.db is at schema 0053
  with both Phase 2 tables; PRAGMA quick_check returned ok. A post-acceptance backup is at
  data/exports/phase2-post-acceptance-2026-11-07.tar.gz
  (SHA-256 b919ae0283edef91e31ac1d1d2062537288258818ab707b527caee3be29db9d7), verified by a
  dry-run import.
- **Data/decisions at Phase 2 closure:** readiness is the accepted manual field set; the server owns
  load, sets and RIR; manual mean velocity is a performed observation only; the normal prescription
  tables remain the audit source; no plan editing on the phone; no offline queue, HealthKit or RPE
  coercion. Plan editing (R8), HealthKit readiness (Phase 3A) and offline capture (Phase 4) were added
  later under their own contracts.
- **Rollback:** set mutations_enabled: false; drop ios_issued_plan and ios_operation_receipt;
  remove the Phase 2 routes/client screens and forget the device. Prescriptions/workouts already
  committed by a started session remain valid.
- **Residual limitations at Phase 2 closure:** plain HTTP on the trusted LAN only; no HealthKit,
  offline capture or review screen; personal-team signing expires after 7 days. Phase 2 itself had no durable
  pending-mutation journal; that was added immediately after closure as R1 (see below). It is not
  a general offline queue: only attempted mutations are journaled, and new mutations are blocked
  while one is unresolved. R5 recovery/reconciliation UX is implemented and closed; R2 is closed
  as absorbed by R7's `plans/current` read; R7 is implemented and closed (unit, simulator and two
  live UI runs); R8 is closed; R4 is implemented and closed and is not a Phase 2 closure
  blocker.

### R1 durable pending-mutation journal (implemented and closed 2026-11-07)

R1 was implemented immediately after Phase 2 closure as a client-only reliability layer, then
closed by the owner on 2026-11-07. Verification is unit/simulator based; a separate physical R1
pass was not performed.

- The journal stores attempted operations in Application Support with iOS file protection and
  backup exclusion. Each entry carries the operation UUID, device/server, mutation kind, target
  workout or plan id, route, exact encoded request body, creation timestamp and pending/conflict
  state.
- An entry is written immediately before the HTTP request. A 2xx acknowledges and removes it;
  definitive 4xx responses remove it; transport/5xx keep it pending; an idempotency conflict marks
  it conflicted. On launch, pending entries replay with their original UUID and body, in order.
- The journal is capped at 16 entries, retained for 30 days, and auto-replayed only within
  28 days (inside the server's 30-day receipt window). Older entries become conflicts and require
  explicit discard/verification. New mutations are blocked while an unresolved entry exists.
- Today shows the pending operation with retry/discard actions. A conflict or terminal server
  response stops automatic replay rather than guessing.
- This is not an offline queue: only operations the owner actually attempted are recorded, and
  the cap/blocking prevent an unbounded queue. R4 is closed; R2 is closed as absorbed by R7.

Client tests: 55 (43 Phase 2 + 8 journal/recovery + 1 R3 plan-selection + 3 R5 recovery tests).
The normal live simulator workflow passes with the journal and recovery UI enabled. R1 is closed;
dedicated physical-iPhone R1/R3/R5 passes were not separately performed.

### R3 explicit plan-item selection (implemented and closed 2026-11-07)

- The active-workout add-set form lists every occurrence when the selected exercise appears more
  than once: Item 1, Item 2, etc., with sets/reps/load/RIR. The default is **Not attributed**.
- Selecting an item sends its `plan_item_index`; the backend already validates that the index
  matches the exercise. Selecting nothing keeps the safe nil attribution, and unique exercises
  continue to auto-attribute.
- Changing the exercise resets the selection. The existing set logging, idempotency and retry
  paths are unchanged.
- Unit verification covers repeated choices, unique auto-attribution and the nil fallback. R3 is
  closed; a separate physical-iPhone R3 pass was not performed.


### R5 workout recovery/reconciliation UX (implemented and closed 2026-11-07)

- On refresh, if the server has an active workout not represented locally, Today shows a Recovery
  section with **Resume server workout**, **Abandon server workout**, and **Dismiss**.
- If a local in-progress workout is no longer active on the server, Today shows that it may have
  been completed or abandoned elsewhere, with **Refresh server state** and **Clear local state**.
- If starting a prescription returns consumed/expired/superseded, the unusable prescription is
  cleared and a **Refresh server state** recovery state is shown instead of silently resetting.
- Unreplayable pending mutations continue to use the R1 pending-operation panel with retry/discard.
- A one-read grace after a local workout mutation prevents a false ended-elsewhere state before
  the next server read; the next refresh still reconciles an externally finished workout.
- Unit tests cover server-active discovery, ended-elsewhere detection and consumed-prescription
  recovery. The normal live simulator workflow passes. R5 is closed; a separate physical R5 pass
  was not done.

### R4 form-rating correction UX (implemented and closed 2026-11-08)

- Selecting an exercise that already has a rating shows **Current rating** and prefills the
  segmented picker with that value.
- A subsequent save is labelled **Save correction** and states that the earlier rating is retained
  in the append-only record while the latest is shown in the workout.
- The workout payload still returns only the latest rating per exercise; no database, API or
  history semantics changed.
- Unit coverage verifies the current-rating lookup; the simulator build and 72-test client suite
  pass.

### R7 asynchronous prescription request with workout settings (implemented and closed 2026-11-08)

**Contract:** [`design/IOS-R7-CONTRACT.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-R7-CONTRACT.md) — approved decisions, server
model, routes, polling, tests, acceptance and rollback.

R7 exists because the Phase 2 prescription route blocks: it calls `build_prescription` inside the
request handler, the resolver takes 35–46 s on the ODROID-C4, and the client times out at 10 s. The
request then fails visibly while the server completes it ~30 s later, leaving a pending journal
entry that blocks further mutations. R7 removes the blocking call and adds the workout settings the
owner asked for.

- **Settings before issuing:** session type (`auto` or an explicit type), the minimum-session
  fallback and an optional main-lift structure (`top_set` true for top set/back-off, false for
  straight sets, omitted for the server/resolver default), validated by the server and recorded as
  provenance. This amends the Phase 2 rule that only `auto` exists.
- **Non-blocking request:** `POST /api/ios/v1/prescriptions` validates the gates, writes a
  `queued` row and returns 202 immediately. One bounded dispatcher thread drains the queue on the
  shared CPU slot (`_CPU_JOB_SLOTS`, no second budget), re-checking eligibility before the slot and
  again before the build so a superseded or expired request never reaches the resolver; it
  publishes only if the row was not superseded meanwhile.
- **Legacy rows:** migration `0056` rebuilds the table and carries every existing plan forward with
  an explicit mapping (live → `ready`, consumed/superseded preserved, invalid rows abort the
  migration). Prescriptions and receipts are untouched.
- **Authoritative recovery:** on launch and foreground, `GET plans/current` decides what the app
  shows; a cached Today, a retained preview or a journalled response can never override it, and a
  superseded or expired plan is removed from the UI.
- **Durable state:** the request row is the job. `GET /api/ios/v1/plans/current` returns its
  status, server-computed age, and the plan when ready; this also closes R2.
- **Polling:** 1 s → 2 s → 5 s → 10 s, stopping only at a terminal state or the 15-minute request
  TTL. 60 s is a copy threshold ("still generating, you can leave"), not a failure, so a 90 s build
  completes normally.
- **App exit and return:** because the state is in the database, reopening the app finds a ready
  plan on the ready card, or resumes the counter from the server's elapsed seconds.
- **Persistence change:** prescription rows are written in the start transaction, not at issue, so
  an unstarted plan is a preview and parameter tweaking cannot pollute the prescription history.
- **Invalidation:** changing settings issues a new request that supersedes the previous row whatever
  its state; the superseded build finishes and is discarded by the guarded publish.
- **Implemented:** migration `0056`, `web/ios_plan_worker.py` (one dispatcher, two eligibility
  checks), the `202` issue route, `GET plans/current`, start-time prescription persistence and the
  client's settings sheet, generating card, polling and foreground reconciliation. The server
  behaviour is covered by the default suite; the client is built with an iOS 27.0 deployment
target and unit-tested on the available iOS 27.2 simulator (73 tests, 0 failures), launches, and passes the live UI flow against a throwaway
  server: pair → readiness → request workout → Workout ready → start → set → finish → Progress.
  That run found and fixed a real bug (the plan sheet was dismissed when the consumed plan made
  `plans/current` report `none`). A second run with the **resolver enabled** against a copy of
  the real database also passed: `202` in 0.1 s, plan ready in 4 s on the development host, full
  flow green in 90.9 s. Migration `0056` applied to that copy preserved all five legacy plan rows.

### R8 active-workout plan editing (closed 2026-11-08)

**Contract:** [`design/IOS-R8-CONTRACT.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-R8-CONTRACT.md) — scope, load rule, routes,
data effects, tests, acceptance and rollback.

R8 brings the web UI's existing live-workout edits to the phone: swap a plan item's exercise, add an
exercise, remove one, and change a set count. It supersedes the Phase 2 clause "no plan edits,
exercise swap, set-count change".

- Every edit runs through the existing `workout.py` services (`swap_exercise`, `add_exercise`,
  `remove_exercise`, `change_sets`); they rewrite `plan_modified_json` and append
  `workout_event` rows. The issued plan JSON is never modified, so prescribed and performed stay
  separately reconstructible.
- The phone never supplies a load or a replacement plan. Add sends only the exercise id and the
  service applies its defaults (3×8–12 @ RIR 2, no load); swap clears the load and records why.
  The owner enters the performed load when logging the set; R8 does not run the load solver.
- Exercise choice comes from an authenticated read-only `GET /api/ios/v1/exercises`; the app loads
  it while online. R8 does not add an offline queue; R1 journaling covers attempted edits only.
- Swap is blocked after sets are logged; set count cannot go below logged sets; the last item cannot
  be removed; ambiguous unattributed sets block edits. Removing an item with logged sets keeps those
  sets and warns first. An expected-exercise guard returns `409 plan_changed` instead of letting a
  stale index edit the wrong lift.
- A plan item's `order_index` is its stable identity across remove/swap/add; logged sets store it in
  `prescription_item_index`, so removing an earlier item does not renumber later attributions. The
  current display position is separate, and legacy positional rows use a same-exercise fallback.
- The web UI shares the service guards and returns 409 for rejected edits; it does not gain the
  iPhone picker or any new R8 screen.
- In progress only, idempotent, full workout payload returned; no schema change.

### Phase 3A — HealthKit HRV/RHR/bodyweight readiness (closed 2026-11-08)

- Server: migrations 0054_healthkit_readiness.sql and 0055_healthkit_bodyweight.sql, the
  append-only healthkit_readiness table, the
  shared effective-readiness merge (manual/preset > HealthKit > imported), and the authenticated
  POST /api/ios/v1/healthkit/readiness route. bootstrap reports healthkit_readiness alongside the
  existing capabilities; healthkit remains false for Phase 3B.
- Client: read-only HealthKit authorization for HRV SDNN, resting heart rate and bodyweight,
  deterministic Apple Watch classification, 48-hour HRV / current-day RHR / 30-day bodyweight
  selection, single-flight import, the healthkitReadiness mutation-journal kind, Settings opt-in
  and Today import/provenance display.
- Verification: 1,685 server tests, 102 client tests, simulator build and the live UI workflow pass.
  Physical HealthKit acceptance with real samples remains pending.
- Rollback: remove the client importer and canonical-merge integration, drop healthkit_readiness
  with the paired 0054/0055 migration rows, and leave readiness_day/readiness_entry untouched.

No Phase 3B, offline capture, HealthKit write access, sleep import, new score or training-rule
change is included. Each later phase requires a separate approval.

## Related

- **Client docs:** [docs/README.md](README.md), [README.md](../README.md), [USER-GUIDE.md](../USER-GUIDE.md), [DEVICE-ACCEPTANCE.md](../DEVICE-ACCEPTANCE.md)
- **Client agent rules:** [docs/AGENT-CONTRACTS.md](AGENT-CONTRACTS.md), [docs/AGENT-WORKFLOWS.md](AGENT-WORKFLOWS.md), [docs/AGENT-LIVE-TESTS.md](AGENT-LIVE-TESTS.md)
- **Server API:** [API.md](https://github.com/georgesdib/strength-training-app/blob/development/docs/API.md), [UI-MAP.md](https://github.com/georgesdib/strength-training-app/blob/development/docs/UI-MAP.md)
- **Server roadmap:** [ROADMAP.md](https://github.com/georgesdib/strength-training-app/blob/development/ROADMAP.md)

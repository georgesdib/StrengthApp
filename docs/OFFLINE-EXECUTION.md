# Unified offline execution — client implementation

This is the client-owned implementation note for the cross-repository plan
[Unified offline workout execution](https://github.com/georgesdib/strength-app/blob/offline-execution/docs/plans/UNIFIED-OFFLINE-EXECUTION.md)
(C1 and C2 of its MacBook handout). The plan and the iOS/watch contract stay canonical in the
portfolio repository; this file records only what the app does.

## C1 — S0 client

- **Technique throttle.** The request sheet has a main-work-only toggle. It is sent as
  `settings.technique_throttle`. The issued plan marks every item whose rationale refs contain
  `MOD-TECH-001` and explains that main-work loads were reduced for this session only. Accessory
  work is untouched by the server.
- **Execution identity.** `execution_id` is decoded from `POST /prescriptions` and
  `GET /plans/current`. It is stored with the cached plan and sent as `execution_id` on
  `POST /workouts`. A start from the cached plan also sends the athlete's `started_at`; a live
  start does not.
- **Cached plan.** The issued plan (plan body, execution id, warnings, readiness and the
  `load-catalogue/v1` catalogue) is stored in `OfflineCapture.cachedPlan`. It is cleared when the
  start is accepted or the plan is reported consumed/expired/superseded.
- **Catalogue prefill.** A substitution for an essential slot uses
  `round_down(base / (1 + (reps + rir) / 30), increment)`; an addition or non-essential slot uses
  the accessory value. Missing RIR falls back to plain Epley. Rounding is decimal, not binary
  floating point. The request carries `prefill_load_kg`, `prefill_catalogue_version` and
  `prefill_as_of`. A `prefill_verified: false` response is logged as a diagnostic; the value the
  athlete saw is never replaced.
- **Pending devices and finality.** Finishing a phone-owned workout names the watch in
  `pending_devices` when its events may still be missing. The report shows
  "Apple Watch data pending" and refreshes while `reconciliation.state == "open"`; it never treats
  those totals as final.

## C2 — S1 client

- **Capture version 2.** `OfflineCapture` decodes version 1 and migrates it in place (ledger
  fields filled, plan cache added as absent). The version-1 file is readable after an app update
  mid-workout.
- **Ledger entries.** Every queued write carries `entry_id`, `workout_id`, `device_id`,
  `device_seq`, `kind`, payload, local creation time, clock offset, plan watermark and
  acknowledgement state. The provenance falls back to the active session record, so a write queued
  by the watch or the phone is attributed even when the caller did not pass it explicitly. Entries
  are not aged out before acknowledgement; only an acknowledgement or a deliberate discard removes
  one.
- **Plan-only watch cache.** The phone sends a `WatchPlanCache` file with `transferFile`
  (`kind: plan_cache`), not the application context. The watch copies it to
  `Application Support/StrengthWatch/plan-cache.json` and can show and start a watch-targeted
  plan with no server connection.
- **Offline start.** On either device, a transport failure during start writes a local session
  under the plan's `execution_id` and queues a `start` ledger entry. The first sync calls
  `POST /workouts` with the original `started_at`; subsequent sets already target that id.
- **Ack-before-commit.** With the phone reachable, the watch commits a set through the existing
  phone relay and waits for its acknowledgement. No acknowledgement within three seconds leaves
  the set in the ledger as offline work; it is retried later under the same idempotency key.
- **Merge.** The phone merges a relayed set against its committed sets: a colliding
  `(exercise, set_index)` is renumbered after the current maximum in capture order, warm-up
  indexes `>= 1000` stay in their band, and device/plan provenance is retained. No set is rejected.
  The acknowledged server id is recorded in a per-device `LocalSetMap`. If the watch has to write
  directly to the server and receives `set_index_conflict`, it reads the active workout, renumbers
  the queued set the same way, and retries once instead of dropping it.
- **Late reconciliation.** The phone settles the window through
  `POST /workouts/{id}/reconciliation` when the watch reports nothing left to send. A refused late
  set (`409 reconciliation_window_closed`) remains visible on the device as unsent; the server has
  preserved it for audit only.

## Audit remediation (2026-11-23)

- **HealthKit writer policy (C3/D11).** The watch keeps its per-device finaliser keyed by
  `sessionUUID`. The phone now saves one HealthKit workout when it finishes a session, through a
  local writer that never deletes, merges or corrects a record and keeps no pending state. Both
  devices may save; training data still comes from the server's sets.
- **Execution-change payload.** Substitutions now render the replacement's own `set_groups`,
  `sets`, `top_set` and `vbt_target`/`vbt`; top-set eligibility is shown as
  `not_applicable · substituted`, never inherited from the planned lift.
- **Prefill protocol.** The legacy `prefill_requested` flag is gone. A catalogue value is sent
  with its version; a catalogue miss sends the version with no value; no catalogue sends neither
  and the server solves.
- **Corrections.** A set is corrected with one `POST .../update-set`; it keeps its `set_id`, so
  the merge map and telemetry stay attached. A `late_event_rejected` or
  `reconciliation_window_closed` response leaves the correction unsent and shown, never retried.
- **Plan binding.** `409 plan_not_bindable` clears the unusable cached plan and asks for a fresh
  one.

## Follow-up findings (2026-11-23)

- **Completed start replay.** If another pairing device completed a session before the watch
  flushed its offline start, the server now returns the existing workout for the same
  `execution_id` instead of `410 plan_consumed`; the watch drops the start and sends the queued
  sets through the late-reconciliation window.
- **Optimistic execution changes.** A substitution or addition is persisted and applied to the
  local execution view before the server answers, including its catalogue load, set groups, set
  cap and VBT target. A transport failure keeps it marked `pending`; a server rejection keeps it
  marked `rejected` and visible. The server response replaces it on acknowledgement.
- **Complete catalogue contract.** Swift decodes `dose_load_kg`, `dose_sets_cap` and
  `vbt_target`. A live erector dose wins over the ordinary base, caps sets and uses straight sets,
  matching Python's `prescription_from_catalogue`. Parity tests cover ordinary, dose and
  bodyweight/power entries.
- **Set origin.** Every set carries `origin_device_id`. The watch relay adds the watch id before
  the phone commits; the phone adds its own id on direct writes. The server validates that the
  origin belongs to the workout's pairing and persists it without changing the set key.

## S5 — pairing-scoped execution

- An issued plan belongs to the iPhone/watch pairing. The request screen no longer has a device
  picker and the client no longer sends `execution_target`.
- Either device in the pairing can start the plan. `owner_device_id` is provenance only.
- The phone no longer enters mirror mode: it can log, rate form, edit and finish whenever a session
  is open. The takeover button, its confirmation sheet and the takeover request are gone.
- The watch no longer turns read-only because another device owns the session.
- The watch keeps its read-only credential. Execution writes no longer go direct: the watch
  sends each start, set, correction, removal, form, event batch and finish to the phone, which
  commits it with its own credential. If the phone is unreachable the operation stays in the
  watch ledger for the next connection. Reads still use the watch credential.

## S3 completeness

The watch can log extra working sets beyond the planned groups, and phone-authored execution-change
additions appear in its plan and can be logged. The watch does not author a new exercise addition
(no watch-side catalogue picker); the performed set remains the durable record and the execution
change is a phone-side view hint.

## Status and accepted limitations

**Closed 2026-11-23.** Physical-device acceptance was closed by owner decision
([record](acceptance/device/14-offline-execution.md)); no separate §16 matrix run is claimed.
The server is deployed at `34e7f29`; the app build remains. Keep the old-app compatibility window short: until the new app ships, the old app cannot request a new plan or substitute.

Accepted limitations:

- Watch-authored **new exercise additions** remain phone-only; the watch can log extra sets and
  consume phone-authored additions.
- Watch execution writes need a reachable phone. The watch starts and logs offline, queues the
  writes, and sends them when the phone returns; the watch token is read-only for execution.
- The phone HealthKit save requires workout write permission granted through the HealthKit opt-in.
- The phone-committed watch relay cannot run while the watch app is suspended; queued work waits
  for the next active connection.

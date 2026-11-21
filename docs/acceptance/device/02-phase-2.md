_Part of the device acceptance record. Index: [DEVICE-ACCEPTANCE.md](../../../DEVICE-ACCEPTANCE.md). Content preserved verbatim._

# Phase 2 device acceptance checklist — completed 2026-11-07

**Status: accepted 2026-11-07.** The live simulator flow covered pair -> readiness -> issue ->
start -> add a manual-VBT set -> force-quit/relaunch recovery -> finish -> Progress against a
temporary SQLite database. The owner then confirmed the physical-iPhone Phase 2 checklist on the
iPhone 16 Pro Max (iPhone17,2), iOS 27.2. The live database is at schema 0053 with both Phase 2
tables; a verified post-acceptance backup is at
data/exports/phase2-post-acceptance-2026-11-07.tar.gz. The checklist below is retained as the
record of what was exercised.

## Before you start

- [ ] Take a consistent backup of the live database before applying migration 0053 (the plan in this
      repository, [iOS client plan](https://github.com/georgesdib/strength-app/blob/main/docs/plans/IOS-CLIENT-PLAN.md) §13.1); use a temporary database for the rehearsal.
- [ ] The server is running over plain HTTP on the trusted home LAN and is not Internet-reachable.
- [ ] config/ios.v1.yaml has mutations_enabled: true; bootstrap reports readiness_write,
      prescription and workout_write as true.
- [ ] Xcode 27.2, the personal team, the owner's iPhone and local-network permission are ready.

## Readiness

- [ ] Today offers Log readiness; the form shows the core five 1-5 fields, optional
      HRV/RHR/bodyweight/wearable and legacy labels, plus an optional note.
- [ ] Saving a partial check-in succeeds and missing fields stay missing.
- [ ] A value outside the server's range or an empty form shows a clear error and saves nothing.
- [ ] A second save with the same values is safe; a transport retry does not create a duplicate
      manual entry.
- [ ] The Today readiness score/status refreshes after saving.

## Prescription

- [ ] On a day without score-ready readiness, Start workout asks whether to start without a score;
      Cancel creates no plan; Start anyway creates one with the acknowledgement recorded.
- [ ] When the server asks for a scheduled deload or drop confirmation, the app shows the choice;
      Accept and Proceed without both produce a plan, and Cancel creates none.
- [ ] When the server finishes building, Today shows **Workout ready** with the session type,
      date, exercise count and any warnings. **Review workout** opens the full plan; no sheet opens
      automatically, and Start is only on the review screen.
- [ ] The plan is server-issued: the ready card and active workout show no editable load/set/RIR
      controls before logging.
- [ ] Issuing a second plan supersedes the first; starting the older plan is rejected.

## Start, workout and finish

- [ ] Start workout on the review screen opens the active workout directly and shows the plan and
      logged sets.
- [ ] Force-quit and relaunch with an active workout; Resume workout returns to the same workout
      and logged sets.
- [ ] Add a set with load, reps and RIR; the logged set appears with the same values.
- [ ] Add a set with an optional mean velocity; the logged row shows the value and it is not used
      to change the prescription.
- [ ] Add a set with optional per-rep velocities (comma/space separated); the logged row shows the
      rep summary and expandable rep velocities, with the mean derived if omitted.
- [ ] Rate form for an exercise, then record a correction: the current rating is shown, the button
      says "Save correction", and the earlier rating remains in the append-only record.
- [ ] Add an exercise from the plan menu: the online catalogue picker loads, and the added item has
      the server defaults (3 sets, 8–12 reps, RIR 2) with no invented load.
- [ ] Swap an exercise before logging sets; the replacement has no load. After logging a set, the
      swap action is disabled/explained.
- [ ] Lower a planned set count; it stops before going below the logged-set count. The last plan
      item cannot be removed.
- [ ] Repeating the same set request (for example after a lost response) does not duplicate it.
- [ ] Optional 1-5 form ratings save and survive a refresh.
- [ ] Finish with a session RPE 1-10; the workout completes, appears in History and contributes to
      Progress. Repeating the completion request does not create a second session.
- [ ] Finish with Session RPE not recorded; the session completes without inventing an RPE.
- [ ] An acknowledged completion opens the **Session report**; **Done** returns to Today and no
      second completion request is sent.
- [ ] The report shows adherence, velocity, session feedback, quality flags and evidence; a plan
      edited during the workout shows the original and final prescription; unavailable data shows
      its explicit reason rather than a zero.
- [ ] Stop the server after completion or corrupt the report read: the report shows **Report
      unavailable**, **Try again** retries only the read, and **Done** still leaves the flow.
- [ ] From History, open the completed session and tap **View session report**; the same report
      opens read-only. An imported session without a workout record explains why no report exists.
- [ ] When the summary carries a per-workout observation, the report shows **What stood out** with
      its gate, sample size and limitations; when the server returns none, the section is absent.
- [ ] Queue a finish offline; the app dismisses as before with no report. After sync, the report is
      available from History.
- [ ] Abandon asks for confirmation; the workout becomes abandoned, leaves the active state and
      cannot later be completed.
- [ ] Attempting to start while another workout is active shows a clear workout-active error and
      offers the active workout instead.
- [ ] The exercise screen shows the warm-up ramp including the empty-bar first set; a working set
      can be logged without logging any warm-up.
- [ ] Opening an exercise records nothing. The first **Start set** starts it, and leaving the screen
      without **End exercise** keeps it in progress.
- [ ] **End exercise** closes any running rest, records the completion, offers the optional 1–5 form
      rating with a skip, and returns to the plan list.
- [ ] Start a set on exercise A, go back and start a set on exercise B: both show **In progress**,
      starting B interrupts A's rest, and ending A leaves B open.
- [ ] Skip a warm-up's set and log a planned set: the swap and set-count controls stay available
      (a warm-up never counts as a planned set).
- [ ] Start a rest, return to Today: the countdown stays visible above the tab bar, then dismisses
      itself at zero.
- [ ] Lock the phone during a rest: the rest-end notification appears; **Done** clears it and
      returns to the app.
- [ ] Lock the phone during a rest: the Lock Screen shows a countdown (and the Dynamic Island on a
      supported iPhone) with the app closed; tapping it opens Strength.
- [ ] Add the **Strength** control to Control Center and to the Action button; both open the app.
- [ ] Force-quit during a rest, wait past its end, relaunch: the interval is recorded as completed
      at the time it actually ended.
- [ ] With Wi-Fi off, open Exercise Library and an exercise picker: the cached catalogue still lists
      and selects exercises; plan editing still reports that it needs the server.

## Progress and settings

- [ ] The Progress tab shows coverage, performance, weekly volume, attendance and back-symptom
      sections for the selected window.
- [ ] Changing 4/8/12/26/52 weeks reloads the dashboard; pull to refresh works.
- [ ] No Progress value is computed on the phone; it is the server dashboard.

## Failure, idempotency and the server switch

- [ ] With the server stopped, a mutation shows a clear error; the app does not claim the save.
      Retrying the same action after the server returns does not duplicate the plan, set or session.
- [ ] Force-quit after an acknowledged set and relaunch; the active workout and set are recovered
      through Today. Note the Phase 2 limitation: a response lost before acknowledgement cannot be
      replayed after termination because there is no durable pending-mutation journal (roadmap R1).
- [ ] Changing the plan's Idempotency-Key with a different body is rejected by the server; the app
      shows the conflict instead of silently discarding it.
- [ ] Set mutations_enabled: false, restart the server and refresh: bootstrap/read screens still
      load, training controls are disabled and every write returns the disabled message. Reads
      still work; restore the flag afterwards.
- [ ] 401/403 after revoking the device returns to Pairing and deletes the local token.

## Secrets and rollback

- [ ] Neither the bearer token nor an Idempotency-Key appears in the server application log, the
      web Logs page or an error body.
- [ ] The token remains only in the iPhone Keychain; Forget deletes it.
- [ ] Rollback rehearsed: set mutations_enabled: false, then (with the server stopped and a backup
      taken) drop ios_operation_receipt and ios_issued_plan and delete the 0053 schema_migration
      row. Existing prescriptions/workouts from a started session remain valid.

## Sign-off

| Check | Result | Notes |
|---|---|---|
| Readiness entry and validation | pass | owner-confirmed 2026-11-07 |
| Prescription gate/confirmation/Workout ready | pending | revised 2026-11-08 |
| Start, resume and single-use plan | pass | owner-confirmed 2026-11-07 |
| Add set incl. manual velocity | pass | owner-confirmed 2026-11-07 |
| Form rating | pass | owner-confirmed 2026-11-07 |
| Completion (RPE and not recorded) | pass | owner-confirmed 2026-11-07 |
| Abandon | pass | owner-confirmed 2026-11-07 |
| Progress | pass | owner-confirmed 2026-11-07 |
| Retry/idempotency and disabled switch | pass | owner-confirmed 2026-11-07 |
| Force-quit/relaunch recovery | pass | acknowledged set recovered; R1 journal covers attempted unacknowledged operations (post-acceptance; R1 closed without a separate device pass) |
| Secrets and rollback | pass | owner-confirmed 2026-11-07 |

Owner confirmation: 2026-11-07  ·  Build: Phase 2  ·  Device: iPhone 16 Pro Max (iPhone17,2),
iOS 27.2  ·  Simulator: iPhone 18 Pro, iOS 27.2
---

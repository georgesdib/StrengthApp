# Phase 1 device acceptance checklist — completed 2026-11-07

**Result: complete.** The owner confirmed the Phase 1 pass on their physical iPhone (iOS 27.2;
the connected device reports iPhone 16 Pro Max, iPhone17,2) against the local server on the home
LAN. The simulator pass used the iPhone 18 Pro. The checklist below is retained as the record of
what was exercised. A later transport-internal remediation hardened the redirect guard to
same-origin (scheme, host and effective port); it is covered by unit tests and does not change the
normal LAN path.

Phase 1 is read-only: if a check would require writing a readiness day, starting a workout or
requesting a prescription, it is out of scope.

## Before you start

- [ ] Xcode 27.2 is selected (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
- [ ] The server is running on the home LAN over plain HTTP and is **not** reachable from the
      Internet. No port-forwarding, VPN, TLS proxy or certificate is required.
- [ ] The server database is the intended one. For a rehearsal, use a temporary database
      (`strength-coach --db /tmp/rehearsal.db web --host 0.0.0.0 --port 8000`); never point a
      rehearsal at the live `data/coach.db`.
- [ ] The iPhone and the server are on the same trusted network.
- [ ] `StrengthApp` is selected, the personal team is set, and the build targets the owner's iPhone.
- [ ] The app's local-network permission is allowed in iPhone Settings if it was previously denied.

## Pairing

- [ ] `strength-coach --db <db> ios pair` prints one grouped 8-digit code and an expiry.
- [ ] The app's Pairing screen shows the server address, a code field, the optional label and a
      Pair button. Release starts with an empty address; Debug prefills `http://127.0.0.1:8000`.
- [ ] A malformed code shows an inline error and creates no device.
- [ ] A wrong code shows the server's 401 message and creates no device.
- [ ] An expired or already-used code shows the 410 message and creates no device.
- [ ] Five failed attempts exhaust the code (429); mint a new code to continue.
- [ ] A valid code pairs once, creates exactly one device, and returns to Today.
- [ ] Pairing the same code a second time is rejected (410).

## Today and History

- [ ] Today shows the **server-local** date, not a UTC slice.
- [ ] Today shows the readiness status, score, basis, overrides and context flags returned by the
      server; an unknown/insufficient day is not shown as a zero score.
- [ ] Today shows "No active workout" when none is open; if one is open, its summary is shown.
- [ ] Pull to refresh updates the screen; a server stop shows a clear error, not fabricated data.
- [ ] History loads the default page, shows date/session type/sets/tonnage/lifts, and "Load more"
      appends older sessions without duplicates.
- [ ] Empty history shows the empty state; a server error shows the retry state.

## Persistence and local forget

- [ ] Force-quit and relaunch the app; it opens Today without asking for the code again.
- [ ] Settings shows the server URL, device label/id and app version.
- [ ] "Forget this device" asks for confirmation, deletes the local token, and returns to Pairing.
- [ ] After Forget, the server still lists the device (`strength-coach ios devices`) until it is
      revoked or re-paired.
- [ ] Pairing again with a new code works and replaces the Keychain item.

## Server-side revocation

- [ ] `strength-coach ios devices` lists the device id, label, created, last seen and revoked.
- [ ] `strength-coach ios revoke <device_id>` sets the timestamp; a second revoke is a no-op.
- [ ] On the phone, a read after revocation returns to Pairing with the device-revoked message.
- [ ] A revoked device cannot read Today or History, even with the old token.
- [ ] Re-pairing after revocation creates a new device row and works.

## Secrets and logs

- [ ] The pairing code is printed only by the CLI; neither the code nor the token appears in the
      server application log or the web Logs page.
- [ ] Error bodies never contain the code or token.
- [ ] The token is not in UserDefaults, a file, a crash report or an analytics payload.
- [ ] The token is in the iPhone Keychain only, and `Forget` deletes it.
- [ ] The app talks only to the entered server address; there is no public/cloud fallback.

## Existing server behaviour

- [ ] The existing web UI still loads and works without an iOS token.
- [ ] Existing `/api/*` routes behave as before; only `/api/ios/v1/*` requires a bearer token.
- [ ] No prescription, workout, readiness or review behaviour changed.

## Rollback

- [ ] Forget the device on the phone.
- [ ] Revoke the device on the server.
- [ ] If the whole phase is being withdrawn: drop `ios_device` and `ios_pairing_code`, remove the
      `/api/ios/v1/` routes and the `ios` CLI group. No training, readiness, prescription or
      workout row is touched.

## Sign-off

| Check | Result | Notes |
|---|---|---|
| Pairing and rejection paths | pass | owner-confirmed 2026-11-07 |
| Today readiness/date | pass | owner-confirmed 2026-11-07 |
| History paging | pass | owner-confirmed 2026-11-07 |
| Relaunch persistence | pass | owner-confirmed 2026-11-07 |
| Forget and re-pair | pass | owner-confirmed 2026-11-07 |
| Server revocation | pass | owner-confirmed 2026-11-07 |
| No secrets in logs | pass | owner-confirmed 2026-11-07 |
| Existing web/API unchanged | pass | owner-confirmed 2026-11-07 |
| Device/build/signing | pass | owner-confirmed 2026-11-07 |

Owner confirmation: 2026-11-07  ·  Build: Phase 1  ·  Device: iPhone 16 Pro Max (iPhone17,2),
iOS 27.2  ·  Simulator: iPhone 18 Pro, iOS 27.2

---

# Phase 2 device acceptance checklist — pending

**Status: simulator-verified 2026-11-07; physical-iPhone acceptance pending.** The live simulator
flow covered pair -> readiness -> issue -> start -> add a manual-VBT set -> finish -> Progress
against a temporary SQLite database. Run this checklist on the physical iPhone against a rehearsal
database before treating Phase 2 as accepted.

## Before you start

- [ ] Take a consistent backup of the live database before applying migration 0053 (the plan in the
      server repository docs/IOS-CLIENT-PLAN.md §13.1); use a temporary database for the rehearsal.
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
- [ ] The preview shows the session type, date, expiry, readiness summary, plan items (sets, reps,
      load, RIR/quality) and warnings.
- [ ] The plan is server-issued: the phone shows no editable load/set/RIR controls in the preview.
- [ ] Issuing a second plan supersedes the first; starting the older plan is rejected.

## Start, workout and finish

- [ ] Start workout opens the active workout directly and shows the plan and logged sets.
- [ ] Force-quit and relaunch with an active workout; Resume workout returns to the same workout
      and logged sets.
- [ ] Add a set with load, reps and RIR; the logged set appears with the same values.
- [ ] Add a set with an optional mean velocity; the logged row shows the value and it is not used
      to change the prescription.
- [ ] Repeating the same set request (for example after a lost response) does not duplicate it.
- [ ] Optional 1-5 form ratings save and survive a refresh.
- [ ] Finish with a session RPE 1-10; the workout completes, appears in History and contributes to
      Progress. Repeating the completion request does not create a second session.
- [ ] Finish with Session RPE not recorded; the session completes without inventing an RPE.
- [ ] Abandon asks for confirmation; the workout becomes abandoned, leaves the active state and
      cannot later be completed.
- [ ] Attempting to start while another workout is active shows a clear workout-active error and
      offers the active workout instead.

## Progress and settings

- [ ] The Progress tab shows coverage, performance, weekly volume, attendance and back-symptom
      sections for the selected window.
- [ ] Changing 4/8/12/26/52 weeks reloads the dashboard; pull to refresh works.
- [ ] No Progress value is computed on the phone; it is the server dashboard.

## Failure, idempotency and the server switch

- [ ] With the server stopped, a mutation shows a clear error; the app does not claim the save.
      Retrying the same action after the server returns does not duplicate the plan, set or session.
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
| Readiness entry and validation | pending | |
| Prescription gate/confirmation/preview | pending | |
| Start, resume and single-use plan | pending | |
| Add set incl. manual velocity | pending | |
| Form rating | pending | |
| Completion (RPE and not recorded) | pending | |
| Abandon | pending | |
| Progress | pending | |
| Retry/idempotency and disabled switch | pending | |
| Secrets and rollback | pending | |

Owner confirmation: pending  ·  Build: Phase 2  ·  Device: iPhone 16 Pro Max (iPhone17,2),
iOS 27.2  ·  Simulator: iPhone 18 Pro, iOS 27.2

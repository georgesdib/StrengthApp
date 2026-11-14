# Watch acceptance — owner-run (6.2b–6.7)

**Status: not yet performed.** This script is for the owner's physical iPhone + Apple Watch. A
simulator build is not proof of WatchConnectivity delivery, Keychain isolation or watch installation.

## Before you start

- [ ] Use a disposable server/database, not the live `data/coach.db`.
- [ ] The server is reachable from the iPhone on the home LAN and has `watch_enabled: true` in
      `config/ios.v1.yaml` (restart is not required; it is read per request).
- [ ] Build and install the current `StrengthApp` on the physical iPhone and `StrengthWatch` on the
      paired Apple Watch. Keep both apps installed.
- [ ] The iPhone is paired with the server (Today loads) and **Settings → Home Server** is the
      reachable LAN address. Do not use the Away address.
- [ ] Note the iPhone's device id in **Settings → This device**.
- [ ] Optionally set Prefer Home Server off so the active iPhone route is Away while Home remains
      configured. Watch Pair/Replace/Revoke must still target Home; it must never mint against Away.
- [ ] With Home unreachable and Away active, Pair/Replace must show a Home error and create no
      watch device on Away.

## Pair and handshake

- [ ] On the watch, open Strength. It says **Open Strength on your iPhone to pair.**
- [ ] On the iPhone, **Settings → Apple Watch** shows *Not paired* and enables **Pair Apple Watch**.
- [ ] Tap **Pair Apple Watch**. The status becomes *Waiting for Apple Watch*.
- [ ] Within a few seconds, the watch shows **Ready** with the Home host, and the iPhone shows
      **Paired** with a *Last acknowledged* time.
- [ ] Lock the watch, unlock it, and foreground both apps. The status remains Paired; it does not
      mint a second watch device.
- [ ] Force-quit and relaunch the iPhone app. Settings still shows Paired, without asking for a new
      pairing code.
- [ ] On the server, `strength-coach ios devices` shows exactly one active watch whose
      `parent_device_id` is the iPhone device id. It has a credential epoch and no plaintext token.

## Config-only refresh

- [ ] Change the Home Server to another address that reaches the same disposable server, then tap
      **Save server settings**.
- [ ] Foreground both apps. The watch updates its displayed host; the phone does not report
      **Paired** until the watch acknowledges that Home URL and the current desired
      `configVersion`.
- [ ] Make the watch acknowledge an older Home URL (for example by changing Home while the watch
      is unreachable). The phone must re-baseline its configuration version, send the new URL, and
      become **Paired** only after the matching acknowledgement. It must not report Ready while
      the old URL remains.
- [ ] Simulate a phone reinstall/configVersion reset while watch metadata survives. A watch
      acknowledgement ahead of the phone's version must cause a bounded re-baseline and converge,
      not a permanent version deadlock.
- [ ] Restore the original Home Server and save again.

## Revoke and deliberate suppression

- [ ] On the iPhone, **Settings → Apple Watch → Revoke Apple Watch**, confirm.
- [ ] The iPhone status becomes *Revoked*; the watch shows *Watch unpaired* (or clears Ready when it
      next receives the context).
- [ ] On the server, the watch row is revoked. Its old token is rejected with 401/403.
- [ ] Foreground both apps several times. The phone must **not** automatically mint a replacement
      watch; status stays Revoked.
- [ ] Tap **Pair Apple Watch** again. A new watch device with a higher credential epoch is created,
      the old one stays revoked, and the watch returns to Ready.

## Phone revocation cascade

- [ ] Revoke the iPhone device on the server with the CLI (or re-pair the iPhone).
- [ ] Confirm the iPhone's active child watch is also revoked in the same operation
      (`revoked_watch_ids` in the DELETE response; the CLI prints `revoked watches:`).
- [ ] The old watch token cannot read any `/api/ios/v1/*` route.
- [ ] A revocation context naming a different watch device is ignored; it must not clear the
      current watch token.

## Failure and recovery

- [ ] Start Pair with the watch app closed. The status may stay *Waiting for Apple Watch*; opening
      the watch app or foregrounding both apps completes the handshake or reports missing
      credentials.
- [ ] Kill the iPhone app after minting but before the ack, then relaunch. It may show Waiting; the
      tokenless probe either gets a re-ack or the watch reports missing and the phone mints a new
      epoch.
- [ ] Leave the watch with stale metadata (a different device id or an older epoch) and no token,
      then pair the phone's current credential. The watch adopts the current device/epoch as
      **missing**, clears the stale token, and the phone mints once; it must not loop on an old
      acknowledgement.
- [ ] Leave the watch with a valid old token while the phone expects a newer device/epoch. The watch
      re-acks the old credential; the phone mints a fresh epoch (at most twice in one foreground),
      sends the token, and the new token replaces the old one.
- [ ] A tokenless probe must never create a new Ready state or grant API access; only a
      token-bearing new lineage can replace a valid old token or a revoked credential.
- [ ] Move the watch to a second iPhone (or re-pair with a new phone device). A token-bearing
      credential for the new device identity must establish the new lineage even if its epoch is
      numerically lower. A same-device stale token at the old epoch must remain rejected, and a
      cross-device revocation must not clear the current link.
- [ ] Turn off Wi-Fi on the watch (or move it out of range) and change the Home Server. The watch
      keeps its old Home URL and does not switch to Away; it updates when it can reach the phone and
      the new Home server.

## Read-only Today (6.2c)

- [ ] On the iPhone, request a workout and choose **Apple Watch** as the device. The request uses
      `execution_target: "watch"`; the iPhone shows the watch-targeted notice and no Start button.
- [ ] Open Strength on the watch. It shows the session type, date, exercise items with
      sets/reps/load/RIR/rest, warnings and **Read-only preview**.
- [ ] The watch has no Start, Log set, Finish or edit control.
- [ ] Tap Refresh on the watch to update the plan. Foregrounding the watch also refreshes it.
- [ ] Request a plan for the iPhone. The watch shows "This workout is planned for iPhone" and does
      not display the phone-targeted plan body. A plan with a missing or unknown target shows the
      unsupported-target message and no prescription details.
- [ ] With no plan, the watch shows "No workout for Apple Watch."
- [ ] Kill the watch app and relaunch while offline. It does not fabricate a plan; it shows the
      connect-to-home message rather than a stale persisted plan.
- [ ] Revoke the watch credential while the watch is open, then refresh. The watch clears its token,
      shows the pairing instruction, and does not retry in a loop.
- [ ] Stop the Home server, then refresh. The watch shows an offline/Home error; it does not fall
      back to Away and does not display the phone's current plan as a watch plan.

## Secrets and cleanup

- [ ] The watch token never appears in the iPhone logs, UserDefaults, a file or a crash report.
- [ ] The watch token is in the watch Keychain only; non-secret metadata may be in UserDefaults.
- [ ] Forget the iPhone device and revoke the disposable watch; stop and delete the disposable
      server/database.


## Execution lifecycle (6.3) — owner-run

**Status: not yet performed.** Requires the watch build; a simulator is not proof of liveness,
suspension or the Digital Crown.

- [ ] Request a plan for **Apple Watch**; the watch shows **Start on Apple Watch**.
- [ ] The first start asks for Health access. Allowing it starts the session; denying it must
      refuse to start and point to logging on the iPhone instead.
- [ ] Start: the watch shows the **exercise list** with every prescribed exercise and its
      "0 of n" progress.
- [ ] Tap an exercise: its screen shows "Set 1 of n" and the target load × reps @ RIR, with
      **Start set**, **End exercise**, and **Add set** only once you are on the last prescribed set.
- [ ] Lower the wrist for a minute, then raise it. The screen wakes on the same set, elapsed time
      has advanced, and nothing was lost.
- [ ] With Wi-Fi off, **Start set** and adjust load, then force-quit before ending the set.
      Relaunch: the running set returns with the same load and reps, not the prescription's.
- [ ] **Start set**: the screen becomes the running set with a set timer; adjust load with the
      Digital Crown (±2.5 kg) and reps with −/+.
- [ ] **End set** opens the RIR sheet (prescribed default, 0–6, *Not recorded*). Saving captures
      the set as pending, then clears once the home server acknowledges it.
- [ ] The rest bar appears and survives a wrist drop. **+15s** extends it and **−15s** shortens
      it (ending the rest when that is all that remains); it stays until tapped.
- [ ] **Add set** on the last prescribed set starts an extra set prefilled with the previous
      values; the list counts it without changing the prescription.
- [ ] **End exercise** returns to the list with the completed sets; starting exercise 2 before
      exercise 1 works and the server's telemetry shows both blocks separately.
- [ ] The phone adds or removes an exercise: as of 6.6 the watch's plan refreshes at the next
      idle point (see W4/W5); nothing on the watch breaks.
- [ ] Let the countdown reach zero: it reads **Rest complete**, a local notification fires if
      permission was granted, and the rest itself stays open until the next set.
- [ ] Start the next set without ending the rest: the rest closes at that moment and the set is
      logged. There is no rest-skipped state anywhere.
- [ ] Background the app for several minutes mid-session, return, log a set: elapsed time and
      rest state are correct.
- [ ] Force-quit mid-session and relaunch: the session resumes with the same sets and pending
      count, and nothing is duplicated.
- [ ] Turn off Wi-Fi mid-session and log two sets: both are captured, the banner reads
      offline · n pending, and nothing claims to be saved.
- [ ] Re-enable Wi-Fi: pending work flushes in order (the set, then its events), once each.
- [ ] While a session is running, turn Health access off for the watch app, then foreground it:
      the Set screen shows **Logging may stop when the screen locks.**, and logging a set still
      persists. Turn access back on and foreground again: the message clears.
- [ ] **Done with exercise** while resting: the rest closes and the next exercise's start is
      later; the server shows one `exercise_completed` and a gap before the next
      `exercise_started`.
- [ ] Finish while a rest is open: the server receives a terminal `rest_completed` at the finish
      time, never an unterminated rest.
- [ ] Finish while a set is started but not logged: no `set_started` is recorded for it.
- [ ] Finish while offline with an sRPE. "Finish saved on watch — syncing" persists; reopen at
      home and the server shows one completed session with the original end time.
- [ ] **Discard session** on the finish screen asks for confirmation, abandons the server session
      and clears the local record.
- [ ] Server: `workout_execution_event` holds `set_started`, `set_completed`,
      `rest_started`, `rest_completed` and any `rest_extended` rows with the original
      `occurred_at`; no `rest_skipped`; a synced `set_completed` carries `set_id`.
- [ ] HealthKit: **no workout is saved in 6.3** (that is 6.5); only the liveness session exists.


## Reconciliation and conflicts (6.4) — owner-run

**Status: not yet performed.** Needs a phone and a watch, and a disposable server.

- [ ] Watch targets a plan, starts, logs one set, then **turn Wi-Fi off**.
- [ ] On the phone, swap the next exercise in the plan. Back on the watch, log a set against the
      item that was swapped, then turn Wi-Fi on.
- [ ] The pending set flushes first, comes back as **off-plan** with the set preserved (same
      exercise, load, reps, RIR and time), the summary shows the "plan changed while offline"
      note, and the server's telemetry carries the original item index.
- [ ] Once the watch is idle, **Plan updated** appears and the labels refresh with the phone's
      plan, including a newer `plan_revision`; nothing changes under a set in progress.
- [ ] With a set in progress, the phone edits another item: the current target does not move until
      the set is logged.
- [ ] Phone **Take over logging**: the watch's next foreground shows **Logging moved to the
      phone**, adds no sets, and **Clear record** removes the local copy without abandoning the
      session.
- [ ] Phone finishes the workout while the watch is offline: the watch shows **Session ended
      elsewhere**, keeps the local summary, and clears without recreating anything.
- [ ] Change **Home Server** on the phone while a session is active: the watch keeps the old host,
      finishes and syncs, then adopts the new host after the queue is empty.
- [ ] A delayed older snapshot (cached revision below the current one) never overwrites the plan.


## Phase 6.4 corrective fixes — owner-run

- [ ] **Navigation gate:** start a set in an exercise. The back chevron to the list is gone; it
      stays gone between sets and after logging, and returns only after **End exercise**.
- [ ] Selecting a second exercise while the first is active does nothing; after End exercise the
      list opens and the second exercise starts normally.
- [ ] **Offline set then phone edit:** with Wi-Fi off, log a set, then edit that plan item on the
      phone and reconnect. The queue still holds the set, and **Plan updated** applies once the
      set is committed — the next exercise uses the new plan.
- [ ] **Single flight:** with a slow or flaky home server, force a reconnect during a session and
      confirm each set appears once, in order, with no duplicate rows on the server.
- [ ] **Clock:** on a watch whose clock is several minutes off, set duration and the rest countdown
      stay correct and match the session elapsed time.
- [ ] **Ownership:** a session whose ownership cannot be confirmed shows read-only, keeps its
      queued sets, and becomes writable again only after a reconciliation confirms this watch.


## Heart rate and HealthKit (6.5) — owner-run

- [ ] Start a watch session with workout and heart-rate read access allowed: the Set screen shows a
      live **bpm** while the wrist is raised, and it disappears if HR is not authorised.
- [ ] Log a couple of sets, finish with an sRPE, and confirm Health holds **exactly one**
      strength-training workout with the real start and end, the session's effort, and HR samples.
- [ ] Repeat with HR read **denied**: the workout still saves, with no HR.
- [ ] Finish, then force-quit before the watch syncs. Relaunch: the summary returns, Health still
      shows exactly one workout, and the server finish replays once.
- [ ] Mid-session, force-quit and relaunch, then finish: Health holds one workout with the original
      start, with **no HR** for the pre-crash segment (the documented trade).
- [ ] Deny Health access mid-session, finish: the workout reports **not saved** once, with
      **Try again** and **Dismiss**; Try again after re-allowing access saves the same workout
      once, and Dismiss removes the notice without changing the record.
- [ ] Abandon a session: Health gains no workout.
- [ ] The Health app shows the effort value matching the chosen sRPE, and nothing when
      *Not recorded* was chosen.


### Corrective checks (6.5 audit)

- [ ] Watch clock set five minutes fast, start and finish a session: the Health workout's start and
      end are the real times, and its duration is not negative or shifted.
- [ ] With Health access denied mid-session, finish: the summary reports the workout was **not
      saved**, and Health holds no duplicate after retrying later.
- [ ] Force-quit during finalisation, relaunch with the server finish still pending: the watch does
      **not** create a new live workout; Health gains either the existing workout or one minimal
      backdated one — never two, and never one that starts at relaunch time.
- [ ] Deny effort write while allowing workouts: the workout saves, and the summary says
      **Effort was not saved** without retrying the workout.
- [ ] Leave the watch still with HR shown: the value disappears within ~30 seconds when readings
      stop, and never shows 0 for "no data".



---

# Phase 6.6/6.7 watch acceptance checklist — owner-confirmed 2026-11-14

**Status: physical half run and confirmed by the owner on 2026-11-14**, build `8c26af0`, Apple Watch
Ultra 4. The run surfaced real defects that were fixed during it (the finish idempotency key, the
session-report decode, the split Today buttons); those fixes are post-acceptance commits and are listed
below the sign-off rather than reopening the phase. Automated coverage is listed in
[WATCH-6.6-PLAN.md](docs/WATCH-6.6-PLAN.md) and contract §17; the simulator UI smoke
(`StrengthWatchUITests`) covers fetch → start → log → finish.

**W11** patchy Wi-Fi and **W12** home config refresh were confirmed in the same run. Only **R**
(rollback dry run) remains a follow-up.

## Before you start

- [ ] Development server is reachable on the home LAN; `watch_enabled: true`; migration 0058 applied.
- [ ] Phone paired; watch paired and listed as the one active watch device; HealthKit workout
      authorisation granted on the watch.
- [ ] Seed today's plan through the API with `execution_target: watch` (not the UI), and keep the
      phone app closed except where a step needs it.
- [ ] A watch-owned session has not already been left idle; abandon or finish any leftover session
      so the 24h abandonment path cannot interfere.
- [ ] Record the StrengthApp commit SHA under test before starting.
- [ ] Install the watch app from that build: run `./scripts/install-watch.sh` after building the
      StrengthApp scheme for the iPhone, or confirm the watch already runs the same build.

## W1 — Delayed or failed credential delivery (§17.1)

- [ ] Fresh pair; the watch shows the Today plan once and settles on `Paired` without churn.
- [ ] Revoke the watch from the phone; the watch reports credentials missing and stops fetching.
- [ ] Re-pair; the watch recovers, and the server lists exactly one active watch device.

## W2 — Relaunch with pending sets (§17.2)

- [ ] Start a watch session, disable the watch's network, and log three sets.
- [ ] Force-quit the watch app and relaunch it; the three sets show as pending, in order.
- [ ] Restore the network; the sets flush in their original order with no duplicates, and the
      pending badge clears only after acknowledgement.

## W3 — Backgrounding mid-workout (§17.3)

- [ ] With the session and heart rate running, background the watch app for at least three minutes.
- [ ] Return, log a set: the rest timer, set timer and elapsed time are correct, and heart rate resumes.

## W4 — Phone plan edit while the watch is offline (§17.4)

- [ ] Offline on the watch, swap an unstarted item and change a set count on the phone.
- [ ] Reconnect: pending sets flush first, then the revision applies ("Plan updated"), never mid-set.
- [ ] Repeat against the item the watch already logged a set against: the server answers
      `plan_item_mismatch`, the set survives as off-plan with its performed exercise, and the
      telemetry keeps the original plan-item index.

## W5 — Active session, refresh and reconnect (6.6 / §13)

- [ ] Start a set, then open **Plan**: the same exercise and running set remain; Plan shows
      completed, current and upcoming rows and offers no way to select or log.
- [ ] Try to switch exercise from Plan: it is impossible; **End exercise** is still required.
- [ ] Tap **Refresh** on Set and on Session with queued work: the queue flushes before the plan
      updates; a failed flush keeps the queue, shows the error and does not apply a snapshot.
- [ ] Drop Wi-Fi, log a set, reconnect: the set flushes once and the authoritative snapshot is
      reconciled once.
- [ ] Seed a stale session (lowered threshold or seeded last activity): the advisory warning is
      visible on Set, Session and Plan and does not block logging.
- [ ] Abandon the session from the phone: the watch says **Workout abandoned elsewhere** (no raw
      status), keeps the local set count and offers **Clear record**.
- [ ] Session shows elapsed, completed/pending sets, provisional volume, sync/error state,
      **Refresh**, **Retry sync**, **Undo last set**, next exercise and **Finish**.
- [ ] Phone mirror: the form section is disabled and says ratings are recorded on the watch; a
      phone rating attempt is rejected and never enters the offline queue.

## W6 — Take-over and read-only state (§17.6)

- [ ] While the watch is mid-session, take over logging on the phone and confirm.
- [ ] The phone logs a set successfully; the watch turns read-only, refuses a set write, and no
      captured set is lost.

## W7 — HealthKit finish without duplication (§17.7)

- [ ] Finish with sRPE: the server session completes, and HealthKit holds exactly one strength
      workout with heart rate, real start/end and effort.
- [ ] Repeat, force-quitting after finish but before the save settles; relaunching still yields
      exactly one workout with the same external UUID.

## W8 — Clock skew (§17.8)

- [ ] Set the paired iPhone's clock five minutes fast (the watch follows), log and finish a session.
- [ ] The session, its sets and the telemetry timeline keep the times the sets were performed.

## W10 — Execution target (§17.10)

- [ ] A phone-targeted plan is not listed on the watch and cannot be started there.
- [ ] A watch-targeted plan shows the phone notice and no phone Start button.

## W11 — Patchy Wi-Fi (§17.11)

- [ ] Drop the network several times mid-session: each drop queues, each return partially flushes,
      and no operation is cleared before acknowledgement.
- [ ] Finish offline, reconnect after two minutes: server matches the watch — same sets, same
      timestamps, one finish, no duplicates.

## W12 — Home config refresh (§17.12)

- [ ] With no session and an empty outbox, change the home URL on the phone: the watch applies the
      new `configVersion` and keeps its token.
- [ ] With an active session or queued operations, the change is deferred and the old-URL queue
      flushes first; the watch never follows the phone's Away route.

## R — Rollback dry run (approved for the development server)

- [ ] Set `watch_enabled: false` and stop minting watch devices; confirm a new watch plan cannot be
      issued and the watch degrades cleanly, with the phone unaffected.
- [ ] Re-enable, re-pair and confirm the watch recovers; record what the watch and phone showed.

## Sign-off

| Check | Result | Notes |
|---|---|---|
| W1 credential delivery | passed 2026-11-14 (owner) | owner sign-off |
| W2 relaunch with pending sets | passed 2026-11-14 (owner) | owner sign-off |
| W3 backgrounding | passed 2026-11-14 (owner) | owner sign-off |
| W4 phone edit while offline | passed 2026-11-14 (owner) | owner sign-off |
| W5 active session/refresh/reconnect | passed 2026-11-14 (owner) | owner sign-off |
| W6 take-over and read-only | passed 2026-11-14 (owner) | owner sign-off |
| W7 HealthKit exactly once | passed 2026-11-14 (owner) | owner sign-off |
| W8 clock skew | passed 2026-11-14 (owner) | owner sign-off |
| W10 execution target | passed 2026-11-14 (owner) | owner sign-off |
| W11 patchy Wi-Fi | passed 2026-11-14 (owner) | owner sign-off |
| W12 home config refresh | passed 2026-11-14 (owner) | owner sign-off |
| R rollback dry run | follow-up | not part of the accepted run |

Owner confirmation: 2026-11-14 · Build: 8c26af0 · Device: Apple Watch Ultra 4, watchOS 27.x
Follow-up: R rollback dry run (owner-run, not a blocker).
Post-acceptance fixes: finish idempotency key (8c26af0), report decode and Today button split (9dd8329), watch rest notification (8254e4a).
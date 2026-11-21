_Part of the watch acceptance record. Index: [WATCH-ACCEPTANCE.md](../../../WATCH-ACCEPTANCE.md). Content preserved verbatim._

# Phase 6.6/6.7 watch acceptance checklist — owner-confirmed 2026-11-14

**Status: physical half run and confirmed by the owner on 2026-11-14**, build `8c26af0`, Apple Watch
Ultra 4. The run surfaced real defects that were fixed during it (the finish idempotency key, the
session-report decode, the split Today buttons); those fixes are post-acceptance commits and are listed
below the sign-off rather than reopening the phase. Automated coverage is listed in
[WATCH-6.6-PLAN.md](../../WATCH-6.6-PLAN.md) and contract §17; the simulator UI smoke
(`StrengthWatchUITests`) covers fetch → start → log → finish.

**W11** patchy Wi-Fi, **W12** home config refresh and **R** rollback dry run were confirmed in the
same run; no follow-ups remain.

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
| R rollback dry run | passed 2026-11-14 (owner) | owner sign-off |

Owner confirmation: 2026-11-14 · Build: 8c26af0 · Device: Apple Watch Ultra 4, watchOS 27.x
No follow-ups: W1–W12 and R are all confirmed.
Post-acceptance fixes: finish idempotency key (8c26af0), report decode and Today button split (9dd8329), watch rest notification (8254e4a).

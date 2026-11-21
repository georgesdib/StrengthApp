_Part of the watch acceptance record. Index: [WATCH-ACCEPTANCE.md](../../../WATCH-ACCEPTANCE.md). Content preserved verbatim._

## Execution lifecycle (6.3) — owner-run

**Status: covered by the 2026-11-14 owner sign-off** (see the checklist at the end). Requires the watch build; a simulator is not proof of liveness,
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

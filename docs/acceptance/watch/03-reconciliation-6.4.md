# Reconciliation and conflicts (6.4)

_Part of the watch acceptance record. Index: [WATCH-ACCEPTANCE.md](../../../WATCH-ACCEPTANCE.md). Content preserved verbatim._

## Reconciliation and conflicts (6.4) — owner-run

**Status: covered by the 2026-11-14 owner sign-off** (see the checklist at the end). Needs a phone and a watch, and a disposable server.

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

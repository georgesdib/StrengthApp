# Phase 6.6 — active session, refresh and mirror ownership

**Status:** implemented 2026-11-12; 283 iPhone/package tests pass and the watch target builds;
physical Ultra acceptance owner-confirmed 2026-11-14. The canonical requirements
are in the portfolio [watch contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-WATCH-CONTRACT.md)
§9, §10.3, §13 and §17; this slice plan records the client implementation and acceptance only.

## Destinations

- **Set** remains the main exercise screen.
- **Session** is a sheet from the Set or exercise-list header: elapsed time, completed/pending set
  counts, provisional tonnage, sync state and errors, Refresh, Retry sync, Undo, next exercise and
  Finish.
- **Plan** is a read-only sheet with the full sequence, completed/current/upcoming state and the
  plan-updated marker. It offers no selection or logging action and cannot bypass the
  exercise-navigation lock. Opening or closing either sheet preserves the selected exercise,
  active set and execution phase.

## Refresh, reconnect and warnings

- Refresh and reconnect flush the ordered outbox first, then fetch and apply the authoritative
  execution snapshot. A failed flush leaves the queue and snapshot untouched and exposes the retry.
- Reconciliation is single-flight; refresh/reconnect/post-set requests cannot overlap or
  double-apply.
- The server-derived idle warning is advisory and visible on Set, Session and Plan.
- A completed or abandoned server session uses explicit “completed elsewhere” / “abandoned
  elsewhere” wording; local sets remain visible and clearable.

## Ownership

- A watch-owned session is mirrored on the phone with set, form and velocity controls disabled.
- The phone rejects form (and set/finish) mutations before either the online or offline-queue
  branch; server ownership validation remains authoritative.
- Plan edits and the take-over action remain available on the phone.

## Average heart rate

Average heart rate was **removed** from the Phase 6.6 requirement set. It is not tracked,
calculated, displayed or tested, and it is not deferred future work. Live heart rate on the Set
screen remains part of Phase 6.5.

## Verification

- StrengthCore tests: plan rows are read-only and preserve active state; Plan cannot switch
  exercises; a failed flush prevents snapshot reconciliation; abandoned status maps to an explicit
  reason; stale state is exposed; next-exercise selection.
- iPhone mirror tests: form controls are hidden and a form mutation is rejected before the offline
  queue.
- The CI script builds the watch scheme and runs the iPhone and package tests (283 tests pass).
- Physical Ultra checks live in the watch acceptance checklist; simulator evidence is not proof.

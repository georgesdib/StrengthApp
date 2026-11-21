_Part of the device acceptance record. Index: [DEVICE-ACCEPTANCE.md](../../../DEVICE-ACCEPTANCE.md). Content preserved verbatim._

# Phase 4 offline acceptance checklist — complete

**Status: physically tested and owner-confirmed 2026-11-08.**

- [x] Start a workout online, then stop the server or enable airplane mode.
- [x] Add sets, record a form rating, force-quit and relaunch; the cached workout and pending
      operations are restored.
- [x] Cancel an unsent pending set and an unsent finish; the local snapshot updates.
- [x] Restart the server or disable airplane mode; foreground the app and verify FIFO replay.
- [x] Verify each queued operation reaches the server exactly once, with the original performed
      timestamps.
- [x] Queue a finish offline, reconnect and verify the session materializes with the actual finish
      time and measured duration.
- [x] Simulate an ended-elsewhere/different-active-workout case; verify no queued work is attached
      to the wrong workout and a visible conflict is shown.
- [x] Verify Retry and Discard (per operation and all capture) behave explicitly.
- [x] Verify Request workout/Start workout, plan edits, readiness and HealthKit stay unavailable or
      server-required while offline.
- [x] Confirm no background sync runs.

Owner confirmation: pass 2026-11-08 · Build: Phase 4 · Device: physical iPhone · iOS: 27.2

---

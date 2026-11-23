_Part of the device acceptance record. Index: [DEVICE-ACCEPTANCE.md](../../../DEVICE-ACCEPTANCE.md). Content preserved verbatim._

# INT-7c Shortcuts start and finish acceptance — complete (owner-confirmed 2026-11-15)

**Status 2026-11-15:** the Shortcuts app can start a workout and open the finish screen on both the
phone and the watch. Ending never finishes by itself — it opens the screen where sRPE is recorded,
matching the Action button's behaviour.

## Automated

- [x] The phone and watch schemes build; the iOS suite passes through `scripts/ci.sh`.
- [x] The phone start intent refuses to invent a plan: no issued prescription means a message, not a
      workout.

## Physical device — owner-confirmed

- [x] With no requested workout, "Start Workout" says to request one and opens the app; nothing starts.
- [x] With a requested workout, "Start Workout" starts it and lands on the active workout.
- [x] "Finish Workout" on the phone opens the running workout; sRPE is entered and Finish is pressed by
      hand.
- [x] "Finish Workout" on the watch opens the finish screen; the same applies after the Action button's
      second press.
- [x] Both intents work from the Shortcuts app and from Siri's intents list.

Owner confirmation: pass 2026-11-15 · Build: INT-7c · Device: iPhone + Watch · iOS 27.2 / watchOS 27.2

---

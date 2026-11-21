_Part of the device acceptance record. Index: [DEVICE-ACCEPTANCE.md](../../../DEVICE-ACCEPTANCE.md). Content preserved verbatim._

# INT-7b-1 workout automation acceptance — complete (owner-confirmed 2026-11-15)

**Status 2026-11-15:** `WorkoutAutomation` is wired into the session transitions and its unit tests pass
on the iPhone 17 simulator. The owner confirmed every physical-device check below.

## Automated

- [x] A configured shortcut fires once per session and event, and a second identical transition is a
      no-op.
- [x] Start and end are separate channels and both fire.
- [x] An empty or whitespace-only field is off.
- [x] Different sessions each fire.
- [x] A refused URL is forgotten so a later transition can retry, and the workout is untouched.
- [x] The URL is `shortcuts://run-shortcut?name=<percent-encoded>` with no input.

## Physical device — owner-confirmed

- [x] Settings shows "Workout automation" with a shortcut name per event and two test buttons.
- [x] With both fields filled, starting a workout runs the start shortcut (Shortcuts comes to the
      foreground briefly and the app returns).
- [x] Finishing or abandoning the workout runs the end shortcut.
- [x] With both fields empty, nothing runs.
- [x] A shortcut name that no longer exists does not block or delay the workout and does not crash.
- [x] The shortcut receives no input: a shortcut whose first action reads "Shortcut Input" still runs.

Owner confirmation: pass 2026-11-15 · Build: INT-7b-1 · Device: physical iPhone · iOS: 27.2

---

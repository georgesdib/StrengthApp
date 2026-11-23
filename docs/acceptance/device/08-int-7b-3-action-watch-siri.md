_Part of the device acceptance record. Index: [DEVICE-ACCEPTANCE.md](../../../DEVICE-ACCEPTANCE.md). Content preserved verbatim._

# INT-7b-3 Action button and watch Siri acceptance — complete (owner-confirmed 2026-11-15)

**Status 2026-11-15:** the watch target links `StrengthIntents`, declares its own read-only intents and
App Shortcuts, registers a watch-side data provider, and implements `StartWorkoutIntent` plus the
donated finish intent. The owner confirmed every physical check below.

## Automated

- [x] The watch scheme builds with the intents package linked.
- [x] The phone scheme still builds and the iOS suite passes (run through `scripts/ci.sh`).
- [x] `StrengthWorkoutStyle` is a single `Strength` case; the issued plan decides the session content.

## Physical device — owner-confirmed

- [x] Settings > Action button > Workout lists Strength; choosing it and pressing the button starts the
      plan the iPhone already requested for the watch.
- [x] With no watch-targeted plan, the button answers "Request a workout on your iPhone first" and opens
      the app instead of starting anything.
- [x] While a session is running, the second press brings the session forward and does **not** finish it
      (owner chose "open the finish screen", 2026-11-15); sRPE is entered and Finish is tapped by hand.
- [x] Watch Siri answers the four read-only questions (last workout, overview, weekly review, exercise
      progression) after the watch app has been opened once.
- [x] With the watch unpaired, those phrases answer with the pairing message instead of hanging.

Owner confirmation: pass 2026-11-15 · Build: INT-7b-3 · Device: Apple Watch · watchOS 27.2

---

_Part of the device acceptance record. Index: [DEVICE-ACCEPTANCE.md](../../../DEVICE-ACCEPTANCE.md). Content preserved verbatim._

# INT-10 Daily reminder acceptance — outstanding

**Status 2026-11-16:** implemented on the iOS client; automated tests pass. The physical-device checks
are **not run yet** — simulator success is not proof of notification delivery.

## Automated

- [x] `xcodebuild test -only-testing:StrengthAppTests/NudgeSchedulerTests` — 18 tests, 0 failures.
- [x] `NudgeSchedulerTests`, `AppModelTests` and `RestTimerTests` pass together (29 tests).
- [x] The iOS scheme builds for the iPhone 18 Pro simulator (iOS 27.2).
- [x] The full `scripts/ci.sh` gate: both schemes build and 425 tests pass (1 skipped).

## Physical device — outstanding

- [ ] Enable the reminder, set it two minutes ahead, background the app and receive it on time.
- [ ] The message names only facts the app already shows; with Apple Intelligence off it uses the
      built-in wording rather than failing.
- [ ] Tapping the notification opens Today; with readiness missing it presents the readiness form.
- [ ] With only part of the core readiness answered, the reminder asks you to finish it rather than
      saying it is logged, and tapping it opens the readiness form.
- [ ] The **Log readiness** action opens the readiness form directly.
- [ ] Complete a session before the reminder time and confirm no reminder fires that day.
- [ ] Change the time, foreground the app, and confirm one pending reminder on each of the next seven
      days and no duplicates.
- [ ] With a Focus mode on, confirm the reminder's behaviour (this build adds no time-sensitive
      entitlement, so Focus may hold it).

## First device run — 2026-11-16 (two defects found)

- **Wrong readiness state.** The reminder said readiness had not been logged after it had been. Cause:
  the server omits `known` when a day has a usable merged row and sends `known: false` only when it
  has none, and the client tested for `known == true`. Fixed with `ReadinessPayload.isLogged`
  (`known ?? true`) and a decoding test that pins both shapes.
- **No model prose.** The readiness facts contain no numbers, so any numeral the model wrote failed
  the grounding check and the template always shipped. The owner then asked for numbers to be allowed
  in a reminder: the nudge now enforces only length, while the narrative surfaces keep the strict
  number-grounding check. Settings reports the last composition's origin and reason.
- **Not mirrored to the watch.** Expected behaviour, not a defect: iOS mirrors an iPhone notification
  only while the iPhone is locked or asleep.

Both fixes are covered by `NudgeSchedulerTests` (20 tests). The physical-device list above still
needs a re-run against the fixed build.

Owner confirmation: pending.

---

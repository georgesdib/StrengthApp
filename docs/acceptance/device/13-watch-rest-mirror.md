_Part of the device acceptance record. Index: [DEVICE-ACCEPTANCE.md](../../../DEVICE-ACCEPTANCE.md). Content preserved verbatim._

# Watch rest mirror and Home scene diagnostics — implemented, device run pending (2026-11-21)

**Status 2026-11-21:** the phone now mirrors a rest that starts on the Apple Watch as its Live
Activity, and the watch reports what it knows about the phone's Home scenes so a scene that does not
run is no longer silent. The watch scene path is **owner-confirmed on hardware** for the mapping and
for **Test start scene**; the rest mirror and the workout start/end transitions are still unverified.

The scene failure reported on 2026-11-21 was a HomeKit identifier mismatch: the watch saw the home
and the scene under different identifiers than the phone had stored, so resolution by identifier
found nothing and the run was refused without a reason. Building 07c2725 resolves identifiers first
and then by the owner's own home and scene names, and shows the reason when both fail. With that
build installed, Test start scene ran the scene from the watch alone.

## Automated

- [x] `WatchRestSnapshot` survives the user-info round trip, including a rest with no end date.
- [x] A foreign or malformed message is ignored, never decoded into a rest.
- [x] A rest shows when the phone is idle, defaults its label to **Rest**, and carries the watch's end date.
- [x] A phone-started rest wins: a watch rest never replaces it.
- [x] A duplicate or reordered delivery is ignored; a relaunched watch is never treated as stale.
- [x] A rest with no end date dismisses only a mirrored activity, and a rest that ended before the
      delivery arrives never appears.
- [x] `WatchSceneMapping` round-trips and treats an empty field as "no scene".
- [x] The focused suites (`WatchRestMirrorTests`, `WorkoutAutomationTests`, `WatchPairingTests`,
      `WatchMirrorTests`) pass on the iPhone 18 Pro simulator: 55 tests, 0 failures.
- [x] A scene resolves by identifier first and by home/scene name second, and reports
      `ran` / `homeMissing` / `sceneMissing` / `failed` with a line the watch can show.
- [x] `scripts/ci.sh` (watch build, phone build, embedded watch): 529 tests, 1 skipped, 0 failures.

## Physical device — not run

- [ ] Start a set on the Apple Watch; within a few seconds the phone's Lock Screen shows the rest
      countdown with **Rest on Apple Watch** and no **+15 s** / **Skip**.
- [ ] With the phone locked and the app backgrounded, the mirror still appears and counts down
      correctly.
- [ ] Extending or skipping the rest on the watch updates or dismisses the phone's activity.
- [ ] A rest started on the phone is not replaced by a watch rest, and vice versa.
- [x] The watch shows the Home scene mapping the phone chose (now under watch **Settings**, after
      the Today screen was returned to training).
- [ ] Changing the scene on the phone reaches the watch within a few seconds without re-pairing.
- [x] **Test start scene** runs the scene from the watch alone (watch **Settings** → Test start scene).
- [ ] Starting a workout on the watch runs the start scene; finishing or discarding runs the end scene.
- [x] If a scene does not run, the watch names the case instead of failing silently.

Owner confirmation: partial, 2026-11-21 · Build 07c2725 (phone and watch) · iPhone 16 Pro Max +
Apple Watch · mapping and Test start scene pass; rest mirror and workout transitions still pending.

_Part of the device acceptance record. Index: [DEVICE-ACCEPTANCE.md](../../../DEVICE-ACCEPTANCE.md). Content preserved verbatim._

# INT-7b-2 HomeKit scenes acceptance — complete (owner-confirmed 2026-11-15)

**Status 2026-11-15:** the phone chooses and executes scenes on start and end; the mapping travels to
the watch in the credential context, and the watch executes the same scenes when it owns the session.
The owner confirmed every phone and watch check below.

## Automated

- [x] The scene runs before the Shortcut, once per session and event.
- [x] A refused scene is forgotten so a later transition can retry, and the workout is untouched.
- [x] `SceneSelection` survives a JSON round-trip and tolerates corrupt storage.
- [x] Ten automation tests pass on the iPhone 17 simulator.

## Physical device — owner-confirmed

- [x] Settings shows "Home scenes" with a start and end picker, populated from the homes the app can
      see; the first open asks for Home access.
- [x] Choosing a scene and starting a workout runs it; finishing or abandoning runs the end scene.
- [x] With both pickers on "None", no scene runs.
- [x] A scene deleted after selection is skipped; the workout still starts and finishes.
- [x] Denying Home access leaves both pickers empty and never blocks a workout.

## Watch — owner-confirmed

- [x] After choosing scenes on the phone, the watch receives the mapping with its next credential
      context (pairing, config refresh, or a scene change).
- [x] Starting a workout on the watch runs the start scene; finishing or discarding runs the end scene.
- [x] The same session never runs a scene twice, and a missing home or scene is skipped silently.

Owner confirmation: pass 2026-11-15 · Build: INT-7b-2 (phone and watch) · Device: iPhone 16 Pro Max + Apple Watch · iOS 27.2 / watchOS 27.2

---

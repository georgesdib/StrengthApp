# Readiness registry — device acceptance

**Status:** **outstanding — the physical-device run was not performed.** The owner declined the
installation of this build on 2026-11-25 when asked. Simulator live acceptance passed on the same
build against a disposable seeded-registry server; that is not physical-device proof.

- **Client branch:** `readiness-registry`
- **Client code under test:** `295b416`
- **Backend:** `strength-training-app` branch `readiness-registry` at `1084da0`
- **Server data:** disposable database at `/tmp/strengthapp-readiness-registry-acceptance/coach.db`,
  seeded registry v1 (`registry_id=1`, effective 1970-01-01, seven enabled metrics)
- **Simulator:** iPhone 18 Pro (iPhone19,2), iOS 27.2
- **Build:** Debug, Xcode 27.2
- **Physical device (not installed):** iPhone 16 Pro Max (iPhone17,2), iOS 27.2.1

## Simulator live acceptance (passed)

Command: `StrengthAppUITests/testPhase2ReadinessPrescriptionWorkoutAndProgressAgainstTheLiveServer`
against the disposable server; 183.9 s, 0 failures.

Verified end to end:

1. Pairing and `GET /api/ios/v1/readiness/schema` returned registry v1 (seven metrics).
2. **Today → Log readiness** rendered the enabled metrics in registry order: Sleep, Energy, Mood,
   Stress, Soreness, then the device inputs. Sleep and Energy carried the red required-one-of mark;
   the footer said "Required: at least one of Sleep or Energy. Enter at least 3 core fields for a
   score."
3. The form's per-metric hints came from the schema: 1–5 for core metrics, `ms`/higher-is-better
   for HRV, `bpm`/lower-is-better for resting heart rate. Bodyweight and the wearable score were
   in a separate **Other inputs** section.
4. Five core values were entered (all 4) and saved. The server log recorded
   `POST /api/ios/v1/readiness 200`; Today refreshed and the test continued through prescription,
   workout, report and Progress.
5. Screenshots used in the user guide: [schema form](../../images/readiness-registry-form.png) and
   [filled form](../../images/readiness-registry-filled.png).

## Physical checklist (still required)

Run this against the same disposable server, with the phone on the same trusted LAN and the server
bound to the Mac's LAN address (never the real database):

1. Pair the iPhone and open **Today → Log readiness**.
2. Confirm the seven seeded metrics appear in registry order, the Sleep/Energy required marks, the
   1–5 scales, the `ms`/`bpm` units and the higher/lower direction.
3. Try to save with only Mood and Stress (no Sleep/Energy, fewer than three core fields): the form
   must block locally and name the missing rule.
4. Save three or more core values including Sleep or Energy: the server must accept the write and
   the Today readiness status/score must refresh from the server.
5. Stop the server and reopen the form: the cached schema (or the fixed fallback) must still render
   and the form must say that server-added metrics are unavailable offline. Confirm no invented
   values.
6. Restart the server and confirm a queued offline readiness write syncs and the authoritative
   score refresh follows.

## Physical acceptance record

| Field | Value |
|---|---|
| Date | — (not run) |
| Device / OS | iPhone 16 Pro Max / iOS 27.2.1 |
| Build | — |
| Result | Outstanding — owner declined installation 2026-11-25 |
| Screenshots | — |

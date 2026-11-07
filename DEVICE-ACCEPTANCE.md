# Phase 1 device acceptance checklist — completed 2026-11-07

**Result: complete.** The owner confirmed the Phase 1 pass on their physical iPhone (iOS 27.2;
the connected device reports iPhone 16 Pro Max, iPhone17,2) against the local server on the home
LAN. The simulator pass used the iPhone 18 Pro. The checklist below is retained as the record of
what was exercised.

Phase 1 is read-only: if a check would require writing a readiness day, starting a workout or
requesting a prescription, it is out of scope.

## Before you start

- [ ] Xcode 27.2 is selected (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
- [ ] The server is running on the home LAN over plain HTTP and is **not** reachable from the
      Internet. No port-forwarding, VPN, TLS proxy or certificate is required.
- [ ] The server database is the intended one. For a rehearsal, use a temporary database
      (`strength-coach --db /tmp/rehearsal.db web --host 0.0.0.0 --port 8000`); never point a
      rehearsal at the live `data/coach.db`.
- [ ] The iPhone and the server are on the same trusted network.
- [ ] `StrengthApp` is selected, the personal team is set, and the build targets the owner's iPhone.
- [ ] The app's local-network permission is allowed in iPhone Settings if it was previously denied.

## Pairing

- [ ] `strength-coach --db <db> ios pair` prints one grouped 8-digit code and an expiry.
- [ ] The app's Pairing screen shows the server address, a code field, the optional label and a
      Pair button. Release starts with an empty address; Debug prefills `http://127.0.0.1:8000`.
- [ ] A malformed code shows an inline error and creates no device.
- [ ] A wrong code shows the server's 401 message and creates no device.
- [ ] An expired or already-used code shows the 410 message and creates no device.
- [ ] Five failed attempts exhaust the code (429); mint a new code to continue.
- [ ] A valid code pairs once, creates exactly one device, and returns to Today.
- [ ] Pairing the same code a second time is rejected (410).

## Today and History

- [ ] Today shows the **server-local** date, not a UTC slice.
- [ ] Today shows the readiness status, score, basis, overrides and context flags returned by the
      server; an unknown/insufficient day is not shown as a zero score.
- [ ] Today shows "No active workout" when none is open; if one is open, its summary is shown.
- [ ] Pull to refresh updates the screen; a server stop shows a clear error, not fabricated data.
- [ ] History loads the default page, shows date/session type/sets/tonnage/lifts, and "Load more"
      appends older sessions without duplicates.
- [ ] Empty history shows the empty state; a server error shows the retry state.

## Persistence and local forget

- [ ] Force-quit and relaunch the app; it opens Today without asking for the code again.
- [ ] Settings shows the server URL, device label/id and app version.
- [ ] "Forget this device" asks for confirmation, deletes the local token, and returns to Pairing.
- [ ] After Forget, the server still lists the device (`strength-coach ios devices`) until it is
      revoked or re-paired.
- [ ] Pairing again with a new code works and replaces the Keychain item.

## Server-side revocation

- [ ] `strength-coach ios devices` lists the device id, label, created, last seen and revoked.
- [ ] `strength-coach ios revoke <device_id>` sets the timestamp; a second revoke is a no-op.
- [ ] On the phone, a read after revocation returns to Pairing with the device-revoked message.
- [ ] A revoked device cannot read Today or History, even with the old token.
- [ ] Re-pairing after revocation creates a new device row and works.

## Secrets and logs

- [ ] The pairing code is printed only by the CLI; neither the code nor the token appears in the
      server application log or the web Logs page.
- [ ] Error bodies never contain the code or token.
- [ ] The token is not in UserDefaults, a file, a crash report or an analytics payload.
- [ ] The token is in the iPhone Keychain only, and `Forget` deletes it.
- [ ] The app talks only to the entered server address; there is no public/cloud fallback.

## Existing server behaviour

- [ ] The existing web UI still loads and works without an iOS token.
- [ ] Existing `/api/*` routes behave as before; only `/api/ios/v1/*` requires a bearer token.
- [ ] No prescription, workout, readiness or review behaviour changed.

## Rollback

- [ ] Forget the device on the phone.
- [ ] Revoke the device on the server.
- [ ] If the whole phase is being withdrawn: drop `ios_device` and `ios_pairing_code`, remove the
      `/api/ios/v1/` routes and the `ios` CLI group. No training, readiness, prescription or
      workout row is touched.

## Sign-off

| Check | Result | Notes |
|---|---|---|
| Pairing and rejection paths | pass | owner-confirmed 2026-11-07 |
| Today readiness/date | pass | owner-confirmed 2026-11-07 |
| History paging | pass | owner-confirmed 2026-11-07 |
| Relaunch persistence | pass | owner-confirmed 2026-11-07 |
| Forget and re-pair | pass | owner-confirmed 2026-11-07 |
| Server revocation | pass | owner-confirmed 2026-11-07 |
| No secrets in logs | pass | owner-confirmed 2026-11-07 |
| Existing web/API unchanged | pass | owner-confirmed 2026-11-07 |
| Device/build/signing | pass | owner-confirmed 2026-11-07 |

Owner confirmation: 2026-11-07  ·  Build: Phase 1  ·  Device: iPhone 16 Pro Max (iPhone17,2),
iOS 27.2  ·  Simulator: iPhone 18 Pro, iOS 27.2

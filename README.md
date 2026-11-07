# StrengthApp — iOS client

**Status: Phase 1 complete 2026-11-07; Phase 2 complete and accepted 2026-11-07** — both
simulator-verified and owner-confirmed on the physical iPhone. Phase 3 is not started.

A small native SwiftUI client for the owner's local `strength-coach` server. Phase 2 adds the
online strength workflow: manual readiness, a server-issued prescription, start-by-id, active
workout set logging (including optional manual mean velocity), form ratings, completion/abandon
and the Progress screen. Python remains the sole authority for readiness scores, prescriptions,
loads, sets and training decisions; the phone never supplies plan content.

The server contracts are `docs/design/IOS-PHASE-1-CONTRACT.md` and
`docs/design/IOS-PHASE-2-CONTRACT.md` in the `strength-training-app` repository. The client is
this separate repository.

## Requirements

- Xcode 27.2 and an iOS 27.2 simulator or device.
- The server repository running `strength-coach web` on the same trusted home network.
- For a device build: the owner's personal team (7-day signing) and the owner's iPhone.

## Run against the local server

1. Start the server on the machine the phone can reach:

   ```bash
   strength-coach --db /path/to/coach.db web --host 0.0.0.0 --port 8000
   ```

2. Mint a one-use code:

   ```bash
   strength-coach --db /path/to/coach.db ios pair --label "iPhone"
   ```

3. Build and run `StrengthApp` in Xcode on the iPhone 18 Pro simulator (Debug prefills
   `http://127.0.0.1:8000`) or on the owner's iPhone (enter the server's LAN address, for example
   `http://192.168.1.10:8000`).

4. Enter the 8-digit code and pair. The app stores only the token in the Keychain; the server
   stores only its SHA-256 digest.

## Screens

- **Pairing** — server URL, one-use code, optional device label, inline error, progress.
- **Today** — server date/time/time zone, readiness status/score/basis/overrides/context, active
  workout or "no active workout"; Log readiness, Start workout and Resume workout; pull to refresh.
- **Readiness** — manual sleep/energy/mood/soreness/stress (1–5), optional HRV/RHR/bodyweight/
  wearable and legacy labels, optional note; missing fields stay missing; errors stay visible.
- **Prescription preview** — server-issued plan, readiness summary, warnings and expiry; Start
  workout starts by issued-plan id only and transitions directly into the active workout.
- **Workout** — plan and logged sets, add set with load/reps/RIR and optional mean velocity,
  optional 1–5 form rating, finish with session RPE or explicit not-recorded, abandon with
  confirmation.
- **History** — paginated sessions with sets, tonnage, main lifts and review state; load more,
  empty and error states.
- **Progress** — the server dashboard: sRPE coverage, performance points, weekly volume, attendance
  and back-symptom summary over a 4/8/12/26/52-week window.
- **Settings** — server URL, device id/label, app version, Forget this device (local token only),
  re-pair instructions.

There is no HealthKit, offline queue, plan editing, per-rep VBT, review/rubric or Apple
Intelligence/PCC UI in Phase 2.

## Storage and networking

- Token: `kSecClassGenericPassword`, service `com.georgesdibpersonalteam.StrengthApp`, account
  `api-token`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Deleted by Forget.
- Server URL and device id/label: UserDefaults (not secret). The token never goes to
  UserDefaults, a file, a log or a crash report.
- One `IOSAPIClient`: http/https base URL validation, `Authorization: Bearer`, JSON on POST,
  10-second timeout, strict decoding, bounded GET retries only, no automatic POST retries, no
  cookies, no redirects outside the paired origin (scheme, host and effective port), no background
  transfers.
- Every Phase 2 mutation sends a UUID `Idempotency-Key`; a retry reuses the key. The client keeps
  the key for a failed retry and does not claim a save it did not receive.
- 401/403 clears the local pairing and returns to the pairing screen. Other 4xx show the server
  message/code; 5xx shows a generic failure.
- Plain HTTP on the trusted home LAN. No TLS, proxy, CA or remote access. No analytics, telemetry,
  advertising, cloud database or Internet fallback.

## Tests

The unit-test target (`StrengthAppTests`, 43 tests) covers Keychain save/load/delete/replace, API
client decoding from fixtures, 401/403 mapping, bounded GET retries, no POST retry, base-URL/code/
label validation, the AppModel pairing/forget/auth-failure flows, the same-origin redirect policy
(cross-port, scheme-changing, host, userinfo and delegate rejection), Phase 2 request bodies and
idempotency headers, server conflict code/details decoding, progress decoding, the
issue/start/add-set/complete model flow, body-aware retry keys, unique-only plan-item attribution,
duplicate-tap guarding and ambiguous-failure classification.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project StrengthApp.xcodeproj -scheme StrengthApp \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

The optional UI smoke tests (`StrengthAppUITests`) verify pairing, Today, History, Settings,
relaunch persistence and Forget, plus the Phase 2 flow (readiness → prescription → start → add a
manual-VBT set → force-quit/relaunch recovery → finish → Progress) against a real local server. They are skipped unless
`StrengthAppUITests/LiveConfig.swift` is generated with `enabled = true` and a fresh pairing code;
the committed copy is disabled so the normal gate does not need a server. The shared scheme
includes both test targets. The simulator test run needs normal (ad-hoc) simulator signing so the
Keychain is available; a plain app build may pass `CODE_SIGNING_ALLOWED=NO`.

### Headless/agent build note

In a sandboxed agent shell the Swift compiler's nested plugin sandbox and `$TMPDIR` Clang module
cache may be denied. Add these command-line overrides for that environment only (they are not in
the project file, so normal Xcode builds are unchanged):

```bash
OTHER_SWIFT_FLAGS='-disable-sandbox -Xcc -fmodules-cache-path=$PWD/clang-module-cache'
```

Simulator `xcodebuild test` also needs a pseudo-terminal and simulator services, which a
workspace-only sandbox may deny.

## Real-device acceptance

Phase 1 and Phase 2 completed 2026-11-07; the records are in
[DEVICE-ACCEPTANCE.md](DEVICE-ACCEPTANCE.md). Phase 3 needs its own approved contract and has not
started.

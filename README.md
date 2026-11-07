# StrengthApp — iOS Phase 1

**Status: Phase 1 complete 2026-11-07** — simulator-verified and owner-confirmed on the physical
iPhone. Phase 2 is not started.

A small native SwiftUI client for the owner's local `strength-coach` server. Phase 1 is
**read-only**: pairing, today's readiness/status, recent history and settings/forget. Python remains
the sole authority for readiness scores, prescriptions and training decisions.

The server contract is `docs/design/IOS-PHASE-1-CONTRACT.md` in the
`strength-training-app` repository. The client is this separate repository.

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
  workout summary or "no active workout"; pull to refresh.
- **History** — paginated sessions with sets, tonnage, main lifts and review state; load more,
  empty and error states.
- **Settings** — server URL, device id/label, app version, Forget this device (local token only),
  re-pair instructions.

There is no **Progress** screen in Phase 1. The server exposes `GET /api/ios/v1/progress` and
covers it with server tests, but the client screens are Pairing, Today, History and Settings only.
A Progress screen is deferred to Phase 2 and was not added under the Phase 1 contract.

There is no prescription, workout write, readiness entry, HealthKit, review or offline UI in
Phase 1.

## Storage and networking

- Token: `kSecClassGenericPassword`, service `com.georgesdibpersonalteam.StrengthApp`, account
  `api-token`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Deleted by Forget.
- Server URL and device id/label: UserDefaults (not secret). The token never goes to
  UserDefaults, a file, a log or a crash report.
- One `IOSAPIClient`: http/https base URL validation, `Authorization: Bearer`, JSON on POST,
  10-second timeout, strict decoding, bounded GET retries only, no cookies, no redirects outside
  the paired origin (scheme, host and effective port), no background transfers.
- 401/403 clears the local pairing and returns to the pairing screen. Other 4xx show the server
  message; 5xx shows a generic failure.
- Plain HTTP on the trusted home LAN. No TLS, proxy, CA or remote access. No analytics, telemetry,
  advertising, cloud database or Internet fallback.

## Tests

The unit-test target (`StrengthAppTests`, 29 tests) covers Keychain save/load/delete/replace, API
client decoding from fixtures, 401/403 mapping, bounded GET retries, no POST retry, base-URL/code/
label validation, the AppModel pairing/forget/auth-failure flows, and the same-origin redirect
policy (cross-port, scheme-changing, host, userinfo and delegate rejection).

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project StrengthApp.xcodeproj -scheme StrengthApp \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

The optional UI smoke test (`StrengthAppUITests`) verifies pairing, Today, History, Settings,
relaunch persistence and Forget against a real local server. It is skipped unless
`StrengthAppUITests/LiveConfig.swift` is generated with `enabled = true` and a fresh pairing code;
the committed copy is disabled so the normal gate does not need a server. The simulator test run
needs normal (ad-hoc) simulator signing so the Keychain is available; a plain app build may pass
`CODE_SIGNING_ALLOWED=NO`.

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

Completed 2026-11-07; the record is in [DEVICE-ACCEPTANCE.md](DEVICE-ACCEPTANCE.md). Phase 2 is
not started and needs its own approved contract.

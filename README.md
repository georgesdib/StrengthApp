# StrengthApp — iOS client

[![iOS CI](https://github.com/georgesdib/StrengthApp/actions/workflows/ios-ci.yml/badge.svg)](https://github.com/georgesdib/StrengthApp/actions/workflows/ios-ci.yml)

**Status: Phase 1 complete 2026-11-07; Phase 2 complete and accepted 2026-11-07; Phase 3A
closed 2026-11-08** — Phase 3A is unit/simulator/live-server and physical-iPhone verified. Phase 4
offline capture and replay are closed 2026-11-08 (snapshot/outbox, add set/form/finish, ordered
sync, conflict handling and cancellation); physical offline acceptance was owner-confirmed. R1 durable pending-mutation journal, R3 explicit plan-item selection,
R4 form-rating correction UX, R5 recovery/reconciliation and R8 active-workout plan editing are
closed. Phase 6.0 (the shared watch core) and 6.1 (the server watch contract) are complete. Phase
6.2 is complete and closed 2026-11-10: 6.2a embedded watch target and CI, 6.2b credential/config
handoff and phone-side Pair/Status/Revoke, and 6.2c read-only Today from the Home server. Phases
6.3–6.5 add the watch execution lifecycle, offline conflicts and heart rate with one HealthKit
workout. 6.6 adds the phone mirror with plan-revision pushes and take-over, the active Set,
Session and Plan destinations, refresh/reconnect reconciliation, idle and ended-elsewhere
messaging, and the mirror form controls. Physical Apple Watch acceptance was owner-confirmed 2026-11-14.

A small native SwiftUI client for the owner's local `strength-coach` server. Phase 2 adds the
online strength workflow: manual readiness, a server-issued prescription, start-by-id, active
workout set logging (including optional manual mean velocity), form ratings, completion/abandon
and the Progress screen. Phase 3A adds opt-in, read-only HealthKit HRV, resting heart rate and
bodyweight;
manual readiness wins, Python remains the sole authority for readiness scores, prescriptions,
loads, sets and training decisions, and the phone never supplies plan content.

The shared iOS phase contracts and client plan are canonical in the portfolio repository; the
[client docs index](docs/README.md) lists the client-specific documentation. The Phase 6 watchOS
companion contract is
[`IOS-WATCH-CONTRACT.md`](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-WATCH-CONTRACT.md);
Phase 6.0–6.7 are complete: 6.2 closed 2026-11-10 (shared core, server contract, watch target,
credential handoff and read-only Today), 6.3–6.6 followed, and 6.7 physical acceptance was
owner-confirmed 2026-11-14 (W1–W12 and R). The client plan is
[the canonical iOS client phase plan](https://github.com/georgesdib/strength-app/blob/main/docs/plans/IOS-CLIENT-PLAN.md);
start with [`docs/README.md`](docs/README.md) for the client documentation map.

## Agent documentation

- [docs/README.md](docs/README.md) — client documentation index and repository ownership.
- [docs/AGENT-WORKFLOWS.md](docs/AGENT-WORKFLOWS.md) — build, test, CI and completion procedures.
- [docs/AGENT-LIVE-TESTS.md](docs/AGENT-LIVE-TESTS.md) — disposable live-server UI acceptance.
- [docs/AGENT-CONTRACTS.md](docs/AGENT-CONTRACTS.md) — server authority and API contract rules.
- [Canonical iOS client phase plan](https://github.com/georgesdib/strength-app/blob/main/docs/plans/IOS-CLIENT-PLAN.md) — phased plan, architecture invariants and rollback gates.

## User guide

See [USER-GUIDE.md](USER-GUIDE.md) for pairing, Home/Away routing, workout controls, rest
notifications, offline behaviour, History execution timeline, HealthKit and troubleshooting.

## Requirements

- Xcode 27.2 and an iOS 27.0 or newer simulator or device.
- The server repository running `strength-coach web` on the same trusted home network.
- For a device build: the owner's personal team (7-day signing) and the owner's iPhone.
- No Wi-Fi/location permission is required. Home/Away routing uses a short reachability probe
  of Home Server, with Prefer Home Server as the manual override; both addresses should reach
  the same paired server.

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
  workout or "no active workout"; Log readiness, Request workout and Resume workout; a Recovery
  section when the server has a workout not represented locally, a local workout ended elsewhere,
  or a prescription is no longer usable; an opt-in HealthKit section showing HRV/RHR/bodyweight
  effective values, source, sample age and Import from HealthKit; pull to refresh.
- **Readiness** — manual sleep/energy/mood/soreness/stress (1–5), optional HRV/RHR/bodyweight/
  wearable and legacy labels, optional note; HealthKit HRV/RHR/bodyweight values/source/age are
  shown on the same form with manual override; missing fields stay missing; errors stay visible.
- **Workout ready** — once the server finishes building, Today shows a ready card with the
  session type, date, exercise count and warnings. **Review workout** opens the full plan, and
  **Start workout** on that screen starts by issued-plan id and opens the active workout directly;
  start is never offered before the exercises are visible. Request workout
  can ask for server-decided, top-set/back-off or straight-set main-lift structure and chooses
  **iPhone** or **Apple Watch** as the execution target. A watch-targeted plan shows a notice on
  the phone and is started on the watch; it never exposes the phone Start button.
- **Workout** — exercise-first list with an exercise detail screen, prepopulated planned sets,
  performed-set logging with load/reps/RIR, optional mean velocity when the plan supplies a
  velocity target, optional per-rep velocity with
  comma/space-separated input, explicit Start set and set-completion timestamps, performed-set
  add/remove, outside-plan exercise logging through the authenticated catalogue, a working-set
  rest timer using the plan’s `rest_s` with prescribed/actual comparison, observable skip and
  extension, one app-level timer that stays visible above the tab bar on Today and every tab, a
  local notification at rest end with a **Done** action (and an in-app haptic/sound while active),
  warm-up rows including an empty-bar first set, an explicit prescription-item picker when the
  exercise appears more than once, and form ratings on the exercise screen that show the current
  value and label a later save as a correction, additive plan
  editing (add/swap/remove and set count), finish with one sRPE picker (Not recorded or 1–10),
  optional productivity (Not recorded or 1–5), abandon with confirmation.
- **Session report** — after an acknowledged completion, the iPhone shows the AFC-2 completed-workout
  report: prescription adherence, VBT/velocity, session feedback, quality flags and evidence.
  History detail can reopen the same report for an app-tracked session; imported sessions without a
  workout record say so. The report is read-only and performs no client-side calculation.
- **History** — paginated sessions with sets, tonnage, duration, main lifts and review state;
  tap a session for a read-only outline, duration and set summary plus a recorded execution
  timeline, set/rest durations, prescribed-versus-actual rest and missing-data indicators; load
  more, empty and error states.
- **Progress** — the server dashboard: sRPE coverage, performance points, weekly volume, attendance
  and back-symptom summary over a 4/8/12/26/52-week window.
- **Settings** — Home Server, Away Server, Prefer Home Server, active route, Exercise Library,
  Apple Watch Pair/Status/Revoke, device id/label, app version, opt-in HealthKit readiness, Forget
  this device (local token only), re-pair instructions.
- **Apple Watch** — credential status plus the Home server's watch-targeted work. A watch-targeted
  plan is started, logged and finished on the watch (sets, form rating, mean velocity only when
  the plan supplies a velocity target, rest with +15s/−15s and a local end-of-rest notification,
  heart rate, one HealthKit workout, sRPE and optional productivity at finish, local-first
  outbox); phone-targeted plans are hidden. While
  the watch owns the session the phone shows a **Logged on Apple Watch** banner, keeps set logging
  and form ratings disabled, and remains read-only for capture; plan edits still work and are
  pushed to the watch at its next idle point, never mid-set. **Take over logging** asks for
  confirmation, moves ownership to the phone and leaves the watch read-only.
- **Exercise Library** — searchable catalogue, read-only configuration, server-computed e1RM and
  paginated working-set history; the catalogue is cached on disk so browsing and exercise choice
  work offline, configuration is cached for the app session, e1RM/history are fetched on entry,
  with explicit refresh.

HealthKit is read-only, off by default and limited to HRV, resting heart rate and bodyweight. There is no
workout-HR import, review/rubric or Apple Intelligence/PCC UI. Execution telemetry is queued through
the Phase 4 offline capture path; plan edits remain online-only.

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
- R1 durable journal: attempted mutations are written to Application Support before sending,
  with the UUID, device/server, kind, target, route and exact encoded body. The file uses iOS
  data protection and is excluded from backup. It is capped at 16 entries, retained 30 days and
  replayed automatically for 28 days; conflicting or stale entries stop and require review/discard.
  It is not an offline queue: only attempted mutations are recorded, and new mutations are blocked
  while an unresolved one exists. R1 is closed 2026-11-07; verification is unit/simulator based
  and a separate physical R1 pass was not performed.
- 401/403 clears the local pairing and returns to the pairing screen. Other 4xx show the server
  message/code; 5xx shows a generic failure.
- The watch has its own server device/token. The phone holds that token in memory only until the
  watch acknowledges it; the watch stores it in its own Keychain. Non-secret watch metadata
  (device id, epoch, configVersion, Home URL) is separate from the token. The watch never follows
  the phone's Away route.
- Plain HTTP on the trusted home LAN. No TLS, proxy, CA or remote access. No analytics, telemetry,
  advertising, cloud database or Internet fallback.

## Tests

The unit-test target (`StrengthAppTests`, 184 tests) covers Keychain save/load/delete/replace, API
client decoding from fixtures, 401/403 mapping, bounded GET retries, no POST retry, base-URL/code/
label validation, the AppModel pairing/forget/auth-failure flows, the same-origin redirect policy
(cross-port, scheme-changing, host, userinfo and delegate rejection), Phase 2 request bodies and
idempotency headers, server conflict code/details decoding, progress decoding, the
issue/start/add-set/complete model flow, body-aware retry keys, unique-only plan-item attribution,
duplicate-tap guarding, ambiguous-failure classification, the durable journal's persistence,
scoping, cap, conflict/terminal handling and relaunch replay, repeated-exercise plan-item choices
with nil fallback, exercise catalogue/plan-edit decoding, durable offline snapshot/outbox ordering,
local set IDs, cancellation and retention, offline add/form/finish capture, cached-workout relaunch
pending-operation cancellation, unresolved retention, explicit 28-day expiry, ordered replay,
exercise-first workout navigation, working-set rest timer, performed-set add/remove, outside-plan
exercise logging, exercise-library detail/e1RM/history decoding, active-workout conflict blocking and
non-blocking form-rating failure, R5 server-active/ended-elsewhere/consumed-prescription recovery states, and
Phase 3A Apple Watch classification, HRV/RHR/bodyweight selection/freshness, per-metric
eligible/missing/stale states, coalesced authoritative refresh, import/refresh concurrency,
HealthKit request encoding and indeterminate no-sample handling, plus optional per-rep velocity
parsing and the refresh gate before import. Watch tests cover credential payload validation,
epoch/configVersion ordering, stale/revoked re-ack, config-only refresh without a token, the
watch Keychain/metadata split, mint/list/revoke requests, the phone handoff state machine, a lost
acknowledgement, re-mint on missing credentials, deliberate revoke suppression, cross-device
revocation rejection, duplicate-revocation idempotence, tokenless-probe recovery from stale
metadata, credential-lineage replacement, Home-only watch API routing, configuration-version
re-baselining, and convergence to a fresh epoch or config without an acknowledgement loop. The
read-only watch Today tests cover plan-state mapping, strict target filtering (including
missing/unknown targets), plan item labels, bootstrap plus plan fetches over the supplied watch
session, and authentication failure. AppModel integration tests cover watch-coordinator startup
after initial pairing, existing-pair launch, re-pair reset, and execution-target forwarding. Offline
recovery tests cover active-workout clearing, preserved pending operations, unreadable/unsupported
capture files, retry, explicit discard, write failures, recovery conflicts, telemetry-drop
visibility, and ensuring a failed read is never overwritten.

### Building and testing from the command line

Prerequisites: Xcode 27.x, an iOS 27.x simulator runtime, a watchOS 27.x simulator runtime, and
the Xcode developer directory selected. If `xcode-select -p` prints
`/Library/Developer/CommandLineTools`, every `xcodebuild`
call fails with "requires Xcode"; either select it once
(`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`) or prefix each command with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

The repository tracks `project.xcproj` rather than a `project.pbxproj`; Xcode 27 opens it and
`xcodebuild` reads it directly, so there is nothing to generate first.

```bash
# What exists: four targets and two shared schemes.
xcodebuild -list -project StrengthApp.xcodeproj

# Build the app for a simulator. This also builds and embeds StrengthWatch.app.
xcodebuild -project StrengthApp.xcodeproj -scheme StrengthApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# Build the watch app on its own (use an available watch simulator id).
xcodebuild -project StrengthApp.xcodeproj -scheme StrengthWatch \
  -destination 'platform=watchOS Simulator,id=<watch-simulator-id>' build

# Run every unit test.
xcodebuild test -project StrengthApp.xcodeproj -scheme StrengthApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:StrengthAppTests

# Run one test while iterating.
xcodebuild test -project StrengthApp.xcodeproj -scheme StrengthApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:StrengthAppTests/Phase2AppModelTests/testIssueStartSetAndCompleteFlow
```

`./scripts/ci.sh` wraps the watch build, the app build and the unit-test command above and is
what CI runs. Set `WATCH_DESTINATION` to override the first available Apple Watch simulator.

Install and launch the built app by hand (the UI test does this itself when it is enabled):

```bash
xcrun simctl boot 'iPhone 17'
xcrun simctl install 'iPhone 17' <DerivedData>/Build/Products/Debug-iphonesimulator/StrengthApp.app
xcrun simctl launch 'iPhone 17' com.georgesdibpersonalteam.StrengthApp
```

Two failure modes that are environmental rather than code:

- **"Test crashed with signal kill before establishing connection"** means the simulator session
  is wedged, usually after a test run was killed. `xcrun simctl shutdown all` then boot the device
  again, or run on a different simulator. A clean device always works.
- **A non-interactive shell has no pseudo-terminal**, which `xcodebuild test` needs. Wrap the
  command: `script -q /dev/null xcodebuild test …` (macOS). The build alone does not need it.

The physical-device Phase 3A checklist and rollback steps are in
[`DEVICE-ACCEPTANCE.md`](DEVICE-ACCEPTANCE.md). The Phase 6.2 watch credential handshake,
read-only Today and revocation script is in [`WATCH-ACCEPTANCE.md`](WATCH-ACCEPTANCE.md); it is
owner-run and has not been performed. The server-side backup, migration and pairing-code runbook
is in [the canonical iOS client plan](https://github.com/georgesdib/strength-app/blob/main/docs/plans/IOS-CLIENT-PLAN.md) §13.3.

### Running the live UI tests

The optional UI smoke tests (`StrengthAppUITests`) drive the app against a real server: pairing,
Today, History, Settings, relaunch persistence and Forget, plus the full session flow (readiness →
request workout → settings sheet → Workout ready card → start → add a manual-VBT set → force-quit/relaunch
recovery → finish → Progress). They are skipped unless `StrengthAppUITests/LiveConfig.swift` is
generated with `enabled = true` and a fresh pairing code; the committed copy is disabled so the
normal gate needs no server. The shared scheme includes both test targets. The simulator test run
needs normal (ad-hoc) simulator signing so the Keychain is available; a plain app build may pass
`CODE_SIGNING_ALLOWED=NO`.

**Never point a live run at a server holding real training data.** Stand up a throwaway one on
another port:

```bash
# Throwaway server, separate database, non-default port (8000 may be the real one).
strength-coach --db /tmp/live/coach.db web --host 127.0.0.1 --port 8001

# A single-use code; it expires after five minutes, so mint it just before the run.
strength-coach --db /tmp/live/coach.db ios pair --label UITest
```

Write `LiveConfig.swift` with `enabled = true`, `serverURL = "http://127.0.0.1:8001"`,
`pairingCode` from the command above, and `expectedSessionDate` set to a date the History screen
will show — seed one by completing a workout through the API, or skip the History assertion by
using the pairing test instead.

**Point the app at the port with UserDefaults, not by typing.** XCUITest typing into the server
field is flaky, and more importantly the app's Debug default is `http://127.0.0.1:8000`, so a test
that only types when the field "looks wrong" will happily pair against the real server. Set the
value before launching instead:

```bash
xcrun simctl spawn 'iPhone 17' defaults write com.georgesdibpersonalteam.StrengthApp \
  ios.serverURL "http://127.0.0.1:8001"
```

The app keeps that value across launches (Forget clears the token, not the URL), so the run is
deterministic. The UI test also compares the field against `LiveConfig.serverURL` and types only
when they differ.

Restore `LiveConfig.swift` afterwards (`git checkout -- StrengthAppUITests/LiveConfig.swift`); a
filled copy carries a server address and a pairing code and must never be committed.

### Sandboxed or headless shells

Nothing here is needed when the build runs in an ordinary terminal or in Xcode; these are
workarounds for shells whose sandbox denies what the toolchain expects.

- **SwiftUI macros fail** with "external macro implementation type … could not be found" and
  `sandbox-exec: sandbox_apply: Operation not permitted`: the compiler sandboxes its macro plugin.
  Disable that nesting for the invocation:

  ```bash
  OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox' \
  xcodebuild build -project StrengthApp.xcodeproj -scheme StrengthApp -destination '…'
  ```

  If the Clang module cache is also unwritable, point it inside the workspace as well:
  `-Xcc -fmodules-cache-path=$PWD/clang-module-cache`.
- **Tests need a pseudo-terminal** (`script -q /dev/null`), as noted above, and simulator access
  from the harness itself; a workspace-only file sandbox may block `simctl`, launching the test
  runner, or taking screenshots.

## Continuous integration

[`.github/workflows/ios-ci.yml`](.github/workflows/ios-ci.yml) runs on every push to `main`,
on pull requests targeting `main`, and on manual dispatch. A GitHub-hosted `xcode-27` runner
selects Xcode 27.2, then builds the app and runs the `StrengthAppTests` unit-test target on a
simulator. UI tests are excluded: they need a live server, a one-use pairing code and seeded data,
none of which belong in CI.

The same work is one local command:

```bash
./scripts/ci.sh
```

It builds and runs the unit tests, and refuses to run if `StrengthAppUITests/LiveConfig.swift` is
filled in. Override the destination, test filter or derived-data path with
`DESTINATION=… ONLY_TESTING=… DERIVED_DATA=…`.

The workflow runs on pull requests as well as post-merge pushes, so the check is available to
PRs. The app targets iOS 27.0 (`IPHONEOS_DEPLOYMENT_TARGET`), matching the oldest simulator
runtime on the hosted image — a higher floor with no matching runtime makes the test step
impossible to run there. The local Mac currently has only the iOS 27.2 simulator runtime, so the
local gates build with a 27.0 minimum and execute on 27.2.

## Real-device acceptance

Phase 1 and Phase 2 completed 2026-11-07; the records are in
[DEVICE-ACCEPTANCE.md](DEVICE-ACCEPTANCE.md). Phase 3 needs its own approved contract and has not
started.

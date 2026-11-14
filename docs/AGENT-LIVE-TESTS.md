# Agent live tests — StrengthApp

How to run the optional UI acceptance tests without touching real training data. Read
../AGENTS.md and AGENT-WORKFLOWS.md first.

## 1. Safety

- Never point a live run at the real server or live database.
- Use a disposable database and a non-default port.
- LiveConfig.swift is tracked with empty defaults. A filled copy carries a server address and
  a one-use pairing code; restore it after the run.
- Do not copy a pairing code or token into tracked files, logs or the final summary.
- Stop the temporary server when finished.

## 2. Start a disposable server

    rm -rf /tmp/strengthapp-live-ui
    mkdir -p /tmp/strengthapp-live-ui
    .venv/bin/strength-coach --db /tmp/strengthapp-live-ui/coach.db web \
      --host 127.0.0.1 --port 8001

Run it as a managed background job. Verify GET / returns 200.

Mint a fresh code immediately before the test:

    .venv/bin/strength-coach --db /tmp/strengthapp-live-ui/coach.db ios pair --label UITest

The code is single-use and expires after five minutes.

## 3. Configure the app

Write StrengthAppUITests/LiveConfig.swift:

    enum LiveConfig {
        static let enabled = true
        static let serverURL = "http://127.0.0.1:8001"
        static let pairingCode = "<fresh code digits>"
        static let expectedSessionDate = "YYYY-MM-DD"
    }

Do not commit this file. The debug default is port 8000, so the UI test also sets
argument-domain defaults:

    -ios.serverURL <LiveConfig.serverURL>
    -ios.server.homeURL <LiveConfig.serverURL>

This prevents an old app container from silently pairing with a real default server. The test
still asserts/completes the visible server field.

If you need the defaults for a manual run:

    xcrun simctl spawn <simulator-id> defaults write \
      com.georgesdibpersonalteam.StrengthApp ios.serverURL "http://127.0.0.1:8001"

## 4. Run

Run only the needed live test; both tests consume a pairing code, so mint a fresh one between
runs and update LiveConfig.pairingCode.

    xcodebuild test -project StrengthApp.xcodeproj -scheme StrengthApp \
      -configuration Debug \
      -destination 'platform=iOS Simulator,id=<simulator-id>' \
      -derivedDataPath <derived> \
      -only-testing:StrengthAppUITests/StrengthAppUITests/<test-name> \
      OTHER_SWIFT_FLAGS='-disable-sandbox -Xcc -fmodules-cache-path=<derived>/clang-module-cache'

Use danger-full-access for the pseudo-terminal. Do not run the whole UI suite unless the
pairing-code lifecycle is handled.

## 5. Tests

testPairReadRelaunchAndForgetAgainstTheLiveServer
- pairs, reads Today/History/Settings, relaunches, verifies Keychain persistence, forgets.
- Needs a completed session whose occurred_on matches expectedSessionDate.
- Settings is a lazy list: scroll to forget-device and Device id.

testPhase2ReadinessPrescriptionWorkoutAndProgressAgainstTheLiveServer
- pairs, logs readiness, requests/starts a workout, adds a plan exercise, logs a set, force
  quits/relaunches, recovers, finishes, opens Exercise Library, checks Progress.
- A clean database may legitimately show Eligible observations, 0 · unavailable for e1RM.
- The set path can trigger the notification permission prompt; handle only if it blocks.

ExpectedSessionDate can be seeded by running the workout test first, then using the actual
server date for the pairing test with a new code.

## 6. Cleanup

1. app.terminate() or stop the simulator app.
2. Restore the committed config:

    git checkout -- StrengthAppUITests/LiveConfig.swift

3. Confirm the visible file has enabled = false.
4. Stop the disposable server job.
5. Check git status; no filled config or generated artifacts may remain.
6. Do not merge or push an integration branch until the owner says so.

## 7. Evidence and limitations

- Report test names, pass/fail and duration.
- Simulator UI success does not prove physical notification, vibration, haptics, landscape or
  real-device Keychain behaviour.
- Physical acceptance remains a separate owner step.

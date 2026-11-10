# Agent workflows — StrengthApp

Detailed procedures for the native iPhone client. The lean entry point is ../AGENTS.md;
workspace-wide rules are in ../../AGENTS.md.

## 1. Branch

- Work on development; main is integration-only.
- Merge development into main with a merge commit, never squash. Squash is for short-lived
  feature branches only.
- Do not merge or push an integration branch until the owner explicitly says so.
- Keep the CI workflow aligned with main; scripts/ci.sh is the single entry point.

## 2. Toolchain

The deployed minimum is iOS 27.0, and the watch app targets watchOS 27.0. Build with Xcode 27.2.
The local machine has iOS 27.2 and watchOS 27.2 simulator runtimes; hosted CI has 27.0/27.1
runtimes. Do not raise either deployment target without checking the hosted runtime.

xcode-select points at CommandLineTools on this machine, so prefix build/test commands:

    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    export PATH="/Applications/Xcode.app/Contents/Developer/usr/bin:$PATH"

xcodebuild test needs pseudo-terminal access. Under the sandbox it fails with
IDEPseudoTerminalDomain code 7; request danger-full-access for that invocation, do not keep
retrying under workspace-write. Do not run sudo xcode-select -s.

Use a fresh derived-data path for a clean gate. Disable macro sandbox nesting when needed:

    OTHER_SWIFT_FLAGS='-disable-sandbox -Xcc -fmodules-cache-path=<derived>/clang-module-cache'

## 3. Build and test lanes

CI:

    scripts/ci.sh

It builds StrengthWatch on the first available Apple Watch simulator, builds StrengthApp
(including the embedded Watch/StrengthWatch.app), and runs StrengthAppTests on an iPhone
simulator. Override the watch with WATCH_DESTINATION. It refuses to run if LiveConfig.swift is
filled. UI tests are excluded because they need a live server and pairing data.

Focused unit run:

    xcodebuild test -project StrengthApp.xcodeproj -scheme StrengthApp \
      -destination 'platform=iOS Simulator,id=<simulator-id>' \
      -derivedDataPath <derived> -only-testing:StrengthAppTests \
      OTHER_SWIFT_FLAGS='-disable-sandbox -Xcc -fmodules-cache-path=<derived>/clang-module-cache'

Watch-only build:

    xcodebuild -project StrengthApp.xcodeproj -scheme StrengthWatch \
      -destination 'platform=watchOS Simulator,id=<watch-simulator-id>' \
      -derivedDataPath <derived> build

Release compile:

    xcodebuild -project StrengthApp.xcodeproj -scheme StrengthApp \
      -configuration Release -destination 'platform=iOS Simulator,id=<simulator-id>' \
      -derivedDataPath <derived> build CODE_SIGNING_ALLOWED=NO

Run only the tests the change requires unless the owner asks for a full run. Do not repeat
the full suite to watch it. Live UI tests use docs/AGENT-LIVE-TESTS.md.

## 4. Completion checks

1. The narrowest relevant unit/UI tests pass.
2. A new behaviour has a test that fails without it.
3. The app and the watch target build under the current minimums, and the app contains
   Watch/StrengthWatch.app.
4. LiveConfig.swift is disabled and git status is clean.
5. UI changes are checked in portrait and landscape where relevant.
6. User-visible changes update README/USER-GUIDE or relevant contract docs.
7. Physical-only behaviour is not claimed from simulator evidence.

## 5. CI rules

.github/workflows/ios-ci.yml runs on pushes to main, PRs targeting main, and manual dispatch.
It selects Xcode 27.2 and calls scripts/ci.sh, which builds both schemes. Change the script,
not the workflow. Keep the workflow trigger and documentation in sync.

The script refuses a filled LiveConfig.swift. A filled config carries a server address and a
one-use pairing code.

## 6. Build/test quirks

Standing owner rule: anything that surprises you and costs a retry gets a dated row in
private/BUILD-TEST-QUIRKS.md in the same turn. Read that file before a build/test run.

- Append, do not rewrite. A superseding fix gets a new row.
- It may name local paths/ports/simulators but never pairing codes, tokens, real server
  addresses, live DB paths or personal training data.
- Durable fixes are promoted into README.md; the raw row stays private.
- The rule covers Python and iOS loops, including optional test layers.

## 7. Documentation

- README.md — build/test/architecture.
- USER-GUIDE.md — owner-facing iPhone use.
- docs/AGENT-LIVE-TESTS.md — disposable live server/UI acceptance.
- docs/AGENT-CONTRACTS.md — server authority and additive client/server changes.
- DEVICE-ACCEPTANCE.md — physical acceptance checklist.

Do not duplicate live-test secrets or real server values in tracked files.

## 8. Reporting

Report only:
- task and changed files;
- decisions/assumptions;
- test status, including whether the run was focused/full/live;
- open risks, especially anything not physically validated;
- next action.

# AGENTS.md — working in StrengthApp (iOS client)

Rules for any agent (or human) editing this repository. The project overview and the build/test
recipe are in [`README.md`](README.md); the server contracts live in the sibling
`strength-training-app` repository.

## Standing rule — write down every build/test quirk

Owner instruction (2026-11-08): when building, running tests, or testing the app, anything that
surprises you and costs a retry is recorded, not just worked around. Add a dated row — symptom,
cause, fix — to the machine-local notebook `private/BUILD-TEST-QUIRKS.md` in the same turn, and
read that file before an iOS build/test run.

- Append; do not rewrite. A fix that stops working gets a new row that supersedes the old one.
- The notebook is git-ignored and stays that way. It may name local paths, ports and simulators;
  it must still never hold a pairing code, a token, the real server address, a path to the live
  database or personal training data. A code is single-use and expires after five minutes — that
  is not a reason to copy it.
- The rule covers the whole loop, including the Python suite: a green default lane still excludes
  `integration`, `golden`, `regression` and `slow`.
- A general fix (one that would help any machine) is promoted into `README.md`; the raw row stays
  in the notebook.
- The generic recipe is public; the notebook is not. When in doubt, keep operational detail out of
  tracked files.

## Never commit a live configuration

`StrengthAppUITests/LiveConfig.swift` is tracked with empty defaults so a fresh clone builds.
After any live run, restore it (`git checkout -- StrengthAppUITests/LiveConfig.swift`) and check
`git status`. A filled copy carries a server address and a one-use pairing code, and a live run
pairs a device and writes readiness, a prescription and a workout.

## Toolchain on this machine

`xcode-select` points at `/Library/Developer/CommandLineTools`, so every `xcodebuild` call
needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and Xcode's `usr/bin` on
`PATH`; `xcodebuild test` also needs a pseudo-terminal. The failure-to-fix rows live in
`private/BUILD-TEST-QUIRKS.md`; the commands that work are in README's "Building and testing
from the command line".

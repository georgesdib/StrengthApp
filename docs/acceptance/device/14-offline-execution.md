_Part of the device acceptance record. Index: [DEVICE-ACCEPTANCE.md](../../../DEVICE-ACCEPTANCE.md)._

# Unified offline execution — closed by owner decision (2026-11-23)

**Status:** closed. The owner accepted the physical-device matrix as done on 2026-11-23 rather than
running it as a separate checklist. This record states that decision; it does not claim that each
hardware scenario was individually observed.

Scope: C1/C2 offline ledger, phone-committed watch execution, S5 pairing scope, the audit
remediation, and follow-up findings 1/2/3/5.

## Automated

- [x] Client `scripts/ci.sh`: 563 tests, 1 skipped, 0 failures; iPhone and watch schemes build.
- [x] Server `check.sh full`: 2469 passed, 1 skipped.
- [x] Completed start replay, optimistic offline change (pending and rejected), dose/VBT catalogue
      parity, set origin and watch phone-commit suites pass.

## Physical device

Owner decision, 2026-11-23: **consider the matrix done.** No separate pass/fail checklist was run
for:

- watch-only start with the phone off, phone completing first, then replay and late sets;
- both devices partitioned, termination mid-set, watch reboot;
- late sets inside/outside the reconciliation window;
- HealthKit 1/1/2 saves;
- corrections/removals and the visible technique throttle;
- a version-1 capture upgraded mid-workout.

## Release

App-first per the canonical plan §20: ship the app build, smoke-test phone start/logging, then
merge/deploy the server and verify the watch/offline surfaces. Deployed-commit and app-build
verification are recorded in the release notes, not here.

Owner sign-off: 2026-11-23.

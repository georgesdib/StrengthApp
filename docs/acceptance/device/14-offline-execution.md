_Part of the device acceptance record. Index: [DEVICE-ACCEPTANCE.md](../../../DEVICE-ACCEPTANCE.md)._

# Unified offline execution — closed 2026-11-23; user testing confirmed 2026-11-25

**Status:** closed. Physical-device user testing was done and owner-confirmed on 2026-11-25.
This record states the outcome; it does not itemise every scenario.

Scope: C1/C2 offline ledger, phone-committed watch execution, S5 pairing scope, the audit
remediation, and follow-up findings 1/2/3/5.

## Automated

- [x] Client `scripts/ci.sh`: 563 tests, 1 skipped, 0 failures; iPhone and watch schemes build.
- [x] Server `check.sh full`: 2469 passed, 1 skipped.
- [x] Completed start replay, optimistic offline change (pending and rejected), dose/VBT catalogue
      parity, set origin and watch phone-commit suites pass.

## Physical device

Owner-confirmed 2026-11-25: physical-device user testing was done on the installed build, against
the deployed server.

## Release

The server was deployed first at `34e7f29` on 2026-11-23 (migrations `0076`–`0080`, service
active). The app build was installed and user-tested against it.

Owner sign-off: 2026-11-25.

_Part of the device acceptance record. Index: [DEVICE-ACCEPTANCE.md](../../../DEVICE-ACCEPTANCE.md). Content preserved verbatim._

# Phase 3A device acceptance checklist — complete

**Status: physically tested and owner-confirmed 2026-11-08.** The implementation is also
unit/simulator/live-server verified. The canonical server-side commands, backup, migration,
pairing-code and rollback runbook is [iOS client plan](https://github.com/georgesdib/strength-app/blob/main/docs/plans/IOS-CLIENT-PLAN.md) §13.3 in
this repository.

## Before you start

- [x] The server repository is at the Phase 3A implementation commit and the client repository is
      at the Phase 3A client commit.
- [x] Stop the running `strength-coach web` process. Confirm the port is no longer listening.
- [x] Take and verify a full live-database backup before applying migration 0054. The archive
      contains health data; keep it off the phone and out of git.
- [x] Start the server normally; on startup it applies `0054_healthkit_readiness.sql`.
- [x] Verify `schema_migration` is at `0054`, `healthkit_readiness` exists, and
      `PRAGMA quick_check` is `ok`.
- [x] The server is reachable only on the trusted home LAN, over plain HTTP, with no port
      forwarding or public address.
- [x] Xcode 27.2, the personal team, the owner's iPhone and local-network permission are ready.
- [x] The server reports `healthkit_readiness: true` in bootstrap.

## Pairing code

- [x] Mint a fresh code only when the phone is ready:

      ```bash
      .venv/bin/strength-coach --db data/coach.db ios pair --label "iPhone Phase 3A"
      ```

- [x] The CLI prints a grouped 8-digit code and its expiry. The code is one-use, has a 300-second
      default TTL and allows five attempts. Do not store it in a screenshot, ticket or commit.
- [x] Enter the server LAN URL (for example `http://192.168.1.10:8000`), the code and the label
      in the app's Pairing screen. Pairing returns to Today.
- [x] A malformed, wrong, expired or reused code shows the server error and creates no device.
- [x] If the phone is already paired, skip the fresh pairing; test the HealthKit path without
      disturbing the existing keychain item.

## HealthKit setup and import

- [x] Settings -> HealthKit -> enable **Readiness from HealthKit**.
- [x] Grant read access to HRV, Resting Heart Rate and Body Mass only. The Body Mass prompt appears
      when the toggle is enabled/refreshed; no write access is requested.
- [x] The readiness form shows HealthKit HRV/RHR/bodyweight values, source and age alongside the
      manual fields; entering a manual value overrides it and leaving it blank keeps the automatic one.
- [x] Today shows the HealthKit section with the import action.
- [x] Import from HealthKit (or pull to refresh) completes.
- [x] HRV is the newest eligible sample within 48 hours; RHR is from the current server-local day;
      bodyweight is the newest sample within 30 days.
- [x] Today shows effective HRV/RHR/bodyweight values, effective source, sample age, score/status
      and basis.
- [x] Stored `healthkit` provenance is distinct from the effective values.
- [x] If no eligible sample exists, the copy says it can mean no data or access not granted; it
      does not claim denial and does not show zero.
- [x] A stale sample is identified as stale and is not imported as today's value.
- [x] Partial availability is independent: HRV eligible + RHR stale, RHR eligible + HRV missing,
      both missing/stale, and both eligible each show the correct per-metric wording.
- [x] If the POST succeeds but the authoritative GET fails, the import is shown as accepted with a
      refresh error; no duplicate import is attempted.

## Precedence, identity and persistence

- [x] Record a manual HRV, RHR and/or bodyweight, then import again: the manual values remain effective and the
      HealthKit observation remains visible as provenance.
- [x] Import the same sample twice: no duplicate observation is created.
- [x] Force-quit/relaunch: the HealthKit toggle and server data are still present.
- [x] No sleep, workout, cardio or write access is requested or displayed.
- [x] Existing manual readiness, prescription, workout, completion and Progress flows still work.

## Rollback if rejected

- [x] Stop the server.
- [x] Turn the client HealthKit toggle off; manual readiness remains unaffected.
- [x] If a schema rollback is required, remove the client importer and canonical-merge integration
      first, then drop `healthkit_readiness` and delete the `0054` schema_migration row together.
- [x] If restoring the pre-test database is safer, extract only `data/coach.db` from the verified
      backup with the server stopped, and remove `-wal`/`-shm` sidecars. This discards any
      training recorded after the backup.

## Sign-off

| Check | Result | Notes |
|---|---|---|
| Backup and migration verification | pass | owner-confirmed 2026-11-08 |
| Pairing and code rejection paths | pass | owner-confirmed 2026-11-08 |
| HealthKit opt-in and read-only permission | pass | owner-confirmed 2026-11-08 |
| HRV/RHR/bodyweight source, freshness and effective display | pass | owner-confirmed 2026-11-08 |
| No-sample/stale indeterminate states | pass | owner-confirmed 2026-11-08 |
| Manual precedence and sample identity | pass | owner-confirmed 2026-11-08 |
| Existing Phase 2 workflow unchanged | pass | owner-confirmed 2026-11-08 |
| Rollback understood | pass | owner-confirmed 2026-11-08 |

Owner confirmation: pass 2026-11-08 · Build: Phase 3A · Device: physical iPhone · iOS: 27.2


---

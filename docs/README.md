# StrengthApp documentation index

Entry point for the native iPhone client repository. The server remains authoritative for
training policy, readiness, prescriptions, loads, sets and scoring; client docs describe how the
app presents and records that authority.

## Start here

- [README.md](../README.md) — project overview, requirements, build recipe and screens.
- [USER-GUIDE.md](../USER-GUIDE.md) — owner-facing pairing, workout, HealthKit and troubleshooting guide.
- [DEVICE-ACCEPTANCE.md](../DEVICE-ACCEPTANCE.md) — index of physical iPhone acceptance records,
  split by phase under `docs/acceptance/device/`.
- [WATCH-ACCEPTANCE.md](../WATCH-ACCEPTANCE.md) — index of owner-run watch acceptance records
  (6.2b–6.7) under `docs/acceptance/watch/`; the 6.7 record is owner-confirmed 2026-11-14
  (W1–W12 and R).
- `docs/acceptance/` — per-record files linked from those two indexes; read only the relevant record.

## HealthKit

- [HEALTHKIT.md](HEALTHKIT.md) — what the phone and watch read from and write to HealthKit today, the
  exactly-once workout save rule and the privacy limits (denied read is indistinguishable from no
  data) that constrain every future import. Read it before changing any HealthKit code.

## Offline execution

- **Unified offline execution (closed 2026-11-23).** Device-independent offline execution is
  implemented on both sides, including phone-committed watch writes, optimistic offline
  substitutions/additions, the dose-aware catalogue and durable set origin. Read
  [the canonical plan](https://github.com/georgesdib/strength-app/blob/offline-execution/docs/plans/UNIFIED-OFFLINE-EXECUTION.md);
  it is the source of truth. Physical acceptance was closed by owner decision; release is app-first.
- [Offline execution client implementation](OFFLINE-EXECUTION.md) — what C1/C2 changed in the app,
  the plan-only watch cache, the ledger, merge rules and the follow-up findings.

## Client plan and contracts

- [iOS client plan](https://github.com/georgesdib/strength-app/blob/main/docs/plans/IOS-CLIENT-PLAN.md) — phased iPhone implementation plan, architecture
  invariants, rollback gates and completion records.
- [Server API contract](https://github.com/georgesdib/strength-training-app/blob/development/docs/API.md)
  — authoritative HTTP routes and limits.
- [iOS Phase 1 contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-PHASE-1-CONTRACT.md)
- [iOS Phase 2 contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-PHASE-2-CONTRACT.md)
- [iOS Phase 3A contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-PHASE-3A-CONTRACT.md)
- [iOS Phase 4 contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-PHASE-4-CONTRACT.md)
- [iOS R7 contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-R7-CONTRACT.md)
- [iOS R8 contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-R8-CONTRACT.md)
- [watchOS Phase 6 contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-WATCH-CONTRACT.md)
- [Training Intelligence plan](https://github.com/georgesdib/strength-app/blob/main/docs/plans/TRAINING-INTELLIGENCE.md)
  — the delivered cross-repository plan for the read-only intelligence capability layer, the standalone
  MCP server and the native Apple adapters. Delivered 2026-11-15: read-only Siri/Shortcuts intents,
  workout automation (Shortcuts and HomeKit scenes), the Action button, watch Siri and the Shortcuts
  start/finish pair. INT-9 (the Siri AI Developer Preview adoption pass) is deferred until iOS 27.3 and
  PCC (INT-4c) is parked on Apple's entitlement.
- [Training Intelligence contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/TRAINING-INTELLIGENCE-CONTRACT.md)
  — response envelope, MCP tool/resource catalogue and the native iOS adapter rules (five-tool cap,
  no Swift calculation).
- [Cardio stage plan](https://github.com/georgesdib/strength-app/blob/development/docs/plans/CARDIO-STAGE.md)
  — proposed cross-repository plan for HealthKit workout ingestion, canonical backend cardio data and
  cardiovascular monitoring. Nothing is implemented: C0 is a local data audit and C1–C7 are gated on its
  decision record. The wider HealthKit read authorisation, historical backfill, reconciliation queue and
  cardio dashboards it describes are **not** current client behaviour.
- [Watch phone gateway](WATCH-GATEWAY.md) — WP8 relay envelope, direct-first fallback, identity, idempotency and waiting states.
- [Watch 6.3 execution-lifecycle slice plan](WATCH-6.3-PLAN.md) — client-side slices, files and tests for Phase 6.3; the contract above stays authoritative.
- [Watch 6.6 active-session plan](WATCH-6.6-PLAN.md) — client-side destinations, refresh/reconnect, ownership corrections and acceptance pointers; the contract above stays authoritative.

Shared server/client phase contracts are canonical in the portfolio `docs/contracts/` directory; backend implementation, migrations and tests stay in the server repository. Do not maintain duplicate contract text here.

## Agent guidance

- [AGENT-WORKFLOWS.md](AGENT-WORKFLOWS.md) — build, test, CI, toolchain and completion procedure.
- [AGENT-LIVE-TESTS.md](AGENT-LIVE-TESTS.md) — disposable-server live UI setup and cleanup.
- [AGENT-CONTRACTS.md](AGENT-CONTRACTS.md) — API authority and additive client/server contract rules.
- [../AGENTS.md](../AGENTS.md) — lean agent entry point.

## Repository ownership

- Shared phase plans and server/client contracts → [portfolio canonical docs](https://github.com/georgesdib/strength-app/blob/main/docs/README.md).
- Client UI/UX implementation, iPhone user guide, device acceptance, client build/test/live-test guidance → this repository.
- Server API/data-model implementation, schema/migrations, server web UI and backend operations → sibling `strength-training-app` repository.
- Portfolio routing and documentation policy → [portfolio ownership rules](https://github.com/georgesdib/strength-app/blob/main/docs/DOCUMENTATION.md).

When adding a document, put it in the repository that owns the subject and link across
repositories with absolute GitHub URLs.


### Canonical shared phase contracts

Use the portfolio [iOS contract index](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/README.md). Local client-specific acceptance/build instructions remain in this repository.

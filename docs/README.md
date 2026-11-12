# StrengthApp documentation index

Entry point for the native iPhone client repository. The server remains authoritative for
training policy, readiness, prescriptions, loads, sets and scoring; client docs describe how the
app presents and records that authority.

## Start here

- [README.md](../README.md) — project overview, requirements, build recipe and screens.
- [USER-GUIDE.md](../USER-GUIDE.md) — owner-facing pairing, workout, HealthKit and troubleshooting guide.
- [DEVICE-ACCEPTANCE.md](../DEVICE-ACCEPTANCE.md) — physical iPhone acceptance checklists and records.

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

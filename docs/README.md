# StrengthApp documentation index

Entry point for the native iPhone client repository. The server remains authoritative for
training policy, readiness, prescriptions, loads, sets and scoring; client docs describe how the
app presents and records that authority.

## Start here

- [README.md](../README.md) — project overview, requirements, build recipe and screens.
- [USER-GUIDE.md](../USER-GUIDE.md) — owner-facing pairing, workout, HealthKit and troubleshooting guide.
- [DEVICE-ACCEPTANCE.md](../DEVICE-ACCEPTANCE.md) — physical iPhone acceptance checklists and records.

## Client plan and contracts

- [IOS-CLIENT-PLAN.md](IOS-CLIENT-PLAN.md) — phased iPhone implementation plan, architecture
  invariants, rollback gates and completion records.
- [Server API contract](https://github.com/georgesdib/strength-training-app/blob/development/docs/API.md)
  — authoritative HTTP routes and limits.
- [iOS Phase 1 contract](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-PHASE-1-CONTRACT.md)
- [iOS Phase 2 contract](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-PHASE-2-CONTRACT.md)
- [iOS Phase 3A contract](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-PHASE-3A-CONTRACT.md)
- [iOS Phase 4 contract](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-PHASE-4-CONTRACT.md)
- [iOS R7 contract](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-R7-CONTRACT.md)
- [iOS R8 contract](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-R8-CONTRACT.md)
- [watchOS Phase 6 contract](https://github.com/georgesdib/strength-training-app/blob/development/docs/design/IOS-WATCH-CONTRACT.md)

The contracts stay in the server repository because they define the server API and data model.
Do not copy them here; link to them.

## Agent guidance

- [AGENT-WORKFLOWS.md](AGENT-WORKFLOWS.md) — build, test, CI, toolchain and completion procedure.
- [AGENT-LIVE-TESTS.md](AGENT-LIVE-TESTS.md) — disposable-server live UI setup and cleanup.
- [AGENT-CONTRACTS.md](AGENT-CONTRACTS.md) — API authority and additive client/server contract rules.
- [../AGENTS.md](../AGENTS.md) — lean agent entry point.

## Repository ownership

- Client plan, client UI/UX, iPhone user guide, device acceptance, client build/test guidance →
  this repository.
- Training methodology, server API/data model, server design contracts, server web UI → the
  sibling `strength-training-app` repository.
- Portfolio routing, machine handoff and documentation policy →
  [the portfolio repository](https://github.com/georgesdib/strength-app/blob/main/docs/DOCUMENTATION.md).

When adding a document, put it in the repository that owns the subject and link across
repositories with absolute GitHub URLs.

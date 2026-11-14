# Agent contracts — StrengthApp

Rules for client/server contract work. Read the iOS `AGENTS.md`, `AGENT-WORKFLOWS.md`, and the portfolio canonical docs index at https://github.com/georgesdib/strength-app/blob/main/docs/README.md; the server remains authoritative for API behavior and training decisions.

## 1. Authority

The server owns training policy, readiness, prescriptions, loads, sets, progression, e1RM,
volume and scoring. The client may display, capture and replay performed-work data, but it
must not compute or invent plan content or training decisions.

When server and client disagree, stop and inspect the contract; do not make the client the
source of truth.

## 2. Canonical contracts

Shared iOS phase contracts are canonical in the portfolio repository: https://github.com/georgesdib/strength-app/blob/main/docs/contracts/README.md . Individual documents:
- [iOS Phase 1 contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-PHASE-1-CONTRACT.md)
- [iOS Phase 2 contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-PHASE-2-CONTRACT.md)
- [iOS Phase 3A contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-PHASE-3A-CONTRACT.md)
- [iOS Phase 4 contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-PHASE-4-CONTRACT.md)
- [iOS R7 contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-R7-CONTRACT.md)
- [iOS R8 contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-R8-CONTRACT.md)
- [watchOS Phase 6 contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/IOS-WATCH-CONTRACT.md)
- [Training Intelligence contract](https://github.com/georgesdib/strength-app/blob/main/docs/contracts/TRAINING-INTELLIGENCE-CONTRACT.md) — proposed; the intelligence envelopes are additive read-only payloads, and the client must not compute any metric, gate, evidence id or comparison from them.

The backend API reference and data-model implementation details remain in this repository: [`docs/API.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/API.md) and [`docs/DATA-MODEL.md`](https://github.com/georgesdib/strength-training-app/blob/development/docs/DATA-MODEL.md). The shared phase plan is [canonical in the portfolio](https://github.com/georgesdib/strength-app/blob/main/docs/plans/IOS-CLIENT-PLAN.md); it does not replace these implementation references.

Read the relevant portfolio contract before editing. Do not infer a contract from Swift models alone.

## 3. Cross-repo change checklist

For API, schema, authentication or client/server behaviour changes:

1. Read the contract and state which side is authoritative.
2. Produce a plan before editing.
3. Add/update server contract documentation, implementation and tests.
4. Add/update iOS models/decoding, API client and tests.
5. Verify additive compatibility; no silent required-field changes.
6. Run the narrowest server tests and the narrowest iOS tests.
7. Report server/client commits separately; do not merge either branch without approval.

## 4. API rules

- New fields are additive; existing clients must keep decoding.
- Closed request schemas reject unknown fields with useful validation errors.
- Mutations use existing idempotency receipts and stable operation identities.
- Do not claim server acceptance before acknowledgement.
- Preserve original occurrence timestamps across offline replay.
- Resolve ambiguous failures explicitly; never silently attach data to another workout.
- Never create duplicate canonical sets from telemetry events.
- No client-side readiness/prescription/load calculation.
- No public exposure of the local server; iOS uses the authenticated /api/ios/v1/ facade.

## 5. Offline and execution data

- The Phase 4 outbox is the single queue; do not create a parallel sync system.
- Persist locally before acknowledging user actions.
- Preserve FIFO where operations depend on earlier ones.
- Keep unresolved operations visible/actionable.
- Execution events are observational and append-only; workout_set remains canonical.
- Do not infer missing starts/ends/rest; report missing coverage.
- HR observations, if ever added, are separate, opt-in and never training inputs.

## 6. Model/decoding rules

- Match server JSON exactly, including snake_case decoding strategy.
- Optional server fields stay optional in Swift.
- Unknown response fields must not break decoding unless the contract is intentionally closed.
- Error codes are part of the contract; preserve useful server messages.
- Add fixtures/tests for new payload shapes.
- Intelligence payloads (if INT-3 lands) decode into `StrengthCore/Intelligence`; unknown fields must
  not break decoding, and no Swift code may derive a metric, percentage, gate or evidence id from a
  fact block. Model-specific code stays in `StrengthApp/Intelligence`, never in `StrengthCore`.

## 7. Documentation

Update the server API/data-model docs and the client README/USER-GUIDE when user-visible
behaviour changes. Keep shared requirements/contracts in the portfolio canonical documents and server API/data-model implementation detail in the backend; link to those authorities rather than duplicating policy.

## 8. What needs explicit owner approval

- Changing a training rule or threshold.
- Breaking an API contract.
- Making the client authoritative for any training decision.
- Merging or pushing an integration branch.
- Adding a Watch app or a new data-sharing/cloud surface.

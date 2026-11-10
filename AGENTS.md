# AGENTS.md — StrengthApp (iOS client)

Lean entry point for agents editing the native iPhone client. Read the workspace-level
../AGENTS.md first, then the topic document for the task:

- docs/README.md — client documentation index and repository ownership.
- docs/AGENT-WORKFLOWS.md — build, test, CI, toolchain, branch and completion procedure.
- docs/AGENT-LIVE-TESTS.md — disposable-server live UI setup and cleanup.
- docs/AGENT-CONTRACTS.md — API authority and client/server contract rules.
- docs/IOS-CLIENT-PLAN.md — phased client plan, architecture invariants and rollback gates.

README.md remains the project overview and build recipe. The client plan and documentation index
live in this repository; server API/data-model contracts live in the sibling strength-training-app
repository. Do not copy those contracts here.

## Branch

- Development happens on development, not main.
- main is integration-only; merge development into main with a merge commit, never squash.
- Do not merge or push an integration branch without the owner's explicit instruction.

Output discipline and high-risk approval rules are defined by the workspace `../AGENTS.md`.

## Contract authority

The server is authoritative for training policy, readiness, prescriptions, loads, sets,
progression and scoring. The client displays and records; it must not invent plan content or
compute training decisions. Contract changes are additive unless an explicit migration is
agreed. See docs/AGENT-CONTRACTS.md.

## Guardrails

- Never commit a filled StrengthAppUITests/LiveConfig.swift; restore it after a live run.
- Never read, commit or transmit private/, data/, real training exports, health data, tokens
  or pairing codes.
- Record every build/test surprise that costs a retry in private/BUILD-TEST-QUIRKS.md in the
  same turn; read it before an iOS build/test run.
- Keep notification/live behaviour honest: simulator success is not physical-device proof.
- Do not add a Watch app or change scientific training rules without explicit approval.

## Definition of done — short form

1. Narrowest relevant tests pass; add a test that fails without the behaviour.
2. scripts/ci.sh stays the single CI entry point; LiveConfig remains disabled.
3. UI changes are checked in portrait and landscape where relevant.
4. Documentation is updated for user-visible behaviour.
5. Report only task, files, decisions, test status, risks and next action.

Detailed commands and CI rules are in docs/AGENT-WORKFLOWS.md. Live-test setup is in
docs/AGENT-LIVE-TESTS.md.

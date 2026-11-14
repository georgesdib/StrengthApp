# AGENTS.md — StrengthApp (iOS client)

Lean entry point for agents editing the native iPhone client. Read the canonical portfolio shared-doc index at https://github.com/georgesdib/strength-app/blob/main/docs/README.md first (a sibling workspace checkout is not assumed), then the topic document for the task:

- docs/README.md — client documentation index and repository ownership.
- docs/AGENT-WORKFLOWS.md — build, test, CI, toolchain, branch and completion procedure.
- docs/AGENT-LIVE-TESTS.md — disposable-server live UI setup and cleanup.
- docs/AGENT-CONTRACTS.md — API authority and client/server contract rules.
- https://github.com/georgesdib/strength-app/blob/main/docs/plans/IOS-CLIENT-PLAN.md — phased client plan, architecture invariants and rollback gates.

README.md remains the project overview and build recipe. Client build/test/UI/live-test and device-acceptance docs stay here. Shared phase plans and server/client contracts are canonical in the portfolio docs; server API/data-model implementation docs stay in the sibling strength-training-app repository. Do not duplicate shared plans or contracts.

## Branch

- Development happens on development, not main.
- main is integration-only; merge development into main with a merge commit, never squash.
- Do not merge or push an integration branch without the owner's explicit instruction.

Output discipline and high-risk approval rules are in the canonical portfolio `AGENTS.md`: https://github.com/georgesdib/strength-app/blob/main/AGENTS.md .

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


## Shared documentation changes

Do not maintain shared plan/contract copies in this repository. Read and update the portfolio canonical plan/contract when client implementation affects cross-repository requirements; retain client-specific UI/build/test and device acceptance documentation here. Commit client implementation changes on the iOS task branch and shared docs changes in the portfolio repository branch. Update local references and do not update portfolio submodule pointers unless explicitly requested.

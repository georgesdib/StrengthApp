_Part of the device acceptance record. Index: [DEVICE-ACCEPTANCE.md](../../../DEVICE-ACCEPTANCE.md). Content preserved verbatim._

# INT-13 Today summary acceptance — closed by owner decision (2026-11-17)

**Status 2026-11-17:** implemented on the iOS client; automated tests pass. The owner closed the phase
without a physical-device run, so the device checks below remain unverified on hardware.

## Automated

- [x] `TodaySummaryModelTests` and `TodaySummaryFactsTests` — 10 tests, 0 failures.
- [x] One generation per day/readiness/plan/model state; a manual refresh forces another.
- [x] An unavailable model is reported without a generation attempt and never falls back to the other
      model.
- [x] The DeepSeek reply is rejected unless it carries both passages.
- [x] The full `scripts/ci.sh` gate: 437 tests, 1 skipped, 0 failures.

## Physical device — not run (waived)

- [ ] With Apple Intelligence on, the card shows two passages and the footer says **On this iPhone**.
- [ ] With DeepSeek selected and a key saved, the footer says **DeepSeek** and the text arrives.
- [ ] With DeepSeek selected and no key, the card says a key is needed; nothing is generated.
- [ ] With "Include plan and prescription data" off, the DeepSeek summary carries no plan or load.
- [ ] Changing readiness or requesting a session regenerates the card once; idle tab switches do not.
- [ ] The toggle in Settings hides the block on Today.

Owner confirmation: closed by owner decision 2026-11-17; no device run.

---

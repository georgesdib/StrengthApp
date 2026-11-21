_Part of the device acceptance record. Index: [DEVICE-ACCEPTANCE.md](../../../DEVICE-ACCEPTANCE.md). Content preserved verbatim._

# INT-7 Siri and App Intents acceptance — complete (owner-confirmed 2026-11-15)

**Status 2026-11-15:** delivered and owner-confirmed on the physical iPhone (iOS 27.2, Release build
of `development` at `0697889`). Siri routes every read-only phrase to the app and answers with the
deterministic values plus a snippet card.

## Automated

- [x] `StrengthIntents` package product builds and its metadata merges into `StrengthApp.app`.
- [x] Digest tests: overview numbers, empty-window wording, weekly-review sessions and progression,
      progression fallback name, last-workout sentence, average-duration mean and empty case.
- [x] Entity query resolves through the registered provider and filters by identifier.
- [x] Snippet cards render through `ImageRenderer` for weekly review, overview, progression, last
      workout and average duration.
- [x] `scripts/check-shortcut-phrases.sh` passes: every phrase carries the app-name token.

## Physical device — owner-confirmed

- [x] The build installs and launches on the physical iPhone (iOS 27.2).
- [x] "How long was my last workout in StrengthApp" answers with the newest history row.
- [x] "How is my training going in StrengthApp" answers with sessions, mean duration and readiness
      coverage.
- [x] "Weekly review in StrengthApp" answers for the last completed week.
- [x] "How is <exercise> progression in StrengthApp" answers with direction, change and session count.
- [x] "Average workout duration in StrengthApp" answers with the mean and the sample size.
- [x] "Average workout duration over the last 12 weeks in StrengthApp" answers for the 12-week window.
- [x] The metadata build registers the shortcuts after a reinstall; the earlier generic Siri answers
      were a registration problem, not a code problem.

## Not separately recorded on device

- [ ] Snippet cards were seen on device (the views are covered by render tests; the owner confirmed the
      spoken answers, not the cards).
- [ ] The Shortcuts app listing was not opened.
- [ ] The unpaired/offline dialog was not exercised.
- [x] Read-only by inspection: every intent calls a `GET` route (`/intelligence/...` or `/history`)
      and there is no write path in `StrengthIntents`.

## Deferred

- **Spotlight**: `ExerciseEntity` conforms to `IndexedEntity` and the app donates the catalogue with
  `CSSearchableIndex.indexAppEntities`, but search results do not surface on the owner's device. The
  owner accepted the deferral on 2026-11-15. Next probes if it is revisited: Settings → Siri & Search →
  StrengthApp → Show Content in Search, and the `intents` log category.

Owner confirmation: pass 2026-11-15 · Build: INT-7 · Device: iPhone 16 Pro Max (iPhone17,2) · iOS: 27.2

---

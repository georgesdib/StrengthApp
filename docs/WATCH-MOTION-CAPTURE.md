# WATCH MOTION CAPTURE (WP4)

Debug-only per-rep motion recording on the watch. It is not a user feature: it exists to collect
the study data that decides whether tempo and device velocity work at all.

Canonical plan: portfolio `docs/plans/WATCH-MOTION-METRICS.md` §11 (WP4).
Capture contract: portfolio `docs/contracts/IOS-WATCH-CONTRACT.md`, amendment "per-rep motion capture".

## What it records

While a set is open (Start set → End set), the watch samples device motion at the hardware's
highest rate — 100 Hz where available. Each sample carries monotonic time, user acceleration,
rotation rate and gravity. At End set the recording is written to
`Documents/Motion/motion-<timestamp>-<exercise>-set<N>.json` and nothing is uploaded.

The file also carries a **gap report**: expected samples, actual samples, the longest interval and
how many intervals exceeded three nominal periods. A set with gaps cannot be trusted to align rep
boundaries, so the report travels with the data instead of being inferred later.

`method_version` (`tempo/1`) names the derivation algorithm, not the app build. It must be bumped
whenever the derivation changes, because raw samples are discarded after the study window and a
version change is a step change in every derived number.

## Enabling it

The switch only exists in a Debug build:

1. Watch → Today → Settings (the gear).
2. **Motion capture** → **Open**.
3. Turn on **Capture sets**.

Leaving a Release build installed cannot enable it: the toggle is compiled out and the
coordinator returns "off" regardless of stored defaults.

## Device check (owner-run)

Not yet performed. It requires a physical Apple Watch; the simulator has no motion sensor.

1. Wear the watch on the working wrist, strap firm. Note the strap hole.
2. Start a session, open a lift whose plan item carries a motion axis (squat, bench, deadlift,
   press, row). `hip_thrust` and isolation work deliberately have none.
3. Start set → perform 3 reps at a normal tempo → End set → log it.
4. Settings → Motion capture → check the new file appears and reads
   `N samples · vertical` (or `horizontal`).
5. Share it off the watch and open the JSON.

Pass criteria for a set to be admissible:

| Check | Expectation |
|---|---|
| Identity | `context.workoutId`, `exerciseId`, `planItemIndex`, `setOrdinal` match the set just logged |
| Axis | matches the exercise; `null` for hip thrust and isolation work |
| Rate | `actualSamples` ≈ set duration × 100, `droppedFraction` ≤ 0.02 |
| Gaps | `gaps == 0`; `isHealthy == true` |
| Duration | recorded duration within ~0.2 s of Start set → End set |

Collect at least **three sets across two exercises** before calling WP4 accepted. Record one set
with the strap deliberately loose — that is the control for how much strap fit moves the signal.

Also record: battery percentage before and after a 20-minute session with six sets, and whether
the watch got warm. Both decide whether 100 Hz is sustainable for a full session.

## Interpreting a failure

- **"Motion sensor unavailable"** — the watch does not report device motion; nothing was recorded.
- **"No samples captured"** — the set was shorter than the first batch, or sampling never started.
- **Gaps reported** — a stall in delivery, usually a background transition. Note what you did
  (lowered the wrist, walked to the rack) at that moment; it is the most useful field note.
- **Missing file** — the app was killed mid-set; the recording is lost by design rather than
  written partially.

## Retention

A recording is the only copy of its data until it has been exported, so **age alone never deletes
one**. When you confirm a copy exists elsewhere, mark the file exported; only exported files become
eligible for automatic removal, and only after a 30-day backstop. Unexported files stay until you
delete them by hand.

"Clean up exported" purges on demand and also runs when the list opens. It never touches an
unexported file, however old.

Recordings stay on the watch: never attached to an API request, never uploaded. Nothing in this
feature reads HealthKit.

_Part of the watch acceptance record. Index: [WATCH-ACCEPTANCE.md](../../../WATCH-ACCEPTANCE.md). Content preserved verbatim._

## Heart rate and HealthKit (6.5) — owner-run

- [ ] Start a watch session with workout and heart-rate read access allowed: the Set screen shows a
      live **bpm** while the wrist is raised, and it disappears if HR is not authorised.
- [ ] Log a couple of sets, finish with an sRPE, and confirm Health holds **exactly one**
      strength-training workout with the real start and end, the session's effort, and HR samples.
- [ ] Repeat with HR read **denied**: the workout still saves, with no HR.
- [ ] With active-energy read allowed, the saved workout shows a non-zero **Active Energy**
      total in Health; if it is denied, the workout still saves without calories.
- [ ] Finish, then force-quit before the watch syncs. Relaunch: the summary returns, Health still
      shows exactly one workout, and the server finish replays once.
- [ ] Mid-session, force-quit and relaunch, then finish: Health holds one workout with the original
      start, with **no HR** for the pre-crash segment (the documented trade).
- [ ] Deny Health access mid-session, finish: the workout reports **not saved** once, with
      **Try again** and **Dismiss**; Try again after re-allowing access saves the same workout
      once, and Dismiss removes the notice without changing the record.
- [ ] Abandon a session: Health gains no workout.
- [ ] The Health app shows the effort value matching the chosen sRPE, and nothing when
      *Not recorded* was chosen.


### Corrective checks (6.5 audit)

- [ ] Watch clock set five minutes fast, start and finish a session: the Health workout's start and
      end are the real times, and its duration is not negative or shifted.
- [ ] With Health access denied mid-session, finish: the summary reports the workout was **not
      saved**, and Health holds no duplicate after retrying later.
- [ ] Force-quit during finalisation, relaunch with the server finish still pending: the watch does
      **not** create a new live workout; Health gains either the existing workout or one minimal
      backdated one — never two, and never one that starts at relaunch time.
- [ ] Deny effort write while allowing workouts: the workout saves, and the summary says
      **Effort was not saved** without retrying the workout.
- [ ] Leave the watch still with HR shown: the value disappears within ~30 seconds when readings
      stop, and never shows 0 for "no data".



---

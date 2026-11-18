# StrengthApp — iPhone user guide

This is the owner-facing guide for the native iPhone client. The server, web UI and training
engine are documented separately in the
[strength-training-app docs](https://github.com/georgesdib/strength-training-app/blob/development/docs/README.md).

## 1. What the app does

StrengthApp is a companion for one local strength-coach server. Python remains the authority for
readiness scoring, prescriptions, loads, sets, e1RM, volume and training decisions. The phone
displays those results and records what actually happened during a workout.

The core loop is:

1. Review readiness and today's prescription.
2. Start the workout on the phone.
3. Record each set and the rest between working sets.
4. Finish the workout with session RPE and optional notes.
5. Review the completed session and progress.

The app is not a cloud service and does not replace the server's training rules.

## 2. Before pairing

You need:

- the server running strength-coach web and reachable from the phone;
- an iOS 27.0 or newer iPhone;
- a build signed for your phone (the personal-team build expires after seven days);
- a one-use pairing code from the server.

The server may be reached over the trusted home LAN, or through a private HTTPS address such as
Tailscale Serve. Do not expose the unauthenticated web server to the public Internet.

### Pairing

On the server, run from the server checkout (the default database is `data/coach.db`):

    strength-coach ios pair --label "iPhone"

Use `--db` for another database, e.g. `strength-coach --db /path/to/coach.db ios pair`; if the
tool is not on `PATH`, call it as `.venv/bin/strength-coach`. It prints the code once, grouped
as 4+4 digits, with its expiry:

    pairing code: 1234 5678
    expires at:   2026-11-11T23:15:00+00:00 (300s)
    device label: iPhone (enter it in the app if it differs)

Enter the code in the app's pairing screen, choose a label and pair. The token is stored in the
iPhone Keychain and the server keeps only its SHA-256 digest. The code is single-use and expires
after five minutes; `--ttl 60-3600` changes the lifetime.

Manage credentials with `strength-coach ios devices` (device ids, last-seen times) and
`strength-coach ios revoke <device-id>`. Revoking a device also revokes the watches that paired
through it.

If pairing fails:

- check the code was copied exactly and has not expired;
- check the address from the phone, not only from the computer;
- use HTTPS for a Tailscale/MagicDNS address; plain HTTP is for the trusted LAN only.

## 3. Home and Away servers

Settings has:

- **Home Server** — usually the LAN address;
- **Away Server** — usually a private Tailscale/HTTPS address;
- **Prefer Home Server** — the manual preference.

With Prefer Home Server on, the app makes a short reachability check against Home and uses Away
when Home does not answer. Turn it off to force Away when configured. The choice is saved when
you tap **Save server settings**.

Both addresses should normally point at the same paired server/database. Changing to a different
server may require pairing again. A Tailscale HTTPS URL should use the MagicDNS hostname, not a
raw 100.x address.

## 4. Daily workout flow

1. Open **Today** and review readiness and the prescription.
2. When requesting a new workout, choose **Run on iPhone** or **Run on Apple Watch**. The default
   is iPhone. A watch-targeted plan appears on the watch and cannot be started on the phone.
3. When the plan is ready, open **Review workout** to see every exercise, target set, rep range,
   load, RIR, any velocity target, rest and any warnings. **Start workout** is on that screen, so the plan is always
   visible before it is consumed. The server issues the plan; the phone never invents plan content.
4. Open an exercise and tap **Start set** before the set. The first set starts the exercise;
   the exercise stays open until you end it, and starting a set in another exercise leaves the
   first one open, which is how a superset is recorded.
5. Enter load, reps and RIR. When the plan gives the lift a velocity target, it is shown beside
   RIR on the phone and the watch; optional mean and per-rep velocity are offered, and bodyweight
   work is not asked for them. The rest
   is anchored at your **first edit** of the sheet, so the time you spend entering numbers is rest,
   not part of the set; the set keeps the time you started it.
6. Each main lift lists its warm-up ramp, starting with the empty bar (the first rung is capped
   at 20 kg, or the first warm-up when that is lighter). Warm-up rows are optional: skipping them
   and logging the working sets is valid. To record one, tap **Start set** on its warm-up row: it
   fills that row's load and reps, and RIR 6 is what records the set as a warm-up.
   A working set starts the rest timer automatically; logged warm-ups (RIR 6) do not.
7. Repeat for the remaining sets and exercises. When an exercise is done, tap **End exercise**:
   it closes any running rest, records the exercise's completion and offers the optional 1–5 form
   rating. Leaving the screen does not end the exercise.
8. Finish with session RPE or **Not recorded**, optional duration/notes and productivity.
9. Review the **Session report** that opens after completion: prescription adherence, velocity,
   session feedback, quality flags and evidence. It is read-only. **Done** returns to Today.
10. The same report is available later from the session's **History** detail. An imported session
    with no workout record explains that no report exists.

### Set controls

- **Start set** records when you began the set.
- Saving records the completion time and actual set duration.
- The performed set remains the canonical load/reps/RIR/velocity record.
- Removing a set records the correction; it does not rewrite history.
- Unplanned exercises and repeated occurrences of the same exercise are supported.

### Rest timer

The timer uses the prescription's rest seconds when available.

- It displays prescribed rest and counts down above the tab bar, on Today and every other tab,
  so leaving the workout does not hide it.
- **Skip** ends the rest early.
- **+15 s** extends the timer.
- Starting the next set also ends the current rest.
- When rest finishes, the timer dismisses itself and the app records the actual interval.
- The interval survives a relaunch: a rest that ended while the app was closed is recorded at the
  time it actually ended, not when the app next opened.

### Lock Screen and Control Center

While a rest is running, the phone shows a Live Activity countdown on the Lock Screen and in the
Dynamic Island. The countdown is drawn by the system from the rest's end time, so it stays correct
with the app closed. Tapping it opens Strength, where **+15 s** and **Skip** live.

Settings → Control Center (or the Action button) can host the **Strength** control. It opens the
running workout; it does not record a set or change a rest on its own.

The timer is descriptive. It does not change the next prescription or declare the session
compliant.

### Rest alerts

The first rest timer asks for notification permission. If allowed, the app schedules a local
notification for the rest end:

- the notification plays the system sound and follows the phone's vibration/silent settings;
- it carries a **Done** action; tapping either the action or the notification opens the app and
  clears the alert (it does not yet deep-link directly into the active workout);
- extension reschedules the notification;
- skip/finish cancels it.

While the app is active, completion also uses an in-app haptic and sound. If notifications are
denied, the in-app timer still works. If the app is force-quit, the timer state is lost and no
rest-completion event is fabricated.

## 5. Offline use

The app keeps the active workout and pending operations on the phone before acknowledging them.

- Sets, form ratings, finish operations and execution events can be queued.
- The exercise catalogue is cached on the phone: the library and exercise pickers remain usable
  offline for browsing and logging an exercise outside the plan. Plan edits still require the
  server and are not queued.
- Queued work survives app termination and reloads on the next launch.
- Replay preserves the original occurrence time.
- The app shows pending, offline and conflict states rather than claiming server acceptance.
- A workout with pending work cannot silently switch to another server address.
- Finish flushes pending execution events first.
- Unresolved work remains visible; it is not silently discarded or attached to another workout.
- If the local recovery file cannot be read, Today shows **Offline recovery** with a retry action.
  Offline writes are paused and the file is preserved until you retry or explicitly discard it.
- If recovered work belongs to a different active workout, **Offline recovery conflict** asks you
  to keep the current workout and discard the recovered work, or use the recovered workout.
- A failed local capture write is shown as **Offline capture write failed**; it is not reported as
  a network error.
- If execution timing could not be recorded while recovery was unavailable, Today and the workout
  screen show **Execution timing** rather than silently dropping it.

Fresh readiness scoring, prescription generation and server authority are not available offline.
Offline records are performed-work capture, not a new prescription.

## 6. History and execution timeline

Completed sessions in **History** show:

- the session facts, sets and duration;
- a recorded execution section when execution events exist;
- active lifting, recorded rest, transition and total elapsed time;
- set durations;
- prescribed versus actual rest and deviation;
- a chronological event timeline;
- missing-timestamp indicators.

Older or imported sessions without execution events show that the timeline is unavailable. The
app does not invent starts, ends or rest periods. These are observations, not fatigue, readiness
or compliance scores.

The server's web UI **History → Details** shows the same read-only execution timeline for
completed workouts.

## 7. Progress and Exercise Library

- **Progress** shows the server's descriptive dashboard: sRPE coverage, performance points,
  weekly volume, attendance and back-symptom summary over the selected window.
- **Progress → Weekly review** shows the server's deterministic Monday–Sunday package: activity,
  adherence, sessions, main-lift progression, volume, readiness coverage, programme state and up to
  two gated observations, with coverage and limitations. It is read-only and has no model; an empty
  week says so instead of showing zeros.
- **Settings → Exercises** provides a searchable catalogue, exercise configuration, server e1RM
  and paginated working-set history.
- Catalogue/configuration is cached for the app session; entering an exercise fetches e1RM and
  history, and explicit refresh controls are available.

Exercise information is read-only. The training rules and prescription engine are unchanged.

## 8. HealthKit

HealthKit readiness is optional and off by default. When enabled, the app reads only:

- heart-rate variability (SDNN) — readiness uses a **recovery value per night**: the median of
  that day's readings taken before 10:00. A morning with no reading has no HRV for that day; a
  daytime reading is kept for the record but does not drive readiness;
- resting heart rate;
- bodyweight.

Manual readiness takes precedence over HealthKit, which takes precedence over imported
readiness. The app never writes to HealthKit and does not import sleep or workouts. The recovery
series is backfilled once from Health (up to five years) and then updated nightly; the import runs
on an app refresh and after enabling HealthKit.

**Workout heart rate is read only on Apple Watch**, for the live session display and the one
saved HealthKit workout. It is not used for readiness, fatigue, progression or prescriptions.

## 9. Settings and maintenance

- **Home/Away server** — addresses and preference.
- **Exercise Library** — catalogue and history.
- **Apple Watch** — pair, replace or revoke the watch credential.
- **HealthKit** — opt-in readiness import.
- **Daily reminder** — one nudge a day at a time you choose.
- **Today summary** — the two-part prose block at the top of Today.
- **Forget this device** — removes the local token; the server-side device record is managed
  separately with the server CLI.

### Today summary

The top of **Today** can carry a short block in two parts: **Where you stand**, a plain summary of
your readiness and the session in front of you, and **Nudge**, a line or two of encouragement. It uses
the same model you selected for Chat: Apple Intelligence on the iPhone, or DeepSeek.

With DeepSeek selected, loading the card sends your readiness and four-week training facts to DeepSeek.
Plan details travel only while **Include plan and prescription data** is on. The footer under the card
always names the model that wrote it, so you can tell at a glance where the words came from. If the
selected model is unavailable — Apple Intelligence off, or no DeepSeek key saved — the card says so and
offers nothing else; it never quietly switches to the other model. **Refresh** rewrites it; otherwise it
is generated once per day and session and reused. Turn the whole block off under
**Settings → Today summary**.

### Daily reminder

Turn on **Settings → Daily reminder** and choose a time. At that time the app posts one local
notification that names a concrete fact from your record — a planned session, its lead lift and load,
or a missing readiness entry — and asks you to train. The wording is written on the iPhone: by Apple
Intelligence when it is available, otherwise from the built-in text. Nothing is sent to a server.

The reminder is skipped on a day you have already trained. If you train on the watch only and never
open the phone, the phone cannot see the session, so the reminder may still arrive. Tapping the
notification opens Today; **Log readiness** opens the readiness form directly. If notifications are
off for the app, the Settings row says so instead of pretending the reminder is armed.

**Why the wording is sometimes plain.** The message is written by Apple Intelligence when it is
available. When it is not — Apple Intelligence off, the model still downloading, or a generation that
failed or ran long — the app sends built-in wording instead of guessing. Settings shows a
**Last reminder** line saying which happened and why, so a plain message is never a mystery.

**Mirroring to the watch.** The reminder is an iPhone notification, so the Apple Watch shows it only
under Apple's mirroring rules: the iPhone must be locked or asleep, and the watch unlocked and on your
wrist. If you are using the iPhone when it arrives, it stays on the iPhone. There is no per-app switch
in the app for this — it is Watch app → Notifications → Mirror my iPhone, plus the locked-phone rule.

### Apple Watch pairing

The watch uses the **Home Server** only. Set a valid Home Server before pairing; the watch never
follows the Away route.

1. Install and open Strength on the Apple Watch once, then keep both apps open.
2. On the iPhone, open **Settings → Apple Watch**.
3. Tap **Pair Apple Watch**. The status changes from *Waiting for Apple Watch* to *Paired* when
   the watch acknowledges the credential.
4. If the status stays waiting, bring the watch near the phone, open both apps and try again.

The watch receives its own server device token. The iPhone keeps that token only until the watch
acknowledges it; the watch stores it in its own Keychain. **Replace Apple Watch** rotates the
credential. **Revoke Apple Watch** revokes it on the server, clears the watch, and suppresses
automatic re-pairing until you tap Pair again.

Changing the Home Server and tapping **Save server settings** increments the watch configuration
version. When the watch has no active session, it updates its Home address without receiving a new
token.

The watch runs its own session: fetch the watch-targeted plan, **Start set**, log load/reps/RIR.
A warm-up is an ordinary set: tap **Use** on a warm-up row to fill its load and reps, then log it
with RIR 6. RIR 6 is what records it as warm-up work, so it stays out of working-set volume and
does not open a rest. When the plan supplies a velocity target it appears beside RIR and in the
RIR sheet. Mean velocity is available for external-load work even when the plan has no target; the
watch records the measurement and the server owns calibration. Time-based exercises
show seconds (“30s”), not repetitions. The rest starts when you tap **End set**, so the RIR and
velocity entry happens during the rest, not inside the set. Rest — **+15s** extends it, **−15s**
shortens it, and a local notification fires when it ends if you allowed notifications — rate form
at **End exercise**, and finish with editable sRPE and optional productivity. Total elapsed time
and heart rate show at the top of the exercise screen; heart rate follows the latest HealthKit
sample and clears after 10 seconds without a new one. Exactly one HealthKit workout is saved, and
the session sRPE is written as the workout's Apple effort score.

A swap re-solves the replacement from its own history and calibration: load, warm-up ramps and
VBT target when available. It never copies the old lift's load. If no load can be derived, the
replacement shows **Load not set** rather than **bodyweight**, remains startable, and accepts a
manual load. VBT is optional for external-load work and is measured, not calibrated, by the watch. Capture is local-first: without the
network the sets queue on the watch and sync when it reconnects.

Requested a workout for the wrong target? The ready card on Today offers **Request another
workout**, which supersedes the pending plan; a watch only drops the old plan at its next refresh.

While the watch owns the session the phone shows **Logged on Apple Watch** and does not accept sets,
form ratings or velocity. Use the phone to edit the plan; an edit reaches the watch at its next idle
point, never mid-set. **Take over logging** asks for confirmation, moves the session to the phone
and leaves the watch read-only; sets the watch already recorded stay in the session.

If the server address changes, save the settings and let the app recheck. If you change to a
different server/database, pair again.

## 10. Troubleshooting

**The app cannot reach the server**

- Open the server's web UI from the phone, not only from the computer.
- For Tailscale, use the MagicDNS HTTPS hostname; do not use raw HTTP or a raw 100.x HTTPS
  address.
- Check Tailscale/VPN is active on the phone.
- Use valid HTTPS for remote access; plain HTTP is for the trusted LAN.
- Confirm the server process is current and shows the expected iOS routes.

**A workout action is pending or offline**

Open Today's pending/offline section. Do not switch servers while work is unresolved. Reconnect
and retry; if the server has completed or abandoned the workout, follow the recovery action shown
rather than creating a replacement.

**Notifications do not appear**

Allow notifications in iOS Settings. Check Focus/Silent settings and the phone's notification
sound/vibration settings. The in-app timer works without notification permission.

**The exercise timeline is unavailable**

That workout has no recorded execution events. Historical sessions are not backfilled. A newly
completed workout needs both set start and completion events for set durations; a completion
timestamp alone is not enough.

**A duration looks wrong**

The app records when you tapped Start set and when you saved the set. Time spent with the app
backgrounded or with a timer suspended can affect the measured interval. Missing events remain
missing rather than being estimated.

## 11. Privacy and safety

- The server is local/private; the web UI has no authentication and must not be exposed publicly.
- The iOS token is stored in the Keychain and is sent only to the configured server.
- The app does not send training data to a cloud analytics or LLM service.
- Nothing here changes the training methodology. Stop a set or session if it becomes unsafe;
  the app is a recorder, not medical advice.

## 12. Known limitations

- No workout pause/resume UI; time away from the app is not recorded as a pause.
- Notification taps open the app but do not deep-link directly to the active workout.
- Offline set events use a local identity until replayed; the server set ID is attached when
  available online.
- Exercise completion is explicit on the phone (**End exercise**); on the watch it is the
  **End exercise** button or a switch to another exercise.
- No workout heart-rate observations.
- The session report is only available after the server has acknowledged completion. A queued
  offline finish shows no report until it syncs; open the session from History after that.
- Warm-up rows are a guide; only working sets count toward the plan's set completion. Tap
  **Use** on a row to fill the ordinary set controls, then record RIR 6 at End set.
- The notification/vibration path and all timing behaviour require physical-iPhone acceptance;
  simulator builds are not proof of those behaviours.

## Related documentation

- [Client README](README.md) — build, test and architecture details.
- Server USER-GUIDE.md — web/CLI workflow and training engine.
- Server docs/API.md — HTTP contracts.
- Server docs/DATA-MODEL.md — workout, set and execution-event schema.

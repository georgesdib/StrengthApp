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
   load, RIR, rest and any warnings. **Start workout** is on that screen, so the plan is always
   visible before it is consumed. The server issues the plan; the phone never invents plan content.
4. Open an exercise and tap **Start set** before the set.
5. Enter load, reps, RIR, and optional mean/per-rep velocity, then save.
6. Each main lift lists its warm-up ramp, starting with the empty bar (the first rung is capped
   at 20 kg, or the first warm-up when that is lighter). Warm-up rows are optional: skipping them
   and logging the working sets is valid. To record one, use **Start another set** with RIR 6.
   A working set starts the rest timer automatically; logged warm-ups (RIR 6) do not.
7. Repeat for the remaining sets and exercises.
8. Finish with session RPE or **Not recorded**, optional duration/notes and productivity.
9. Review the completed session in **History**.

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
- **Settings → Exercises** provides a searchable catalogue, exercise configuration, server e1RM
  and paginated working-set history.
- Catalogue/configuration is cached for the app session; entering an exercise fetches e1RM and
  history, and explicit refresh controls are available.

Exercise information is read-only. The training rules and prescription engine are unchanged.

## 8. HealthKit

HealthKit readiness is optional and off by default. When enabled, the app reads only:

- heart-rate variability (SDNN);
- resting heart rate;
- bodyweight.

Manual readiness takes precedence over HealthKit, which takes precedence over imported
readiness. The app never writes to HealthKit and does not import sleep or workouts.

**Workout heart rate is not implemented.** The app does not request or store workout HR samples,
and HR is not used for readiness, fatigue, progression or prescriptions.

## 9. Settings and maintenance

- **Home/Away server** — addresses and preference.
- **Exercise Library** — catalogue and history.
- **Apple Watch** — pair, replace or revoke the watch credential.
- **HealthKit** — opt-in readiness import.
- **Forget this device** — removes the local token; the server-side device record is managed
  separately with the server CLI.

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

The watch runs its own session: fetch the watch-targeted plan, **Start set**, log load/reps/RIR with
optional mean velocity, rest, rate form at **End exercise**, and finish with sRPE. Heart rate shows
during the session and exactly one HealthKit workout is saved. Capture is local-first: without the
network the sets queue on the watch and sync when it reconnects.

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
- Exercise completion is based on leaving the exercise screen, so its boundary can be
  approximate.
- No workout heart-rate observations.
- Warm-up rows are a guide; only working sets count toward the plan's set completion. Logging a
  warm-up uses **Start another set** with RIR 6.
- The notification/vibration path and all timing behaviour require physical-iPhone acceptance;
  simulator builds are not proof of those behaviours.

## Related documentation

- [Client README](README.md) — build, test and architecture details.
- Server USER-GUIDE.md — web/CLI workflow and training engine.
- Server docs/API.md — HTTP contracts.
- Server docs/DATA-MODEL.md — workout, set and execution-event schema.

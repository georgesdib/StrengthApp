# Phase 6.2b watch credential acceptance — owner-run

**Status: not yet performed.** This script is for the owner's physical iPhone + Apple Watch. A
simulator build is not proof of WatchConnectivity delivery, Keychain isolation or watch installation.

## Before you start

- [ ] Use a disposable server/database, not the live `data/coach.db`.
- [ ] The server is reachable from the iPhone on the home LAN and has `watch_enabled: true` in
      `config/ios.v1.yaml` (restart is not required; it is read per request).
- [ ] Build and install the current `StrengthApp` on the physical iPhone and `StrengthWatch` on the
      paired Apple Watch. Keep both apps installed.
- [ ] The iPhone is paired with the server (Today loads) and **Settings → Home Server** is the
      reachable LAN address. Do not use the Away address.
- [ ] Note the iPhone's device id in **Settings → This device**.

## Pair and handshake

- [ ] On the watch, open Strength. It says **Open Strength on your iPhone to pair.**
- [ ] On the iPhone, **Settings → Apple Watch** shows *Not paired* and enables **Pair Apple Watch**.
- [ ] Tap **Pair Apple Watch**. The status becomes *Waiting for Apple Watch*.
- [ ] Within a few seconds, the watch shows **Ready** with the Home host, and the iPhone shows
      **Paired** with a *Last acknowledged* time.
- [ ] Lock the watch, unlock it, and foreground both apps. The status remains Paired; it does not
      mint a second watch device.
- [ ] Force-quit and relaunch the iPhone app. Settings still shows Paired, without asking for a new
      pairing code.
- [ ] On the server, `strength-coach ios devices` shows exactly one active watch whose
      `parent_device_id` is the iPhone device id. It has a credential epoch and no plaintext token.

## Config-only refresh

- [ ] Change the Home Server to another address that reaches the same disposable server, then tap
      **Save server settings**.
- [ ] Foreground both apps. The watch updates its displayed host and remains Ready; it does not
      receive a new watch token and the server epoch does not change.
- [ ] Restore the original Home Server and save again.

## Revoke and deliberate suppression

- [ ] On the iPhone, **Settings → Apple Watch → Revoke Apple Watch**, confirm.
- [ ] The iPhone status becomes *Revoked*; the watch shows *Watch unpaired* (or clears Ready when it
      next receives the context).
- [ ] On the server, the watch row is revoked. Its old token is rejected with 401/403.
- [ ] Foreground both apps several times. The phone must **not** automatically mint a replacement
      watch; status stays Revoked.
- [ ] Tap **Pair Apple Watch** again. A new watch device with a higher credential epoch is created,
      the old one stays revoked, and the watch returns to Ready.

## Phone revocation cascade

- [ ] Revoke the iPhone device on the server with the CLI (or re-pair the iPhone).
- [ ] Confirm the iPhone's active child watch is also revoked in the same operation
      (`revoked_watch_ids` in the DELETE response / `strength-coach ios devices`).
- [ ] The old watch token cannot read any `/api/ios/v1/*` route.
- [ ] A revocation context naming a different watch device is ignored; it must not clear the
      current watch token.

## Failure and recovery

- [ ] Start Pair with the watch app closed. The status may stay *Waiting for Apple Watch*; opening
      the watch app or foregrounding both apps completes the handshake or reports missing
      credentials.
- [ ] Kill the iPhone app after minting but before the ack, then relaunch. It may show Waiting; the
      tokenless probe either gets a re-ack or the watch reports missing and the phone mints a new
      epoch.
- [ ] Leave the watch with stale metadata (a different device id or an older epoch) and no token,
      then pair the phone's current credential. The watch adopts the current device/epoch as
      **missing**, clears the stale token, and the phone mints once; it must not loop on an old
      acknowledgement.
- [ ] Leave the watch with a valid old token while the phone expects a newer device/epoch. The watch
      re-acks the old credential; the phone mints a fresh epoch (at most twice in one foreground),
      sends the token, and the new token replaces the old one.
- [ ] A tokenless probe must never create a new Ready state or grant API access; only a
      token-bearing higher epoch can replace a valid old token or a revoked credential.
- [ ] Turn off Wi-Fi on the watch (or move it out of range) and change the Home Server. The watch
      keeps its old Home URL and does not switch to Away; it updates when it can reach the phone and
      the new Home server.

## Secrets and cleanup

- [ ] The watch token never appears in the iPhone logs, UserDefaults, a file or a crash report.
- [ ] The watch token is in the watch Keychain only; non-secret metadata may be in UserDefaults.
- [ ] Forget the iPhone device and revoke the disposable watch; stop and delete the disposable
      server/database.

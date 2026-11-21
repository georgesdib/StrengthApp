# Watch phone gateway (WP8)

The watch normally talks to the Home Server directly. When that transport fails, an active,
reachable iPhone can relay the same request over WatchConnectivity. The relay is additive: it is
never the only copy and it does not replace the direct path.

## Protocol

Watch → phone:

```json
{
  "kind": "relay",
  "request": {
    "requestId": "uuid",
    "operation": "bootstrap|start|addSet|executionEvents|finish|abandon|rateForm",
    "baseURL": "http://home.local:8000",
    "token": "watch token",
    "deviceID": "watch device id",
    "workoutId": "optional",
    "issuedPlanId": "optional",
    "idempotencyKey": "original operation id",
    "payload": "base64 JSON request body"
  }
}
```

Phone → watch reply: `{"kind":"relay_reply","response":"<encoded WatchRelayResponse>"}`.

The phone executes the existing API with the watch token and the original idempotency key. It
does not journal, retry or reinterpret the operation. The watch treats an operation as pending
until the phone returns an `ok: true` response; a transport failure, timeout or non-ok response
leaves it queued.

## Operations

| Operation | Phone call |
|---|---|
| bootstrap | `GET /api/ios/v1/bootstrap` |
| start | `POST /api/ios/v1/workouts` |
| addSet | `POST /api/ios/v1/workouts/<id>/sets` |
| executionEvents | `POST /api/ios/v1/workouts/<id>/execution-events` |
| finish | `POST /api/ios/v1/workouts/<id>/complete` |
| abandon | `POST /api/ios/v1/workouts/<id>/abandon` |
| rateForm | `POST /api/ios/v1/workouts/<id>/form` |

## Direct-first rule

`IOSAPIClient` attempts the HTTP request first. Only an `APIError.transport` failure falls back
to the relay; a 4xx/5xx response is surfaced unchanged and never retried through the phone. This
keeps the phone a transport, not a second authority.

## Security and identity

- The watch token travels only over the encrypted WatchConnectivity session; the phone uses it
  transiently and does not persist it.
- The server sees the watch as the execution device; `(device_id, operation_id)` receipts
  deduplicate a relayed operation against a later direct retry.
- The watch never authors substitutions or additions; those remain phone-authored execution
  events.

## Availability

The plan push carries the frozen plan and the current execution view. If the phone is
unreachable, the watch shows the waiting/timeout copy and keeps its queued work; it does not
start a session offline. Offline-on-both-devices remains a documented limitation.

## Code map

- `StrengthCore/Execution/WatchRelayModels.swift` — envelope and coding.
- `StrengthCore/Networking/IOSAPIClient.swift` — direct-first fallback.
- `StrengthCore/Execution/WatchExecutionEngine.swift` — installs the relay transport.
- `StrengthApp/Core/WatchPairing.swift` — phone gateway handler.
- `StrengthWatch/WatchSessionController.swift` — WCSession transport, request/reply.
- `StrengthWatch/StrengthWatchApp.swift` — injects the watch session as the relay.

## Acceptance

The physical run on 2026-11-21 started a watch-owned workout with the watch unable to reach
the server, relayed the set, form and finish through the phone, and the server recorded one set
with no duplicate. The owner accepted WP8 with no follow-ups.

## Tests

- `WatchRelayTests`: transport fallback preserves token/device/idempotency; direct success does
  not touch the relay.
- `WatchRelayGatewayTests`: the phone executes a relayed bootstrap with the watch token and
  returns a decodable response.
- `scripts/ci.sh` builds both apps and runs the unit tests.


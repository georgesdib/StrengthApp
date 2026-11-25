# Readiness registry on the iPhone

The server's readiness registry is the source of truth for which daily readiness inputs exist,
what they are called, their scales, units, direction and the minimum/required-one-of rule. The
iPhone renders that contract and submits values; it does not compute or reinterpret a readiness
score.

Canonical plan:
[READINESS-METRIC-REGISTRY.md](https://github.com/georgesdib/strength-app/blob/readiness-registry/docs/plans/READINESS-METRIC-REGISTRY.md)
(portfolio repository). Server API authority:
[API.md](https://github.com/georgesdib/strength-training-app/blob/readiness-registry/docs/API.md).

## Contract used

- `GET /api/ios/v1/readiness/schema` (bearer) returns `registry_id`, `effective_from`,
  `schema_version`, `min_core_fields`, `require_any_of`, `wearable_weight` and `metrics[]`
  with `key`, `label`, `role` (`core` or `device`), `enabled`, `weight`, `baseline_days`,
  `counts_as_core`, `order`, `min_readings`, `slope`, `scale_min`, `scale_max`,
  `higher_is_better` and `unit`.
- `POST /api/ios/v1/readiness` (bearer + `Idempotency-Key`) keeps `{values, note?}`. The values
  map may contain enabled registry metrics plus the two non-registry inputs `bodyweight_kg` and
  `wearable_score`; unknown or disabled fields are rejected with field errors.
- `GET /api/ios/v1/today` already carries `readiness.registry_version`; the client decodes it but
  still renders the form from the schema endpoint.

## Form behaviour

- Enabled metrics are shown in `order`; disabled metrics are omitted.
- Core metrics use `scale_min`..`scale_max` as whole numbers. Device metrics are numeric and
  show the server's unit and direction.
- Labels, units, direction and the required-one-of marker come from the schema. The marker is a
  red **\*** on `require_any_of` fields, with a footer naming the rule.
- Bodyweight and the wearable score are a separate **Other inputs** section; they are not
  registry metrics.
- The client checks whole-number/positive ranges, `min_core_fields` and `require_any_of` before
  submitting. This is a convenience; the server remains authoritative. A server field error is
  placed on the matching input, and the server message stays visible.
- HealthKit HRV/RHR/bodyweight remain read-only displays on the same form; a manual value wins.

## Offline behaviour

The last successfully fetched schema is cached in Application Support, keyed by server URL. If
the schema request fails, the form uses that cached schema; if there is no cache, it uses the
fixed seeded fields in `ReadinessSchema.fallback`. Readiness entry is never blocked by schema
availability.

A metric added to the server registry after the cache was written is not available offline. The
form says so at the top and does not invent a value for it; the metric appears after the next
successful schema fetch. An offline readiness write follows the existing Phase 2 mutation
journal, so the server remains the authority for the score once it syncs.

## Acceptance

The simulator live flow passed against a disposable seeded-registry server on 2026-11-25; the
physical-device record is [outstanding](acceptance/device/15-readiness-registry.md) because the
owner declined installation for that run. Unit coverage is in `ReadinessSchemaTests`,
`ReadinessSchemaCacheTests`, `ReadinessFormFieldTests`, `IOSAPIClientTests` and
`AppModelTests`.

## What the Swift code must not do

No Swift code calculates readiness, weights, components, category factors, baselines or a score.
`ReadinessSchema` only filters/orders the server's list, formats its labels and validates the
form before submission.

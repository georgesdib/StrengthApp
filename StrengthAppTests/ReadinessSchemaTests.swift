import XCTest

@testable import StrengthApp
import StrengthCore

final class ReadinessSchemaTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func schema() throws -> ReadinessSchema {
        try decoder().decode(ReadinessSchema.self, from: Data(Self.schemaJSON.utf8))
    }

    // MARK: Decoding

    func testDecodesTheRegistrySchemaContract() throws {
        let schema = try schema()
        XCTAssertEqual(schema.registryId, 7)
        XCTAssertEqual(schema.effectiveFrom, "2026-11-20")
        XCTAssertEqual(schema.schemaVersion, 1)
        XCTAssertEqual(schema.minCoreFields, 3)
        XCTAssertEqual(schema.requireAnyOf, ["sleep", "energy"])
        XCTAssertEqual(schema.wearableWeight, 0.1, accuracy: 0.0001)
        XCTAssertEqual(schema.metrics.count, 8)

        let hrv = try XCTUnwrap(schema.metric("hrv_ms"))
        XCTAssertEqual(hrv.label, "HRV (SDNN)")
        XCTAssertEqual(hrv.role, "device")
        XCTAssertTrue(hrv.enabled)
        XCTAssertEqual(hrv.weight, 0.5)
        XCTAssertEqual(hrv.baselineDays, 28)
        XCTAssertFalse(hrv.countsAsCore)
        XCTAssertEqual(hrv.order, 6)
        XCTAssertEqual(hrv.minReadings, 7)
        XCTAssertEqual(hrv.slope, 0.5)
        XCTAssertEqual(hrv.scaleMin, 0)
        XCTAssertNil(hrv.scaleMax)
        XCTAssertTrue(hrv.higherIsBetter)
        XCTAssertEqual(hrv.unit, "ms")
        XCTAssertEqual(hrv.inputHint, "ms · higher is better")

        let rhr = try XCTUnwrap(schema.metric("rhr_bpm"))
        XCTAssertEqual(rhr.label, "Resting heart rate")
        XCTAssertFalse(rhr.higherIsBetter)
        XCTAssertEqual(rhr.unit, "bpm")
        XCTAssertEqual(rhr.inputHint, "bpm · lower is better")

        let sleep = try XCTUnwrap(schema.metric("sleep"))
        XCTAssertEqual(sleep.scaleMin, 1)
        XCTAssertEqual(sleep.scaleMax, 5)
        XCTAssertEqual(sleep.inputHint, "1–5 · higher is better")
        XCTAssertNil(sleep.unit)
    }

    func testEnabledMetricsAreFilteredAndSortedByRegistryOrder() throws {
        let schema = try schema()
        XCTAssertEqual(
            schema.enabledMetrics.map(\.key),
            ["sleep", "energy", "mood", "stress", "soreness", "hrv_ms", "rhr_bpm"]
        )
        XCTAssertEqual(
            schema.enabledCoreMetrics.map(\.key),
            ["sleep", "energy", "mood", "stress", "soreness"]
        )
        XCTAssertEqual(schema.enabledDeviceMetrics.map(\.key), ["hrv_ms", "rhr_bpm"])
        XCTAssertFalse(schema.enabledMetrics.contains { $0.key == "focus" })
        XCTAssertEqual(schema.metric("focus")?.enabled, false)
        XCTAssertEqual(schema.requiredMetricLabels, ["Sleep", "Energy"])
    }

    // MARK: Validation

    func testMinimumAndRequiredValidationAcceptsACompleteEntry() throws {
        let schema = try schema()
        let result = schema.validate(values: ["sleep": 4, "energy": 3, "mood": 4])
        XCTAssertTrue(result.isValid, result.summary ?? "")
    }

    func testRequiredOneOfIsEnforcedClientSide() throws {
        let schema = try schema()
        let result = schema.validate(values: ["mood": 4, "stress": 4, "soreness": 4])
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.fieldErrors, [:])
        XCTAssertEqual(result.summary, "Enter at least one of Sleep or Energy.")
    }

    func testMinimumCoreFieldsAreEnforcedClientSide() throws {
        let schema = try schema()
        let result = schema.validate(values: ["sleep": 4, "energy": 4])
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(
            result.summary,
            "Enter at least 3 core fields for a score; 2 entered."
        )
    }

    func testCoreValuesMustBeWholeNumbersInsideTheServerScale() throws {
        let schema = try schema()
        let fractional = schema.validate(values: ["sleep": 4.5, "energy": 4, "mood": 4])
        XCTAssertEqual(
            fractional.fieldErrors["sleep"],
            "Enter a whole number from 1 to 5."
        )
        let outOfRange = schema.validate(values: ["sleep": 6, "energy": 4, "mood": 4])
        XCTAssertEqual(
            outOfRange.fieldErrors["sleep"],
            "Enter a whole number from 1 to 5."
        )
    }

    func testDeviceAndExtraInputsUseTheServerRanges() throws {
        let schema = try schema()
        let result = schema.validate(values: [
            "sleep": 4, "energy": 4, "mood": 4,
            "hrv_ms": 0, "bodyweight_kg": 0, "wearable_score": 101,
        ])
        XCTAssertEqual(result.fieldErrors["hrv_ms"], "Enter a number greater than 0.")
        XCTAssertEqual(result.fieldErrors["bodyweight_kg"], "Enter a number greater than 0.")
        XCTAssertEqual(result.fieldErrors["wearable_score"], "Enter a number from 0 to 100.")
        XCTAssertFalse(result.isValid)
    }

    func testUnknownFieldIsReportedAndEmptyEntryIsRejected() throws {
        let schema = try schema()
        let unknown = schema.validate(values: [
            "sleep": 4, "energy": 4, "mood": 4, "focus": 3,
        ])
        XCTAssertEqual(
            unknown.fieldErrors["focus"],
            "This metric is disabled in the current registry."
        )
        let empty = schema.validate(values: [:])
        XCTAssertEqual(empty.summary, "Enter at least one readiness field.")
    }

    // MARK: Submission

    func testSubmissionBuildsTheValuesMapAndDropsDisabledMetrics() throws {
        let schema = try schema()
        let result = schema.makeRequest(
            text: [
                "sleep": "4", "energy": "4", "mood": "4",
                "hrv_ms": "62.5", "bodyweight_kg": "80.4",
                "wearable_score": "75", "focus": "3",
            ],
            note: "  felt good  "
        )
        let request = try XCTUnwrap(try? result.get())
        XCTAssertEqual(
            request.values,
            [
                "sleep": 4, "energy": 4, "mood": 4,
                "hrv_ms": 62.5, "bodyweight_kg": 80.4, "wearable_score": 75,
            ]
        )
        XCTAssertNil(request.values["focus"])
        XCTAssertEqual(request.note, "felt good")
    }

    func testSubmissionAcceptsACommaDecimalAndEmptyNote() throws {
        let schema = try schema()
        let result = schema.makeRequest(
            text: ["sleep": "4", "energy": "4", "mood": "4", "bodyweight_kg": "80,4"],
            note: "   "
        )
        let request = try XCTUnwrap(try? result.get())
        XCTAssertEqual(request.values["bodyweight_kg"], 80.4)
        XCTAssertNil(request.note)
    }

    func testSubmissionSurfacesMissingRequiredFields() throws {
        let schema = try schema()
        let result = schema.makeRequest(text: ["mood": "4"], note: "")
        guard case .failure(.invalid(let fields, let summary)) = result else {
            return XCTFail("expected validation failure")
        }
        XCTAssertEqual(fields, [:])
        XCTAssertEqual(
            summary,
            "Enter at least 3 core fields for a score; 1 entered. "
                + "Enter at least one of Sleep or Energy."
        )
    }

    func testSubmissionSurfacesInvalidNumberOnTheMatchingField() throws {
        let schema = try schema()
        let result = schema.makeRequest(text: ["sleep": "four"], note: "")
        guard case .failure(.invalid(let fields, let summary)) = result else {
            return XCTFail("expected validation failure")
        }
        XCTAssertEqual(fields["sleep"], "Enter a number.")
        XCTAssertEqual(summary, "Enter at least one readiness field.")
    }

    func testSubmissionValuesKeepsOnlyEnabledMetricsAndTheTwoExtras() throws {
        let schema = try schema()
        XCTAssertEqual(
            schema.submissionValues([
                "sleep": 4, "focus": 3, "bodyweight_kg": 80, "wearable_score": 70,
            ]),
            ["sleep": 4, "bodyweight_kg": 80, "wearable_score": 70]
        )
    }

    // MARK: Offline fallback

    func testFallbackMirrorsTheSeededRegistryAndAllowsOfflineEntry() throws {
        let fallback = ReadinessSchema.fallback
        XCTAssertNil(fallback.registryId)
        XCTAssertNil(fallback.effectiveFrom)
        XCTAssertEqual(fallback.minCoreFields, 3)
        XCTAssertEqual(fallback.requireAnyOf, ["sleep", "energy"])
        XCTAssertEqual(
            fallback.enabledMetrics.map(\.key),
            ["sleep", "energy", "mood", "stress", "soreness", "hrv_ms", "rhr_bpm"]
        )
        XCTAssertEqual(fallback.metric("hrv_ms")?.label, "HRV (SDNN)")
        XCTAssertEqual(fallback.metric("hrv_ms")?.unit, "ms")
        XCTAssertEqual(fallback.metric("rhr_bpm")?.label, "Resting heart rate")
        XCTAssertEqual(fallback.metric("rhr_bpm")?.unit, "bpm")
        XCTAssertFalse(fallback.metric("rhr_bpm")?.higherIsBetter ?? true)

        let result = fallback.makeRequest(
            text: ["sleep": "4", "energy": "4", "mood": "4"],
            note: "offline"
        )
        let request = try XCTUnwrap(try? result.get())
        XCTAssertEqual(request.values, ["sleep": 4, "energy": 4, "mood": 4])
        XCTAssertEqual(request.note, "offline")
    }

    private static let schemaJSON = #"""
    {
      "registry_id": 7,
      "effective_from": "2026-11-20",
      "schema_version": 1,
      "min_core_fields": 3,
      "require_any_of": ["sleep", "energy"],
      "wearable_weight": 0.1,
      "metrics": [
        {"key": "energy", "label": "Energy", "role": "core", "enabled": true,
         "weight": 1.0, "baseline_days": 0, "counts_as_core": true, "order": 2,
         "min_readings": null, "slope": null, "scale_min": 1, "scale_max": 5,
         "higher_is_better": true, "unit": null},
        {"key": "sleep", "label": "Sleep", "role": "core", "enabled": true,
         "weight": 1.0, "baseline_days": 0, "counts_as_core": true, "order": 1,
         "min_readings": null, "slope": null, "scale_min": 1, "scale_max": 5,
         "higher_is_better": true, "unit": null},
        {"key": "mood", "label": "Mood", "role": "core", "enabled": true,
         "weight": 1.0, "baseline_days": 0, "counts_as_core": true, "order": 3,
         "min_readings": null, "slope": null, "scale_min": 1, "scale_max": 5,
         "higher_is_better": true, "unit": null},
        {"key": "stress", "label": "Stress", "role": "core", "enabled": true,
         "weight": 1.0, "baseline_days": 0, "counts_as_core": true, "order": 4,
         "min_readings": null, "slope": null, "scale_min": 1, "scale_max": 5,
         "higher_is_better": true, "unit": null},
        {"key": "soreness", "label": "Soreness", "role": "core", "enabled": true,
         "weight": 1.0, "baseline_days": 0, "counts_as_core": true, "order": 5,
         "min_readings": null, "slope": null, "scale_min": 1, "scale_max": 5,
         "higher_is_better": true, "unit": null},
        {"key": "hrv_ms", "label": "HRV (SDNN)", "role": "device", "enabled": true,
         "weight": 0.5, "baseline_days": 28, "counts_as_core": false, "order": 6,
         "min_readings": 7, "slope": 0.5, "scale_min": 0, "scale_max": null,
         "higher_is_better": true, "unit": "ms"},
        {"key": "rhr_bpm", "label": "Resting heart rate", "role": "device", "enabled": true,
         "weight": 0.5, "baseline_days": 28, "counts_as_core": false, "order": 7,
         "min_readings": 7, "slope": 0.5, "scale_min": 0, "scale_max": null,
         "higher_is_better": false, "unit": "bpm"},
        {"key": "focus", "label": "Focus", "role": "core", "enabled": false,
         "weight": 1.0, "baseline_days": 0, "counts_as_core": true, "order": 8,
         "min_readings": null, "slope": null, "scale_min": 1, "scale_max": 5,
         "higher_is_better": true, "unit": null}
      ]
    }
    """#
}

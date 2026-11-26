import XCTest
@testable import StrengthCore

final class LoadCataloguePrescriptionTests: XCTestCase {
    private func catalogue(_ body: String) throws -> LoadCatalogue {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LoadCatalogue.self, from: Data(body.utf8))
    }

    func testDoseOverrideCapsSetsAndWinsOverTheOrdinaryBase() throws {
        let value = try catalogue("""
        {"exercises":{"competition_squat":{"load_source":"e1rm","base_load_kg":100,
         "increment_kg":2.5,"dose_load_kg":60,"dose_sets_cap":2,
         "vbt_target":{"target_mps":0.42,"rep_count":5}}}}
        """)
        let result = value.prescription(
            exerciseId: "competition_squat", essential: true, reps: 5, rir: 2,
            sets: 4, groups: [SetGroup(sets: 3, repsLow: 5, rirTarget: 2)]
        )
        XCTAssertEqual(result.loadKg, 60)
        XCTAssertEqual(result.sets, 2)
        XCTAssertEqual(result.reason, "flare_dose")
        XCTAssertEqual(result.groups, [])
        XCTAssertEqual(result.vbtTarget?.targetMps, 0.42)
        XCTAssertEqual(result.topSet?.reasonCode, "substituted")
    }

    func testOrdinaryBaseAndSlotShapeMatchTheServerFormula() throws {
        let value = try catalogue("""
        {"exercises":{"competition_squat":{"load_source":"e1rm","base_load_kg":120,
         "increment_kg":2.5}}}
        """)
        let result = value.prescription(
            exerciseId: "competition_squat", essential: true, reps: 5, rir: 2, sets: 3,
            groups: [
                SetGroup(sets: 1, repsLow: 5, rirTarget: 1),
                SetGroup(sets: 2, repsLow: 8, rirTarget: 2),
            ]
        )
        XCTAssertEqual(result.loadKg, 95)
        XCTAssertEqual(result.reason, "catalogue_e1rm")
        XCTAssertEqual(result.groups.map(\.loadKg), [100, 90])
    }

    func testBodyweightAndPowerKeepTheirReasons() throws {
        let value = try catalogue("""
        {"exercises":{"pull_up":{"bodyweight":true,"increment_kg":2.5},
         "jump_squat":{"power":true,"base_load_kg":80,"increment_kg":5}}}
        """)
        let bodyweight = value.prescription(
            exerciseId: "pull_up", essential: false, reps: 8, rir: 1, sets: 2, groups: []
        )
        XCTAssertEqual(bodyweight.loadKg, 0)
        XCTAssertEqual(bodyweight.reason, "bodyweight")
        let power = value.prescription(
            exerciseId: "jump_squat", essential: false, reps: 5, rir: 0, sets: 3, groups: []
        )
        XCTAssertNil(power.loadKg)
        XCTAssertEqual(power.reason, "power_work")
    }
}

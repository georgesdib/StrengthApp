import Foundation

/// Compact, capability-specific projections for the plan tools. The generic envelope projection
/// is too large for a multi-item prescription or a 12-week adherence payload.
public enum PlanProjection {
    public static func text(_ envelope: IntelligenceEnvelope) -> String {
        switch envelope.capability {
        case "get_prescription": return prescription(envelope)
        case "get_adherence_analysis": return adherence(envelope)
        case "get_programme_block_summary": return programme(envelope)
        default: return NarrativeContext.projectionText(envelope)
        }
    }

    private static func prescription(_ envelope: IntelligenceEnvelope) -> String {
        let head = object(value(envelope, "prescription"))
        var lines = [
            "prescription: date=\(string(head, "for_date")) session=\(string(head, "session_type")) "
                + "fallback=\(string(head, "fallback_level"))",
        ]
        for item in array(value(envelope, "items")) {
            let row = object(item)
            let low = integer(row, "reps_low")
            let high = integer(row, "reps_high")
            let reps = low == high ? "\(low)" : "\(low)-\(high)"
            var line = "- \(string(row, "exercise_id")): \(integer(row, "sets"))x\(reps)"
            if let load = number(row, "load_kg") {
                line += " @ \(format(load)) kg"
            }
            if let basis = optionalString(row, "load_basis"), !basis.isEmpty {
                line += " (\(basis))"
            }
            if let rir = optionalInt(row, "rir_target") { line += ", RIR \(rir)" }
            if let rest = optionalInt(row, "rest_s"), rest > 0 { line += ", rest \(rest)s" }
            if row["essential"].map({ $0 == .bool(true) }) == true { line += ", essential" }
            lines.append(line)
        }
        if let modifiers = optionalArray(value(envelope, "modifiers")), !modifiers.isEmpty {
            lines.append("modifiers: \(modifiers.count) recorded")
        }
        return lines.joined(separator: "\n")
    }

    private static func adherence(_ envelope: IntelligenceEnvelope) -> String {
        let totals = object(value(envelope, "totals"))
        let completion = object(totals["set_completion"])
        let reps = object(totals["reps"])
        let load = object(totals["load"])
        let rir = object(totals["rir"])
        var lines = [
            "adherence totals: workouts=\(integer(totals, "workouts")) "
                + "prescribed_sets=\(integer(totals, "prescribed_sets")) "
                + "performed_sets=\(integer(totals, "performed_sets")) "
                + "matched_sets=\(integer(totals, "matched_sets")) "
                + "missing_sets=\(integer(totals, "missing_sets")) "
                + "set_completion=\(percent(completion["ratio"])) "
                + "reps_attainment=\(percent(object(reps["attainment"])["ratio"])) "
                + "load_attainment=\(percent(object(load["attainment"])["ratio"])) "
                + "rir_attainment=\(percent(object(rir["attainment"])["ratio"])) "
                + "small_sample=\(boolean(totals, "small_sample"))",
        ]
        let coverage = object(value(envelope, "coverage"))
        lines.append(
            "coverage: workouts_in_range=\(integer(coverage, "workouts_in_range")) "
                + "analysed=\(integer(coverage, "workouts_analysed")) "
                + "unavailable=\(integer(coverage, "workouts_unavailable"))"
        )
        for period in array(value(envelope, "periods")).suffix(12) {
            let row = object(period)
            lines.append(
                "- \(string(row, "key")): workouts=\(integer(row, "workouts")) "
                    + "prescribed=\(integer(row, "prescribed_sets")) "
                    + "performed=\(integer(row, "performed_sets")) "
                    + "set_completion=\(percent(object(row["set_completion"])["ratio"]))"
            )
        }
        for exercise in array(value(envelope, "exercises")).prefix(8) {
            let row = object(exercise)
            let set = object(row["set_completion"])
            let loadRow = object(row["load"])
            lines.append(
                "- \(string(row, "exercise_name")): prescribed=\(integer(row, "prescribed_sets")) "
                    + "performed=\(integer(row, "performed_sets")) "
                    + "matched=\(integer(row, "matched_sets")) "
                    + "set_completion=\(percent(set["ratio"])) "
                    + "load_attainment=\(percent(object(loadRow["attainment"])["ratio"]))"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func programme(_ envelope: IntelligenceEnvelope) -> String {
        let window = object(value(envelope, "window"))
        let settings = object(value(envelope, "settings"))
        let deload = object(value(envelope, "deload"))
        let attendance = object(value(envelope, "attendance"))
        var lines = [
            "programme: as_of=\(string(window, "as_of")) window=\(string(window, "start"))..\(string(window, "end")) "
                + "weeks=\(integer(window, "weeks"))",
            "settings: profile=\(integer(settings, "profile_id")) effective=\(string(settings, "effective_from"))",
            "deload: active=\(boolean(deload, "active")) reason=\(string(deload, "reason"))",
            "attendance: completed=\(integer(attendance, "completed")) target=\(integer(attendance, "target")) "
                + "pct=\(format(number(attendance, "pct") ?? 0))%",
        ]
        if let breaks = optionalArray(value(envelope, "breaks")), !breaks.isEmpty {
            lines.append("breaks: \(breaks.count) recorded")
        }
        return lines.joined(separator: "\n")
    }

    private static func value(_ envelope: IntelligenceEnvelope, _ key: String) -> JSONValue? {
        envelope.facts[key]?.value
    }

    private static func object(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let object) = value { return object }
        return [:]
    }

    private static func array(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let array) = value { return array }
        return []
    }

    private static func optionalArray(_ value: JSONValue?) -> [JSONValue]? {
        if case .array(let array) = value { return array }
        return nil
    }

    private static func string(_ object: [String: JSONValue], _ key: String) -> String {
        if case .string(let text) = object[key] { return text }
        return "unknown"
    }

    private static func number(_ object: [String: JSONValue], _ key: String) -> Double? {
        if case .number(let number) = object[key] { return number }
        return nil
    }

    private static func integer(_ object: [String: JSONValue], _ key: String) -> Int {
        Int(number(object, key) ?? 0)
    }

    private static func optionalInt(_ object: [String: JSONValue], _ key: String) -> Int? {
        number(object, key).map(Int.init)
    }

    private static func optionalString(_ object: [String: JSONValue], _ key: String) -> String? {
        if case .string(let text) = object[key] { return text }
        return nil
    }

    private static func boolean(_ object: [String: JSONValue], _ key: String) -> Bool {
        if case .bool(let flag) = object[key] { return flag }
        return false
    }

    private static func percent(_ value: JSONValue?) -> String {
        if case .number(let number)? = value { return String(format: "%.1f%%", number * 100) }
        return "n/a"
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

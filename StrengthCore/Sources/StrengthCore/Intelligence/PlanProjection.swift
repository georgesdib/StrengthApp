import Foundation

public struct PrescriptionCard: Identifiable, Equatable, Sendable {
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let exerciseID: String
        public let sets: Int
        public let repsLow: Int
        public let repsHigh: Int
        public let loadKg: Double?
        public let loadBasis: String?
        public let rir: Int?
        public let restS: Int?

        public init(
            id: String, exerciseID: String, sets: Int, repsLow: Int, repsHigh: Int,
            loadKg: Double?, loadBasis: String?, rir: Int?, restS: Int?
        ) {
            self.id = id
            self.exerciseID = exerciseID
            self.sets = sets
            self.repsLow = repsLow
            self.repsHigh = repsHigh
            self.loadKg = loadKg
            self.loadBasis = loadBasis
            self.rir = rir
            self.restS = restS
        }
    }

    public let id = UUID()
    public let forDate: String
    public let sessionType: String
    public let items: [Item]

    public init(forDate: String, sessionType: String, items: [Item]) {
        self.forDate = forDate
        self.sessionType = sessionType
        self.items = items
    }
}

public enum PlanProjection {
    public static func text(_ envelope: IntelligenceEnvelope) -> String {
        switch envelope.capability {
        case "get_prescription": return prescription(envelope)
        case "get_adherence_analysis": return adherence(envelope)
        case "get_programme_block_summary": return programme(envelope)
        default: return NarrativeContext.projectionText(envelope)
        }
    }

    public static func prescriptionCard(_ envelope: IntelligenceEnvelope) -> PrescriptionCard? {
        guard envelope.capability == "get_prescription", envelope.status == "ok" else { return nil }
        let head = object(value(envelope, "prescription"))
        let items: [PrescriptionCard.Item] = array(value(envelope, "items")).enumerated().compactMap {
            index, item in
            let row = object(item)
            let exercise = optionalString(row, "exercise_id") ?? ""
            guard !exercise.isEmpty else { return nil }
            return PrescriptionCard.Item(
                id: "\(index)-\(exercise)",
                exerciseID: exercise,
                sets: optionalInt(row, "sets") ?? 0,
                repsLow: optionalInt(row, "reps_low") ?? 0,
                repsHigh: optionalInt(row, "reps_high") ?? 0,
                loadKg: number(row, "load_kg"),
                loadBasis: optionalString(row, "load_basis"),
                rir: optionalInt(row, "rir_target"),
                restS: optionalInt(row, "rest_s")
            )
        }
        guard !items.isEmpty else { return nil }
        return PrescriptionCard(
            forDate: optionalString(head, "for_date") ?? "unknown",
            sessionType: optionalString(head, "session_type") ?? "unknown",
            items: items
        )
    }

    private static func prescription(_ envelope: IntelligenceEnvelope) -> String {
        let head = object(value(envelope, "prescription"))
        var lines = ["prescription: status=\(envelope.status)"]
        if envelope.status == "ok" {
            lines[0] += " date=\(optionalString(head, "for_date") ?? "n/a")"
                + " session=\(optionalString(head, "session_type") ?? "n/a")"
                + " fallback=\(optionalString(head, "fallback_level") ?? "n/a")"
            for item in array(value(envelope, "items")) {
                let row = object(item)
                let low = optionalInt(row, "reps_low")
                let high = optionalInt(row, "reps_high")
                let reps: String
                if let low, let high {
                    reps = low == high ? "\(low)" : "\(low)-\(high)"
                } else {
                    reps = "n/a"
                }
                var line = "- \(optionalString(row, "exercise_id") ?? "unknown")"
                    + ": \(optionalInt(row, "sets").map(String.init) ?? "n/a")x\(reps)"
                if let load = number(row, "load_kg") {
                    line += " @ \(format(load)) kg"
                } else {
                    line += " @ n/a"
                }
                if let basis = optionalString(row, "load_basis"), !basis.isEmpty {
                    line += " (\(basis))"
                }
                line += ", RIR \(optionalInt(row, "rir_target").map(String.init) ?? "n/a")"
                if let rest = optionalInt(row, "rest_s"), rest > 0 { line += ", rest \(rest)s" }
                lines.append(line)
            }
            let coverage = object(value(envelope, "coverage"))
            let total = optionalInt(coverage, "items")
            let returned = optionalInt(coverage, "items_returned")
            if optionalInt(coverage, "truncated") ?? 0 != 0 || (total ?? 0) > (returned ?? 0) {
                lines.append(
                    "incomplete: showing \(returned ?? 0) of \(total ?? 0) items"
                )
            }
        }
        lines.append(contentsOf: extras(envelope))
        return lines.joined(separator: "\n")
    }

    private static func adherence(_ envelope: IntelligenceEnvelope) -> String {
        var lines = ["adherence: status=\(envelope.status)"]
        if envelope.status == "ok" {
            let totals = object(value(envelope, "totals"))
            let completion = object(totals["set_completion"])
            let reps = object(totals["reps"])
            let load = object(totals["load"])
            let rir = object(totals["rir"])
            lines.append(
                "totals: workouts=\(intText(totals, "workouts")) "
                    + "prescribed_sets=\(intText(totals, "prescribed_sets")) "
                    + "performed_sets=\(intText(totals, "performed_sets")) "
                    + "matched_sets=\(intText(totals, "matched_sets")) "
                    + "missing_sets=\(intText(totals, "missing_sets")) "
                    + "set_completion=\(percent(completion["ratio"])) "
                    + "reps_attainment=\(percent(object(reps["attainment"])["ratio"])) "
                    + "load_attainment=\(percent(object(load["attainment"])["ratio"])) "
                    + "rir_attainment=\(percent(object(rir["attainment"])["ratio"])) "
                    + "small_sample=\(boolText(totals, "small_sample"))"
            )
            let coverage = object(value(envelope, "coverage"))
            lines.append(
                "coverage: workouts_in_range=\(intText(coverage, "workouts_in_range")) "
                    + "analysed=\(intText(coverage, "workouts_analysed")) "
                    + "unavailable=\(intText(coverage, "workouts_unavailable"))"
            )
            for period in array(value(envelope, "periods")).suffix(12) {
                let row = object(period)
                lines.append(
                    "- \(optionalString(row, "key") ?? "unknown"): "
                        + "workouts=\(intText(row, "workouts")) "
                        + "prescribed=\(intText(row, "prescribed_sets")) "
                        + "performed=\(intText(row, "performed_sets")) "
                        + "set_completion=\(percent(object(row["set_completion"])["ratio"]))"
                )
            }
            for exercise in array(value(envelope, "exercises")).prefix(8) {
                let row = object(exercise)
                let set = object(row["set_completion"])
                let loadRow = object(row["load"])
                lines.append(
                    "- \(optionalString(row, "exercise_name") ?? "unknown"): "
                        + "prescribed=\(intText(row, "prescribed_sets")) "
                        + "performed=\(intText(row, "performed_sets")) "
                        + "matched=\(intText(row, "matched_sets")) "
                        + "set_completion=\(percent(set["ratio"])) "
                        + "load_attainment=\(percent(object(loadRow["attainment"])["ratio"]))"
                )
            }
        }
        lines.append(contentsOf: extras(envelope))
        return lines.joined(separator: "\n")
    }

    private static func programme(_ envelope: IntelligenceEnvelope) -> String {
        var lines = ["programme: status=\(envelope.status)"]
        if envelope.status == "ok" {
            let window = object(value(envelope, "window"))
            let settings = object(value(envelope, "settings"))
            let deload = object(value(envelope, "deload"))
            let attendance = object(value(envelope, "attendance"))
            lines.append(
                "window: as_of=\(optionalString(window, "as_of") ?? "n/a") "
                    + "from=\(optionalString(window, "start") ?? "n/a") "
                    + "to=\(optionalString(window, "end") ?? "n/a") "
                    + "weeks=\(intText(window, "weeks"))"
            )
            lines.append(
                "settings: profile=\(intText(settings, "profile_id")) "
                    + "effective=\(optionalString(settings, "effective_from") ?? "n/a")"
            )
            lines.append(
                "deload: active=\(boolText(deload, "active")) "
                    + "reason=\(optionalString(deload, "reason") ?? "n/a")"
            )
            lines.append(
                "attendance: completed=\(intText(attendance, "completed")) "
                    + "target=\(intText(attendance, "target")) "
                    + "pct=\(percentText(attendance["pct"]))"
            )
            if let breaks = optionalArray(value(envelope, "breaks")), !breaks.isEmpty {
                lines.append("breaks: \(breaks.count) recorded")
            }
        }
        lines.append(contentsOf: extras(envelope))
        return lines.joined(separator: "\n")
    }

    private static func extras(_ envelope: IntelligenceEnvelope) -> [String] {
        var lines: [String] = []
        if !envelope.missing.isEmpty {
            lines.append("missing: " + envelope.missing.joined(separator: "; "))
        }
        let limitations = envelope.limitations.prefix(2).map { String($0.prefix(240)) }
        if !limitations.isEmpty {
            lines.append("limitations: " + limitations.joined(separator: " | "))
        }
        return lines
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

    private static func optionalString(_ object: [String: JSONValue], _ key: String) -> String? {
        if case .string(let text) = object[key] { return text }
        return nil
    }

    private static func number(_ object: [String: JSONValue], _ key: String) -> Double? {
        if case .number(let number) = object[key] { return number }
        return nil
    }

    private static func optionalInt(_ object: [String: JSONValue], _ key: String) -> Int? {
        number(object, key).map(Int.init)
    }

    private static func intText(_ object: [String: JSONValue], _ key: String) -> String {
        optionalInt(object, key).map(String.init) ?? "n/a"
    }

    private static func boolText(_ object: [String: JSONValue], _ key: String) -> String {
        if case .bool(let flag) = object[key] { return flag ? "true" : "false" }
        return "n/a"
    }

    private static func percent(_ value: JSONValue?) -> String {
        if case .number(let number)? = value { return String(format: "%.1f%%", number * 100) }
        return "n/a"
    }

    private static func percentText(_ value: JSONValue?) -> String {
        if case .number(let number)? = value { return String(format: "%.1f%%", number) }
        return "n/a"
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

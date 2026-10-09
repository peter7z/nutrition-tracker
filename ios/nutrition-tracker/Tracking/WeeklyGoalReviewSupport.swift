import Foundation

struct WeeklyHealthWeightDay: Equatable {
    let day: String
    let kilograms: Double
}

struct WeeklyHealthNutritionDay: Equatable {
    let day: String
    let energy: Double?
    let protein: Double?
    let carbohydrates: Double?
    let fat: Double?
}

struct WeeklyHealthActivityDay: Equatable {
    let day: String
    let exerciseMinutes: Double?
    let activeKcal: Double?
}

/// A consented, de-identified 14-day summary. It contains no Health record IDs,
/// source names, device names, or raw samples.
struct WeeklyHealthReviewContext: Equatable {
    let startDay: String
    let endDay: String
    let weights: [WeeklyHealthWeightDay]
    let dailyNutrition: [WeeklyHealthNutritionDay]
    let dailyActivity: [WeeklyHealthActivityDay]

    var jsonValue: JSONValue {
        func number(_ value: Double?) -> JSONValue? {
            guard let value, value.isFinite, value >= 0 else { return nil }
            return .number(value)
        }
        let weightValues: [JSONValue] = Array(weights.sorted { $0.day < $1.day }.uniquedByDay().prefix(14)).compactMap { value in
            guard value.kilograms.isFinite, value.kilograms > 0 else { return nil }
            return .object(["day": .string(value.day), "kilograms": .number(value.kilograms)])
        }
        let nutritionValues: [JSONValue] = Array(dailyNutrition.sorted { $0.day < $1.day }.uniquedByDay().prefix(14)).compactMap { value in
            var result: [String: JSONValue] = ["day": .string(value.day)]
            if let item = number(value.energy) { result["energy"] = item }
            if let item = number(value.protein) { result["protein"] = item }
            if let item = number(value.carbohydrates) { result["carbohydrates"] = item }
            if let item = number(value.fat) { result["fat"] = item }
            guard result.count > 1 else { return nil }
            return .object(result)
        }
        let activityValues: [JSONValue] = Array(dailyActivity.sorted { $0.day < $1.day }.uniquedByDay().prefix(14)).compactMap { value in
            var result: [String: JSONValue] = ["day": .string(value.day)]
            if let value = number(value.exerciseMinutes) { result["exercise_minutes"] = value }
            if let value = number(value.activeKcal) { result["active_kcal"] = value }
            guard result.count > 1 else { return nil }
            return .object(result)
        }
        return .object([
            "consent": .bool(true),
            "purpose": .string("weekly_review"),
            "start_day": .string(startDay),
            "end_day": .string(endDay),
            "weights": .array(weightValues),
            "daily_nutrition": .array(nutritionValues),
            "daily_activity": .array(activityValues)
        ])
    }
}

private extension Array where Element == WeeklyHealthWeightDay {
    func uniquedByDay() -> [Element] {
        var seen = Set<String>()
        return filter { seen.insert($0.day).inserted }
    }
}

private extension Array where Element == WeeklyHealthNutritionDay {
    func uniquedByDay() -> [Element] {
        var seen = Set<String>()
        return filter { seen.insert($0.day).inserted }
    }
}

private extension Array where Element == WeeklyHealthActivityDay {
    func uniquedByDay() -> [Element] {
        var seen = Set<String>()
        return filter { seen.insert($0.day).inserted }
    }
}

struct WeeklyGoalProposalValues: Equatable {
    let energy: Double?
    let protein: Double?
    let carbohydrates: Double?
    let fat: Double?
    let effectiveDay: String
    let rationale: String
    let assumptions: [String]
    let requiresConfirmation: Bool
}

enum WeeklyGoalReviewError: Error, Equatable {
    case confirmationRequired
    case staleGoalVersion
    case invalidProposal
}

/// Creates an isolated candidate snapshot. The caller must obtain user approval
/// and pass this snapshot to TrackingSync.applyConfirmed before publishing it.
@MainActor enum WeeklyGoalProposalStager {
    static func stage(
        _ proposal: WeeklyGoalProposalValues,
        in store: NutritionStore,
        reviewedAt: Date,
        capturedGoalVersionID: UUID?,
        operationID: UUID,
        capturedGoalVersions: [NutritionGoalVersion]? = nil
    ) throws -> NutritionSnapshot {
        guard proposal.requiresConfirmation else { throw WeeklyGoalReviewError.confirmationRequired }
        if let capturedGoalVersions, store.snapshot.goals != capturedGoalVersions {
            throw WeeklyGoalReviewError.staleGoalVersion
        }
        guard store.goalVersion(on: reviewedAt)?.id == capturedGoalVersionID else {
            throw WeeklyGoalReviewError.staleGoalVersion
        }
        guard let effectiveDate = parseDay(proposal.effectiveDay, calendar: store.snapshot.profile.calendar) else {
            throw WeeklyGoalReviewError.invalidProposal
        }
        guard store.snapshot.profile.calendar.startOfDay(for: effectiveDate)
                >= store.snapshot.profile.calendar.startOfDay(for: reviewedAt) else {
            throw WeeklyGoalReviewError.invalidProposal
        }
        let previous = store.goals(on: reviewedAt)
        func selected(_ value: Double?, previous: Double?) -> Double? {
            guard let value else { return previous }
            return value.isFinite && value > 0 && value < 100_000 ? value : nil
        }
        guard let energy = selected(proposal.energy, previous: previous?.energy),
              let protein = selected(proposal.protein, previous: previous?.protein),
              let carbohydrates = selected(proposal.carbohydrates, previous: previous?.carbohydrates),
              let fat = selected(proposal.fat, previous: previous?.fat) else {
            throw WeeklyGoalReviewError.invalidProposal
        }
        let goals = NutritionGoals(energy: energy, protein: protein, carbohydrates: carbohydrates, fat: fat)
        guard goals.isValid else { throw WeeklyGoalReviewError.invalidProposal }
        let staged = NutritionStore(persistence: PreparedNutritionPersistence(store.snapshot))
        try staged.saveGoals(goals, effectiveDate: effectiveDate, operationID: operationID, versionID: operationID)
        return staged.snapshot
    }

    private static func parseDay(_ value: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }
}

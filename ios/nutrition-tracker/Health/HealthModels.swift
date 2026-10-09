import Foundation

enum HealthMetric: String, CaseIterable, Codable, Identifiable {
    case weight, steps, activeEnergy, restingEnergy, exerciseMinutes, workout
    case dietaryEnergy, protein, carbohydrates, fat, saturatedFat

    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .weight: "Weight"
        case .steps: "Steps"
        case .activeEnergy: "Active energy"
        case .restingEnergy: "Resting energy"
        case .exerciseMinutes: "Exercise time"
        case .workout: "Workouts"
        case .dietaryEnergy: "Dietary energy"
        case .protein: "Protein"
        case .carbohydrates: "Carbs"
        case .fat: "Fat"
        case .saturatedFat: "Saturated fat"
        }
    }
    var unit: String {
        switch self {
        case .weight: "kg"
        case .steps: ""
        case .activeEnergy, .restingEnergy, .dietaryEnergy: "kcal"
        case .exerciseMinutes, .workout: "min"
        default: "g"
        }
    }
    var isNutrition: Bool { [.dietaryEnergy, .protein, .carbohydrates, .fat, .saturatedFat].contains(self) }
    var isCumulative: Bool { self != .weight && self != .workout }
}

struct HealthImportConfiguration: Codable, Equatable {
    var metrics: Set<HealthMetric>
    var startDate: Date?
    var timeZoneIdentifier: String

    var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        return result
    }
}

struct HealthSampleRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var metric: HealthMetric
    var startDate: Date
    var endDate: Date
    var value: Double
    var sourceName: String
    var sourceBundleIdentifier: String
    var deviceName: String?
    var workoutActivityCode: UInt?
}

struct HealthDayValue: Codable, Equatable {
    var metric: HealthMetric
    var date: Date
    var value: Double
    var sourceNames: [String]
}

struct NutritionGoals: Codable, Equatable {
    var energy: Double
    var protein: Double
    var carbohydrates: Double
    var fat: Double
    var isValid: Bool { [energy, protein, carbohydrates, fat].allSatisfy { $0.isFinite && $0 > 0 && $0 < 100_000 } }
}

struct HealthNutritionClosure: Codable, Equatable, Identifiable {
    var id: UUID
    var accountScope: String
    var dayID: String
    var closedAt: Date
    var values: [HealthDayValue]
    var goals: NutritionGoals?
}

struct HealthSnapshot: Codable, Equatable {
    var schemaVersion = 1
    var configuration: HealthImportConfiguration?
    var isConnected = false
    var samples: [HealthSampleRecord] = []
    var anchors: [String: Data] = [:]
    var dailyValues: [HealthDayValue] = []
    var lastSyncDate: Date?
    var goals: NutritionGoals?
    var closedNutritionDays: [HealthNutritionClosure]? = nil
    var pendingChatContexts: [String: Data]? = nil

    func value(for metric: HealthMetric, on date: Date) -> Double? {
        let calendar = configuration?.calendar ?? Calendar.current
        return dailyValues.first { $0.metric == metric && calendar.isDate($0.date, inSameDayAs: date) }?.value
    }

    func latestWeight(before date: Date) -> HealthSampleRecord? {
        samples.filter { $0.metric == .weight && $0.endDate <= date }.max { $0.endDate < $1.endDate }
    }
}

struct HealthDelta {
    var samples: [HealthSampleRecord]
    var deletedIDs: [UUID]
    var anchor: Data
    var hasMore: Bool
}

struct StagedHealthImport {
    var snapshot: HealthSnapshot
    var preparedAt: Date
}

enum HealthOperationError: Error {
    case unavailable, invalidConfiguration, invalidData, stalledCursor, unsupportedSchema
}

import Foundation

enum HealthMetric: String, CaseIterable, Codable, Identifiable {
    case weight, steps, activeEnergy, restingEnergy, exerciseMinutes, workout
    case dietaryEnergy, protein, carbohydrates, fat, saturatedFat, fiber
    case vitaminA, thiamin, riboflavin, niacin, pantothenicAcid, vitaminB6, biotin, vitaminB12
    case vitaminC, vitaminD, vitaminE, vitaminK, folate
    case calcium, chloride, iron, magnesium, phosphorus, potassium, sodium, zinc
    case chromium, copper, iodine, manganese, molybdenum, selenium

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
        case .fiber: "Fiber"
        case .vitaminA: "Vitamin A"
        case .thiamin: "Thiamin (B1)"
        case .riboflavin: "Riboflavin (B2)"
        case .niacin: "Niacin (B3)"
        case .pantothenicAcid: "Pantothenic acid (B5)"
        case .vitaminB6: "Vitamin B6"
        case .biotin: "Biotin (B7)"
        case .vitaminB12: "Vitamin B12"
        case .vitaminC: "Vitamin C"
        case .vitaminD: "Vitamin D"
        case .vitaminE: "Vitamin E"
        case .vitaminK: "Vitamin K"
        case .folate: "Folate"
        case .calcium: "Calcium"
        case .chloride: "Chloride"
        case .iron: "Iron"
        case .magnesium: "Magnesium"
        case .phosphorus: "Phosphorus"
        case .potassium: "Potassium"
        case .sodium: "Sodium"
        case .zinc: "Zinc"
        case .chromium: "Chromium"
        case .copper: "Copper"
        case .iodine: "Iodine"
        case .manganese: "Manganese"
        case .molybdenum: "Molybdenum"
        case .selenium: "Selenium"
        }
    }
    var unit: String {
        switch self {
        case .weight: "kg"
        case .steps: ""
        case .activeEnergy, .restingEnergy, .dietaryEnergy: "kcal"
        case .exerciseMinutes, .workout: "min"
        case .vitaminA, .biotin, .vitaminB12, .vitaminD, .vitaminK, .folate, .chromium, .iodine, .molybdenum, .selenium: "mcg"
        case .thiamin, .riboflavin, .niacin, .pantothenicAcid, .vitaminB6, .vitaminC, .vitaminE, .calcium, .chloride, .iron, .magnesium, .phosphorus, .potassium, .sodium, .zinc, .copper, .manganese: "mg"
        default: "g"
        }
    }
    var isNutrition: Bool { Self.nutritionMetrics.contains(self) }
    var isCumulative: Bool { self != .weight && self != .workout }
    static let nutritionMetrics: Set<HealthMetric> = [
        .dietaryEnergy, .protein, .carbohydrates, .fat, .saturatedFat, .fiber,
        .vitaminA, .thiamin, .riboflavin, .niacin, .pantothenicAcid, .vitaminB6, .biotin, .vitaminB12,
        .vitaminC, .vitaminD, .vitaminE, .vitaminK, .folate, .calcium, .chloride, .iron, .magnesium,
        .phosphorus, .potassium, .sodium, .zinc, .chromium, .copper, .iodine, .manganese, .molybdenum, .selenium
    ]
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

struct HealthNutritionDaySnapshot: Codable, Equatable, Identifiable {
    var id: UUID
    var accountScope: String
    var dayID: String
    var capturedAt: Date
    var values: [HealthDayValue]
    var goals: NutritionGoals?
    private enum CodingKeys: String, CodingKey {
        case id, accountScope, dayID, values, goals
        case capturedAt = "closedAt"
    }
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
    var nutritionDaySnapshots: [HealthNutritionDaySnapshot]? = nil
    var pendingChatContexts: [String: Data]? = nil
    // Legacy storage names remain at the serialization boundary only.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, configuration, isConnected, samples, anchors, dailyValues, lastSyncDate, goals, pendingChatContexts
        case nutritionDaySnapshots = "closedNutritionDays"
    }

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

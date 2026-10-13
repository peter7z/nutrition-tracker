import Foundation
import HealthKit

@MainActor protocol HealthDataClient {
    var isAvailable: Bool { get }
    func requestReadAccess(to metrics: Set<HealthMetric>) async throws
    func changes(for metric: HealthMetric, start: Date?, anchor: Data?) async throws -> HealthDelta
    func dailyStatistics(for metric: HealthMetric, start: Date, end: Date, calendar: Calendar) async throws -> [HealthDayValue]
}

@MainActor final class HealthKitClient: HealthDataClient {
    private let store = HKHealthStore()
    private let pageSize = 500
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestReadAccess(to metrics: Set<HealthMetric>) async throws {
        guard isAvailable else { throw HealthOperationError.unavailable }
        let types = try Set(metrics.map { try $0.sampleType as HKObjectType })
        // Success means the authorization flow finished; it does NOT reveal read permission.
        try await store.requestAuthorization(toShare: [], read: types)
    }

    func changes(for metric: HealthMetric, start: Date?, anchor: Data?) async throws -> HealthDelta {
        let queryAnchor: HKQueryAnchor?
        if let anchor {
            guard let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: anchor) else {
                throw HealthOperationError.invalidData
            }
            queryAnchor = decoded
        } else { queryAnchor = nil }
        // Keep the predicate stable across runs: no moving end date on an anchored query.
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let descriptor = HKAnchoredObjectQueryDescriptor<HKSample>(
            predicates: [.sample(type: try metric.sampleType, predicate: predicate)],
            anchor: queryAnchor, limit: pageSize
        )
        let result = try await descriptor.result(for: store)
        let records = try result.addedSamples.map { try record(from: $0, metric: metric) }
        let encodedAnchor = try NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true)
        return HealthDelta(samples: records, deletedIDs: result.deletedObjects.map(\.uuid), anchor: encodedAnchor,
                           hasMore: result.addedSamples.count + result.deletedObjects.count >= pageSize)
    }

    func dailyStatistics(for metric: HealthMetric, start: Date, end: Date, calendar: Calendar) async throws -> [HealthDayValue] {
        guard metric.isCumulative, let type = try metric.sampleType as? HKQuantityType else { return [] }
        let dayStart = calendar.startOfDay(for: start)
        var interval = DateComponents(day: 1)
        interval.calendar = calendar
        interval.timeZone = calendar.timeZone
        let predicate = HKQuery.predicateForSamples(withStart: dayStart, end: end, options: [])
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate), options: .cumulativeSum,
            anchorDate: dayStart, intervalComponents: interval
        )
        let result = try await descriptor.result(for: store)
        var values: [HealthDayValue] = []
        for statistic in result.statistics() where statistic.startDate >= dayStart && statistic.startDate <= end {
            guard let quantity = statistic.sumQuantity() else { continue }
            let value = quantity.doubleValue(for: metric.healthUnit)
            guard value.isFinite && value >= 0 else { throw HealthOperationError.invalidData }
            values.append(HealthDayValue(metric: metric, date: statistic.startDate, value: value,
                                        sourceNames: (statistic.sources ?? []).map(\.name).sorted()))
        }
        // Use HealthKit's merged statistics, never a raw sum of Watch + iPhone samples.
        return values
    }

    private func record(from sample: HKSample, metric: HealthMetric) throws -> HealthSampleRecord {
        let value: Double
        let activity: UInt?
        if let workout = sample as? HKWorkout {
            value = workout.duration / 60
            activity = workout.workoutActivityType.rawValue
        } else if let quantity = sample as? HKQuantitySample {
            value = quantity.quantity.doubleValue(for: metric.healthUnit)
            activity = nil
        } else { throw HealthOperationError.invalidData }
        guard value.isFinite, value >= 0, metric != .weight || value > 0 else { throw HealthOperationError.invalidData }
        return HealthSampleRecord(id: sample.uuid, metric: metric, startDate: sample.startDate, endDate: sample.endDate,
                                  value: value, sourceName: sample.sourceRevision.source.name,
                                  sourceBundleIdentifier: sample.sourceRevision.source.bundleIdentifier,
                                  deviceName: sample.device?.name, workoutActivityCode: activity)
    }
}

extension HealthMetric {
    var sampleType: HKSampleType {
        get throws {
            if self == .workout { return HKObjectType.workoutType() }
            let identifier: HKQuantityTypeIdentifier
            switch self {
            case .weight: identifier = .bodyMass
            case .steps: identifier = .stepCount
            case .activeEnergy: identifier = .activeEnergyBurned
            case .restingEnergy: identifier = .basalEnergyBurned
            case .exerciseMinutes: identifier = .appleExerciseTime
            case .dietaryEnergy: identifier = .dietaryEnergyConsumed
            case .protein: identifier = .dietaryProtein
            case .carbohydrates: identifier = .dietaryCarbohydrates
            case .fat: identifier = .dietaryFatTotal
            case .saturatedFat: identifier = .dietaryFatSaturated
            case .fiber: identifier = .dietaryFiber
            case .vitaminA: identifier = .dietaryVitaminA
            case .thiamin: identifier = .dietaryThiamin
            case .riboflavin: identifier = .dietaryRiboflavin
            case .niacin: identifier = .dietaryNiacin
            case .pantothenicAcid: identifier = .dietaryPantothenicAcid
            case .vitaminB6: identifier = .dietaryVitaminB6
            case .biotin: identifier = .dietaryBiotin
            case .vitaminB12: identifier = .dietaryVitaminB12
            case .vitaminC: identifier = .dietaryVitaminC
            case .vitaminD: identifier = .dietaryVitaminD
            case .vitaminE: identifier = .dietaryVitaminE
            case .vitaminK: identifier = .dietaryVitaminK
            case .folate: identifier = .dietaryFolate
            case .calcium: identifier = .dietaryCalcium
            case .chloride: identifier = .dietaryChloride
            case .iron: identifier = .dietaryIron
            case .magnesium: identifier = .dietaryMagnesium
            case .phosphorus: identifier = .dietaryPhosphorus
            case .potassium: identifier = .dietaryPotassium
            case .sodium: identifier = .dietarySodium
            case .zinc: identifier = .dietaryZinc
            case .chromium: identifier = .dietaryChromium
            case .copper: identifier = .dietaryCopper
            case .iodine: identifier = .dietaryIodine
            case .manganese: identifier = .dietaryManganese
            case .molybdenum: identifier = .dietaryMolybdenum
            case .selenium: identifier = .dietarySelenium
            case .workout: throw HealthOperationError.invalidConfiguration
            }
            guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { throw HealthOperationError.unavailable }
            return type
        }
    }

    var healthUnit: HKUnit {
        switch self {
        case .weight: .gramUnit(with: .kilo)
        case .steps: .count()
        case .activeEnergy, .restingEnergy, .dietaryEnergy: .kilocalorie()
        case .exerciseMinutes, .workout: .minute()
        case .vitaminA, .biotin, .vitaminB12, .vitaminD, .vitaminK, .folate, .chromium, .iodine, .molybdenum, .selenium:
            .gramUnit(with: .micro)
        case .thiamin, .riboflavin, .niacin, .pantothenicAcid, .vitaminB6, .vitaminC, .vitaminE, .calcium, .chloride,
             .iron, .magnesium, .phosphorus, .potassium, .sodium, .zinc, .copper, .manganese:
            .gramUnit(with: .milli)
        default: .gram()
        }
    }
}

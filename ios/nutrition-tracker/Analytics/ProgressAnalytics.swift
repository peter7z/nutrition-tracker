import Foundation

/// A weight sample from any source. Raw observations are retained by the analytics
/// result even when a conflict is unresolved or a sample is not selected daily.
struct WeightObservation: Equatable, Identifiable {
    let id: String
    let date: Date
    let kg: Double
    let source: String

    init(id: String, date: Date, kg: Double, source: String) {
        self.id = id
        self.date = date
        self.kg = kg
        self.source = source
    }
}

struct ActivityObservation: Equatable, Identifiable {
    let id: String
    let date: Date
    /// Duration in minutes.
    let durationMinutes: Double?
    /// Active energy in kcal. Unknown energy stays nil.
    let activeEnergyKcal: Double?
    let source: String

    init(id: String, date: Date, durationMinutes: Double? = nil, activeEnergyKcal: Double? = nil, source: String) {
        self.id = id
        self.date = date
        self.durationMinutes = durationMinutes
        self.activeEnergyKcal = activeEnergyKcal
        self.source = source
    }
}

/// One persisted daily intake summary. Nil nutrients are unknown, never zero.
struct DailyIntakeObservation: Equatable {
    let date: Date
    let caloriesKcal: Double?
    let proteinGrams: Double?
    let carbohydratesGrams: Double?
    let fatGrams: Double?
    let isComplete: Bool

    init(
        date: Date,
        caloriesKcal: Double? = nil,
        proteinGrams: Double? = nil,
        carbohydratesGrams: Double? = nil,
        fatGrams: Double? = nil,
        isComplete: Bool
    ) {
        self.date = date
        self.caloriesKcal = caloriesKcal
        self.proteinGrams = proteinGrams
        self.carbohydratesGrams = carbohydratesGrams
        self.fatGrams = fatGrams
        self.isComplete = isComplete
    }
}

enum WeightConflictChoice: Equatable {
    case include(observationID: String)
    case exclude
}

struct WeightConflictGroup: Equatable, Identifiable {
    /// Stable for the same set of observation IDs, independent of input order.
    let id: String
    let observations: [WeightObservation]
}

struct DailyWeight: Equatable, Identifiable {
    let date: Date
    let observation: WeightObservation
    var id: Date { date }
}

struct WeightResolution: Equatable {
    /// All valid raw records, including duplicate and unresolved records.
    let rawObservations: [WeightObservation]
    /// Latest chosen valid observation for each local calendar day.
    let dailyWeights: [DailyWeight]
    let conflictGroups: [WeightConflictGroup]
    let unresolvedConflictGroupIDs: Set<String>
    let unresolvedConflictCount: Int
    let excludedObservationCount: Int

    var rawSampleCount: Int { rawObservations.count }
    var coveredDayCount: Int { dailyWeights.count }
}

struct MovingWeightAverage: Equatable, Identifiable {
    /// Local calendar day, represented by its start of day in the selected timezone.
    let date: Date
    let averageKg: Double
    /// Number of covered daily weights used in the arithmetic mean.
    let contributingDayCount: Int
    /// Number of valid raw observations on those covered days, including
    /// observations that were excluded by conflict resolution.
    let rawSampleCount: Int
    var id: Date { date }
}

struct ActivitySummary: Equatable {
    let observationCount: Int
    let coveredDayCount: Int
    let durationMinutes: Double?
    let durationObservationCount: Int
    let activeEnergyKcal: Double?
    let activeEnergyObservationCount: Int
}

struct WeeklyReviewSummary: Equatable {
    /// The inclusive 14 local calendar days ending on `endDate`.
    let startDate: Date
    let endDate: Date
    let completeNutritionDays: Int
    let incompleteNutritionDays: Int
    let caloriesKcal: Double?
    let caloriesCoverageDays: Int
    let averageCaloriesKcalPerObservedDay: Double?
    let proteinGrams: Double?
    let proteinCoverageDays: Int
    let averageProteinGramsPerObservedDay: Double?
    let weightDayCount: Int
    let firstWeekWeightDayCount: Int
    let secondWeekWeightDayCount: Int
    let meanWeightKg: Double?
    let activity: ActivitySummary
    let unresolvedWeightConflictCount: Int
    let isEligibleForGoalReview: Bool

    static let reviewWindowDays = 14
    static let minimumCompleteNutritionDays = 10
    static let minimumWeightDays = 6
    static let minimumWeightDaysPerWeek = 3
}

/// Deterministic calculations over caller-supplied observations. The caller must
/// provide the profile timezone; all day boundaries use a Gregorian calendar in
/// that timezone. This type makes observations only and never creates goals or
/// medical advice.
struct ProgressAnalytics {
    let calendar: Calendar

    init(timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    init?(timeZoneIdentifier: String) {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        self.init(timeZone: timeZone)
    }

    /// Finds cross-source candidate duplicates within 10 minutes and 0.1 kg.
    /// A group with no explicit choice is omitted from trend calculations and
    /// remains visible in `unresolvedConflictCount`.
    func resolveWeights(
        _ observations: [WeightObservation],
        choices: [String: WeightConflictChoice] = [:]
    ) -> WeightResolution {
        let valid = observations
            .filter { $0.kg.isFinite && $0.kg > 0 && $0.date.timeIntervalSinceReferenceDate.isFinite }
            .sorted(by: Self.observationOrder)
        let groups = conflictGroups(in: valid)
        var groupedIDs = Set<String>()
        var included = [WeightObservation]()
        var unresolvedGroupIDs = Set<String>()
        var unresolvedCount = 0
        var excludedCount = 0

        for group in groups {
            let ids = Set(group.observations.map(\.id))
            groupedIDs.formUnion(ids)
            guard let choice = choices[group.id] else {
                unresolvedGroupIDs.insert(group.id)
                unresolvedCount += 1
                excludedCount += group.observations.count
                continue
            }
            switch choice {
            case let .include(observationID):
                if let selected = group.observations.first(where: { $0.id == observationID }) {
                    included.append(selected)
                    excludedCount += group.observations.count - 1
                } else {
                    // Invalid choices cannot silently resolve a conflict.
                    unresolvedGroupIDs.insert(group.id)
                    unresolvedCount += 1
                    excludedCount += group.observations.count
                }
            case .exclude:
                excludedCount += group.observations.count
            }
        }

        included.append(contentsOf: valid.filter { !groupedIDs.contains($0.id) })
        let daily = dailyWeights(from: included)
        return WeightResolution(
            rawObservations: valid,
            dailyWeights: daily,
            conflictGroups: groups,
            unresolvedConflictGroupIDs: unresolvedGroupIDs,
            unresolvedConflictCount: unresolvedCount,
            excludedObservationCount: excludedCount
        )
    }

    /// Produces points only for days with a daily weight. Each point averages
    /// daily weights from its own day and the prior `calendarDays - 1` days.
    /// Missing days are absent; no zeros or interpolated values are created.
    func movingAverages(
        for resolution: WeightResolution,
        calendarDays: Int = 7
    ) -> [MovingWeightAverage] {
        guard calendarDays > 0 else { return [] }
        let weights = resolution.dailyWeights.sorted { $0.date < $1.date }
        return weights.map { point in
            let windowStart = calendar.date(byAdding: .day, value: -(calendarDays - 1), to: point.date) ?? point.date
            let window = weights.filter { $0.date >= windowStart && $0.date <= point.date }
            let sum = window.reduce(0.0) { $0 + $1.observation.kg }
            let rawCount = resolution.rawObservations.filter {
                let day = calendar.startOfDay(for: $0.date)
                return day >= windowStart && day <= point.date
            }.count
            return MovingWeightAverage(
                date: point.date,
                averageKg: sum / Double(window.count),
                contributingDayCount: window.count,
                rawSampleCount: rawCount
            )
        }
    }

    /// Summarizes actual observations in the 14 calendar days ending on `endDate`.
    /// Complete/incomplete coverage is based on the explicit daily completeness
    /// flag. Nutrient sums include only supplied, finite values, with coverage
    /// counts beside them; they do not turn missing values into zero.
    func weeklyReview(
        endingAt endDate: Date,
        weights: WeightResolution,
        activities: [ActivityObservation],
        intakes: [DailyIntakeObservation]
    ) -> WeeklyReviewSummary {
        let endDay = calendar.startOfDay(for: endDate)
        let startDay = calendar.date(byAdding: .day, value: -13, to: endDay) ?? endDay
        let nextDay = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay.addingTimeInterval(86_400)
        let dayInRange: (Date) -> Bool = { $0 >= startDay && $0 < nextDay }

        // A daily snapshot may be revised during a day. Keep the latest snapshot
        // for that local day so revisions are not counted as separate days.
        var intakeByDay = [Date: DailyIntakeObservation]()
        for intake in intakes where dayInRange(intake.date) {
            let day = calendar.startOfDay(for: intake.date)
            if let current = intakeByDay[day], current.date >= intake.date { continue }
            intakeByDay[day] = intake
        }
        let dailyIntakes = intakeByDay.values.sorted { $0.date < $1.date }
        let completeDays = dailyIntakes.filter(\.isComplete).count
        let incompleteDays = dailyIntakes.filter { !$0.isComplete }.count
        let calories = dailyIntakes.compactMap(\.caloriesKcal).filter(Self.isValidNutrient)
        let protein = dailyIntakes.compactMap(\.proteinGrams).filter(Self.isValidNutrient)

        let windowWeights = weights.dailyWeights.filter { dayInRange($0.date) }
        let firstWeekEnd = calendar.date(byAdding: .day, value: 7, to: startDay) ?? endDay
        let firstWeekCount = windowWeights.filter { $0.date < firstWeekEnd }.count
        let secondWeekCount = windowWeights.count - firstWeekCount
        let meanWeight: Double? = windowWeights.isEmpty
            ? nil
            : windowWeights.reduce(0.0) { $0 + $1.observation.kg } / Double(windowWeights.count)

        let validActivities = activities.filter { activity in
            guard dayInRange(activity.date) else { return false }
            let validDuration = activity.durationMinutes.map { $0.isFinite && $0 >= 0 } ?? false
            let validEnergy = activity.activeEnergyKcal.map { $0.isFinite && $0 >= 0 } ?? false
            return validDuration || validEnergy
        }
        let durationValues = validActivities.compactMap(\.durationMinutes).filter { $0.isFinite && $0 >= 0 }
        let energyValues = validActivities.compactMap(\.activeEnergyKcal).filter { $0.isFinite && $0 >= 0 }
        let activityDays = Set(validActivities.map { calendar.startOfDay(for: $0.date) })
        let activity = ActivitySummary(
            observationCount: validActivities.count,
            coveredDayCount: activityDays.count,
            durationMinutes: durationValues.isEmpty ? nil : durationValues.reduce(0, +),
            durationObservationCount: durationValues.count,
            activeEnergyKcal: energyValues.isEmpty ? nil : energyValues.reduce(0, +),
            activeEnergyObservationCount: energyValues.count
        )

        let conflictsInWindow = weights.conflictGroups.filter { group in
            weights.unresolvedConflictGroupIDs.contains(group.id)
                && group.observations.contains { dayInRange($0.date) }
        }.count

        let eligible = completeDays >= WeeklyReviewSummary.minimumCompleteNutritionDays
            && windowWeights.count >= WeeklyReviewSummary.minimumWeightDays
            && firstWeekCount >= WeeklyReviewSummary.minimumWeightDaysPerWeek
            && secondWeekCount >= WeeklyReviewSummary.minimumWeightDaysPerWeek

        return WeeklyReviewSummary(
            startDate: startDay,
            endDate: endDay,
            completeNutritionDays: completeDays,
            incompleteNutritionDays: incompleteDays,
            caloriesKcal: calories.isEmpty ? nil : calories.reduce(0, +),
            caloriesCoverageDays: calories.count,
            averageCaloriesKcalPerObservedDay: calories.isEmpty ? nil : calories.reduce(0, +) / Double(calories.count),
            proteinGrams: protein.isEmpty ? nil : protein.reduce(0, +),
            proteinCoverageDays: protein.count,
            averageProteinGramsPerObservedDay: protein.isEmpty ? nil : protein.reduce(0, +) / Double(protein.count),
            weightDayCount: windowWeights.count,
            firstWeekWeightDayCount: firstWeekCount,
            secondWeekWeightDayCount: secondWeekCount,
            meanWeightKg: meanWeight,
            activity: activity,
            unresolvedWeightConflictCount: conflictsInWindow,
            isEligibleForGoalReview: eligible
        )
    }

    private func dailyWeights(from observations: [WeightObservation]) -> [DailyWeight] {
        var latestByDay = [Date: WeightObservation]()
        for observation in observations {
            let day = calendar.startOfDay(for: observation.date)
            if let current = latestByDay[day], !Self.observationOrder(current, observation) { continue }
            latestByDay[day] = observation
        }
        return latestByDay.map { DailyWeight(date: $0.key, observation: $0.value) }.sorted { $0.date < $1.date }
    }

    private func conflictGroups(in observations: [WeightObservation]) -> [WeightConflictGroup] {
        guard observations.count > 1 else { return [] }
        var parent = Array(observations.indices)

        func root(_ index: Int, _ parents: inout [Int]) -> Int {
            if parents[index] != index { parents[index] = root(parents[index], &parents) }
            return parents[index]
        }

        for left in observations.indices {
            for right in observations.indices where right > left {
                let a = observations[left]
                let b = observations[right]
                guard a.source != b.source,
                      abs(a.date.timeIntervalSince(b.date)) <= 10 * 60,
                      abs(a.kg - b.kg) <= 0.1 else { continue }
                let aRoot = root(left, &parent)
                let bRoot = root(right, &parent)
                if aRoot != bRoot { parent[bRoot] = aRoot }
            }
        }

        var components = [Int: [WeightObservation]]()
        for index in observations.indices {
            let component = root(index, &parent)
            components[component, default: []].append(observations[index])
        }
        return components.values
            .filter { $0.count > 1 }
            .map { members in
                let sorted = members.sorted(by: Self.observationOrder)
                let ids = sorted.map(\.id).sorted()
                return WeightConflictGroup(id: ids.joined(separator: "|"), observations: sorted)
            }
            .sorted { $0.id < $1.id }
    }

    nonisolated private static func observationOrder(_ lhs: WeightObservation, _ rhs: WeightObservation) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.id < rhs.id
    }

    nonisolated private static func isValidNutrient(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 1_000_000
    }
}

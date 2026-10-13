import Foundation

/// A calendar-day viewport over the saved history. Its upper bound is exclusive.
struct ProgressChartWindow: Equatable {
    let start: Date
    let end: Date
    let latestStart: Date
    let historyStart: Date
    let calendar: Calendar

    init(days: Int, position: Date?, earliest: Date?, today: Date, calendar: Calendar) {
        self.calendar = calendar
        let today = calendar.startOfDay(for: today)
        latestStart = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        historyStart = min(earliest.map { calendar.startOfDay(for: $0) } ?? latestStart, latestStart)
        let proposedStart = position.map { date in
            let day = calendar.startOfDay(for: date)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            // Native scroll offsets can land a fraction of a second before midnight.
            return nextDay.timeIntervalSince(date) < 1 ? nextDay : day
        } ?? latestStart
        start = min(max(proposedStart, historyStart), latestStart)
        end = calendar.date(byAdding: .day, value: days, to: start) ?? today
    }

    var lastDay: Date { calendar.date(byAdding: .day, value: -1, to: end) ?? start }
    var isLatest: Bool { start == latestStart }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    func contains(_ date: Date) -> Bool { date >= start && date < end }
}

struct SegmentedWeightAverage: Identifiable {
    let point: MovingWeightAverage
    let segment: Int
    var id: Date { point.date }
}

/// Rebuilt only when source data changes, rather than on every scroll frame.
struct ProgressWeightTimeline {
    let resolution: WeightResolution
    let averages: [MovingWeightAverage]
    let segmentedAverages: [SegmentedWeightAverage]

    init(analytics: ProgressAnalytics, observations: [WeightObservation], choices: [String: WeightConflictChoice]) {
        resolution = analytics.resolveWeights(observations, choices: choices)
        averages = analytics.movingAverages(for: resolution)
        var previous: Date?
        var segment = 0
        segmentedAverages = averages.map { point in
            if let previous, analytics.calendar.dateComponents([.day], from: previous, to: point.date).day != 1 {
                segment += 1
            }
            previous = point.date
            return SegmentedWeightAverage(point: point, segment: segment)
        }
    }

    init() {
        resolution = WeightResolution(rawObservations: [], dailyWeights: [], conflictGroups: [],
                                      unresolvedConflictGroupIDs: [], unresolvedConflictCount: 0, excludedObservationCount: 0)
        averages = []
        segmentedAverages = []
    }
}

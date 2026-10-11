import Charts
import SwiftUI

private enum ProgressWeightRange: Int, CaseIterable, Identifiable {
    case days30 = 30
    case days90 = 90
    case days365 = 365

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .days30: "30 days"
        case .days90: "90 days"
        case .days365: "1 year"
        }
    }
}

private enum WeightRecordReference {
    case local(ManualWeightEntry)
    case health(HealthSampleRecord)
}

private struct ResolvedActivityCandidate: Identifiable {
    let source: String
    let title: String
    let date: Date
    let durationMinutes: Double?
    let durationObservationCount: Int
    let activeEnergyKcal: Double?
    let energyObservationCount: Int
    let detail: String
    let recordCount: Int
    var id: String { source }
}

private struct ResolvedActivityDay: Identifiable {
    let dayID: String
    let date: Date
    let candidates: [ResolvedActivityCandidate]
    let selection: String?

    var id: String { dayID }
    var selected: ResolvedActivityCandidate? { selection.flatMap { source in candidates.first { $0.source == source } } }
    var hasConflict: Bool { candidates.count > 1 }
    var isUnresolved: Bool { hasConflict && selected == nil }
}

private struct SegmentedWeightAverage: Identifiable {
    let point: MovingWeightAverage
    let segment: Int
    var id: Date { point.date }
}

struct TrackingProgressView: View {
    @Environment(AccountSession.self) private var account
    @Environment(NutritionStore.self) private var nutrition
    @Environment(HealthSyncModel.self) private var health
    @Environment(\.legacyHistory) private var history
    @Environment(\.locale) private var locale
    @State private var selectedRange: ProgressWeightRange = .days90

    private var calendar: Calendar { nutrition.snapshot.profile.calendar }
    private var now: Date { .now }
    private var today: Date { calendar.startOfDay(for: now) }
    private var analytics: ProgressAnalytics { ProgressAnalytics(timeZone: calendar.timeZone) }

    private var weightReferences: [String: WeightRecordReference] {
        var result = [String: WeightRecordReference]()
        for value in nutrition.snapshot.weights {
            result[weightID(value)] = .local(value)
        }
        for value in health.snapshot.samples where value.metric == .weight {
            result[healthWeightID(value)] = .health(value)
        }
        return result
    }

    private var weightObservations: [WeightObservation] {
        let local = nutrition.snapshot.weights.map { value in
            WeightObservation(
                id: weightID(value), date: value.recordedAt, kg: value.kilograms,
                source: "tracking:\(value.source.rawValue)"
            )
        }
        let imported = health.snapshot.samples.filter { $0.metric == .weight }.map { value in
            WeightObservation(
                id: healthWeightID(value), date: value.endDate, kg: value.value,
                source: healthSourceKey(value)
            )
        }
        return (local + imported).filter {
            let day = calendar.startOfDay(for: $0.date)
            return day >= rangeStart && day <= today
        }
    }

    private var weightResolution: WeightResolution {
        let choices = nutrition.snapshot.weightConflictSelections.mapValues { selected in
            selected == "__exclude__" ? WeightConflictChoice.exclude : .include(observationID: selected)
        }
        return analytics.resolveWeights(weightObservations, choices: choices)
    }

    private var rangeStart: Date {
        calendar.date(byAdding: .day, value: -(selectedRange.rawValue - 1), to: today) ?? today
    }

    private var rangedWeights: [DailyWeight] {
        weightResolution.dailyWeights.filter { $0.date >= rangeStart && $0.date <= today }
    }

    private var rangedRawWeights: [WeightObservation] {
        weightResolution.rawObservations.filter {
            let day = calendar.startOfDay(for: $0.date)
            return day >= rangeStart && day <= today
        }
    }

    private var rangedAverages: [MovingWeightAverage] {
        analytics.movingAverages(for: weightResolution).filter { $0.date >= rangeStart && $0.date <= today }
    }

    private var segmentedAverages: [SegmentedWeightAverage] {
        var previous: Date?
        var segment = 0
        return rangedAverages.sorted { $0.date < $1.date }.map { point in
            if let previous,
               calendar.dateComponents([.day], from: previous, to: point.date).day != 1 {
                segment += 1
            }
            previous = point.date
            return SegmentedWeightAverage(point: point, segment: segment)
        }
    }

    private var rangedWeightConflicts: [WeightConflictGroup] {
        weightResolution.conflictGroups.filter {
            weightResolution.unresolvedConflictGroupIDs.contains($0.id)
                && $0.observations.contains { calendar.startOfDay(for: $0.date) >= rangeStart && calendar.startOfDay(for: $0.date) <= today }
        }
    }

    private var activityDays: [ResolvedActivityDay] {
        var dayCandidates = [String: [ResolvedActivityCandidate]]()
        let localEntries = nutrition.snapshot.activities.filter { isValid($0) }
        for source in [TrackingSource.manual, .spreadsheet] {
            let grouped = Dictionary(grouping: localEntries.filter { $0.source == source }) { nutrition.dayID(for: $0.recordedAt) }
            for (dayID, entries) in grouped {
                guard let date = entries.map(\.recordedAt).min() else { continue }
                let durations = entries.compactMap(\.durationMinutes).filter { $0.isFinite && $0 >= 0 }
                let energies = entries.compactMap(\.activeEnergy).filter { $0.isFinite && $0 >= 0 }
                let kind = Array(Set(entries.map(\.kind))).sorted().joined(separator: ", ")
                let candidate = ResolvedActivityCandidate(
                    source: source.rawValue,
                    title: source == .manual ? "Manual activity" : "Spreadsheet activity",
                    date: date,
                    durationMinutes: durations.isEmpty ? nil : durations.reduce(0, +),
                    durationObservationCount: durations.count,
                    activeEnergyKcal: energies.isEmpty ? nil : energies.reduce(0, +),
                    energyObservationCount: energies.count,
                    detail: kind.isEmpty ? "Activity" : kind,
                    recordCount: entries.count
                )
                dayCandidates[dayID, default: []].append(candidate)
            }
        }

        let dailyHealth = health.snapshot.dailyValues.filter {
            $0.metric == .exerciseMinutes || $0.metric == .activeEnergy
        }
        let healthByDay = Dictionary(grouping: dailyHealth) { nutrition.dayID(for: $0.date) }
        for (dayID, values) in healthByDay {
            let exerciseValues = values.filter { $0.metric == .exerciseMinutes && $0.value.isFinite && $0.value >= 0 }
            let energyValues = values.filter { $0.metric == .activeEnergy && $0.value.isFinite && $0.value >= 0 }
            guard !exerciseValues.isEmpty || !energyValues.isEmpty else { continue }
            let sourceNames = Set(values.flatMap(\.sourceNames)).sorted().joined(separator: ", ")
            let candidate = ResolvedActivityCandidate(
                source: "health",
                title: "Apple Health daily activity",
                date: values.map(\.date).min() ?? today,
                durationMinutes: exerciseValues.sorted { $0.date < $1.date }.last?.value,
                durationObservationCount: exerciseValues.isEmpty ? 0 : 1,
                activeEnergyKcal: energyValues.sorted { $0.date < $1.date }.last?.value,
                energyObservationCount: energyValues.isEmpty ? 0 : 1,
                detail: sourceNames.isEmpty ? "Merged daily Health statistics" : sourceNames,
                recordCount: 1
            )
            dayCandidates[dayID, default: []].append(candidate)
        }

        return dayCandidates.compactMap { dayID, candidates in
            guard let date = candidates.map(\.date).min() else { return nil }
            let sorted = candidates.sorted { $0.source < $1.source }
            let saved = nutrition.snapshot.activitySourceSelections[dayID]
            let selection = saved.flatMap { key in sorted.contains(where: { $0.source == key }) ? key : nil }
                ?? (sorted.count == 1 ? sorted.first?.source : nil)
            return ResolvedActivityDay(dayID: dayID, date: date, candidates: sorted, selection: selection)
        }.sorted { $0.date > $1.date }
    }

    private var weeklyIntakes: [DailyIntakeObservation] {
        (0..<WeeklyReviewSummary.reviewWindowDays).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -(WeeklyReviewSummary.reviewWindowDays - 1 - offset), to: today) else { return nil }
            let dayID = nutrition.dayID(for: date)
            let day = nutrition.snapshot.days.first { $0.id == dayID }
            let closedSummary = day?.summaries.last
            let bridge = TrackingBridge.nutrition(on: date, manual: nutrition.snapshot, health: health.snapshot, accountScope: history.accountScope)
            let historical = nutrition.snapshot.historicalSummaries.filter { $0.dayID == dayID }
            let historicalIsComplete: Bool = {
                guard (day == nil || day?.isClosed == true), closedSummary == nil, bridge.selection == .historical,
                      historical.count == 1, historical[0].isClosed else { return false }
                let values = historical[0].nutrients
                return values.isValid && values.energy?.isFinite == true && values.protein?.isFinite == true
            }()
            let explicitlyComplete = day?.isClosed == true && closedSummary?.completeness == .complete
            let isComplete = explicitlyComplete || historicalIsComplete
            return DailyIntakeObservation(
                date: date,
                caloriesKcal: bridge.values.energy,
                proteinGrams: bridge.values.protein,
                carbohydratesGrams: bridge.values.carbohydrates,
                fatGrams: bridge.values.fat,
                isComplete: isComplete
            )
        }
    }

    private var resolvedActivityDays: [ResolvedActivityDay] {
        let start = calendar.date(byAdding: .day, value: -13, to: today) ?? today
        return activityDays.filter { $0.date >= start && $0.date < (calendar.date(byAdding: .day, value: 1, to: today) ?? today) }
    }

    private var weeklyActivityObservations: [ActivityObservation] {
        resolvedActivityDays.compactMap { day in
            guard let selected = day.selected,
                  selected.durationMinutes != nil || selected.activeEnergyKcal != nil else { return nil }
            return ActivityObservation(
                id: "\(day.dayID)-\(selected.source)", date: day.date,
                durationMinutes: selected.durationMinutes, activeEnergyKcal: selected.activeEnergyKcal,
                source: selected.source
            )
        }
    }

    private var weeklyReview: WeeklyReviewSummary {
        analytics.weeklyReview(
            endingAt: now,
            weights: weightResolution,
            activities: weeklyActivityObservations,
            intakes: weeklyIntakes
        )
    }



    private var selectedActivitySummary: (duration: Double?, durationDays: Int, durationSamples: Int, energy: Double?, energyDays: Int, energySamples: Int, unresolvedDays: Int) {
        let selected = resolvedActivityDays.compactMap(\.selected)
        let durationDays = selected.filter { $0.durationMinutes?.isFinite == true && ($0.durationMinutes ?? -1) >= 0 }
        let energyDays = selected.filter { $0.activeEnergyKcal?.isFinite == true && ($0.activeEnergyKcal ?? -1) >= 0 }
        let durationValues = durationDays.compactMap(\.durationMinutes)
        let energyValues = energyDays.compactMap(\.activeEnergyKcal)
        return (
            durationValues.isEmpty ? nil : durationValues.reduce(0, +),
            durationDays.count,
            durationDays.reduce(0) { $0 + $1.durationObservationCount },
            energyValues.isEmpty ? nil : energyValues.reduce(0, +),
            energyDays.count,
            energyDays.reduce(0) { $0 + $1.energyObservationCount },
            resolvedActivityDays.filter(\.isUnresolved).count
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorKey = nutrition.errorKey { Section { OperationErrorView(key: errorKey) } }
                if let errorKey = health.errorKey { Section { OperationErrorView(key: errorKey) } }

                weightSection
                weightConflictSection
                activitySection
                activityConflictSection
                weeklyReviewSection
            }
            .listStyle(.insetGrouped)
            .refreshable {
                await nutrition.refresh(account: account)
                await health.refreshIfConnected()
            }
            .navigationTitle("Progress")
        }
    }

    private var weightSection: some View {
        Section {
            Picker("Range", selection: $selectedRange) {
                ForEach(ProgressWeightRange.allCases) { range in Text(LocalizedStringKey(range.title)).tag(range) }
            }
            .pickerStyle(.segmented)

            if rangedWeights.isEmpty {
                progressEmptyState(
                    title: "No weight data in this range",
                    description: "Connect Apple Health or review your saved readings.",
                    systemImage: "scalemass"
                )
            } else {
                Chart {
                    ForEach(rangedWeights) { point in
                        PointMark(x: .value("Date", point.date), y: .value("Weight", point.observation.kg))
                            .foregroundStyle(by: .value("Series", "Daily weight"))
                            .symbolSize(38)
                            .accessibilityLabel("Daily weight")
                            .accessibilityValue("\(point.observation.kg.formatted(.number.precision(.fractionLength(1)).locale(locale))) kilograms")
                    }
                    ForEach(segmentedAverages) { item in
                        LineMark(
                            x: .value("Date", item.point.date),
                            y: .value("7-day mean", item.point.averageKg),
                            series: .value("Contiguous days", item.segment)
                        )
                            .foregroundStyle(by: .value("Series", "7-day mean"))
                            .lineStyle(StrokeStyle(lineWidth: 3))
                            .interpolationMethod(.linear)
                            .accessibilityLabel("7-day moving average")
                    }
                }
                .chartForegroundStyleScale([
                    "Daily weight": Color(red: 0.18, green: 0.50, blue: 0.39),
                    "7-day mean": Color(red: 0.35, green: 0.42, blue: 0.72)
                ])
                .chartLegend(position: .bottom, alignment: .leading)
                .chartYAxisLabel("kg")
                .frame(height: 230)
                .accessibilityLabel("Daily weight and 7-day moving average")
                .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8))
            }

            LabeledContent("Weight coverage") {
                Text("\(rangedWeights.count) days · \(rangedRawWeights.count) raw readings")
            }
            LabeledContent("Unresolved matches") { Text("\(rangedWeightConflicts.count)") }
            Text("The daily point uses the latest valid reading that day. The moving average uses only available daily readings in the prior seven calendar days.")
                .font(.footnote).foregroundStyle(.secondary)

            if rangedRawWeights.isEmpty {
                Text("No saved weight readings.").foregroundStyle(.secondary)
            } else {
                ForEach(rangedRawWeights.sorted { $0.date > $1.date }) { observation in
                    weightRecordRow(observation)
                }
            }
            NavigationLink("View original Apple Health records") { HealthHistoryView() }
        } header: { Text("Weight") } footer: {
            Text("All saved measurements are read-only here.")
        }
    }

    @ViewBuilder private var weightConflictSection: some View {
        if !rangedWeightConflicts.isEmpty {
            Section {
                ForEach(rangedWeightConflicts) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Possible duplicate weight readings").font(.headline)
                        Text("Overlapping data is excluded until its source is resolved.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(group.observations) { observation in
                            Group {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(weightSourceName(for: observation.id))
                                        Text(observation.date, format: .dateTime.day().month().hour().minute())
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(observation.kg.formatted(.number.precision(.fractionLength(1)).locale(locale))) kg")
                                }
                            }
                        }

                    }
                    .padding(.vertical, 5)
                }
            } header: { Text("Overlapping sources") }
        }
    }

    private var activitySection: some View {
        Section {
            if resolvedActivityDays.isEmpty {
                progressEmptyState(
                    title: "No activity data",
                    description: "Connect Apple Health to view daily exercise and active energy.",
                    systemImage: "figure.walk"
                )
            } else {
                LabeledContent("Known duration") {
                    if let minutes = selectedActivitySummary.duration {
                        Text("\(minutes.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) min · \(selectedActivitySummary.durationSamples) records on \(selectedActivitySummary.durationDays) / 14 days")
                    } else { Text("Unknown").foregroundStyle(.secondary) }
                }
                LabeledContent("Known active energy") {
                    if let energy = selectedActivitySummary.energy {
                        Text("\(energy.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) kcal · \(selectedActivitySummary.energySamples) records on \(selectedActivitySummary.energyDays) / 14 days")
                    } else { Text("Unknown").foregroundStyle(.secondary) }
                }
                if selectedActivitySummary.unresolvedDays > 0 {
                    Text("\(selectedActivitySummary.unresolvedDays) days have unresolved overlapping activity sources.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Text("Activity is shown separately. It does not increase the food budget. Missing duration or energy stays unknown.")
                    .font(.footnote).foregroundStyle(.secondary)

                ForEach(resolvedActivityDays) { day in
                    activityDayRow(day)
                }
            }
        } header: { Text("Activity") } footer: {
            Text("Apple Health activity uses merged daily exercise minutes and active-energy statistics. Individual workouts are not added again.")
        }
    }

    private func progressEmptyState(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder private var activityConflictSection: some View {
        let conflicts = resolvedActivityDays.filter(\.isUnresolved)
        if !conflicts.isEmpty {
            Section("Overlapping activity sources") {
                ForEach(conflicts) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(day.date, format: .dateTime.weekday(.wide).day().month().year()).font(.headline)
                        Text("Overlapping data is excluded until its source is resolved.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(day.candidates) { candidate in
                            Group {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.title)
                                        Text(verbatim: candidate.detail).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(activityCandidateValue(candidate)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }

    private var weeklyReviewSection: some View {
        Section {
            Text(weeklyReview.startDate, format: .dateTime.day().month())
                + Text(" – ")
                + Text(weeklyReview.endDate, format: .dateTime.day().month().year())

            LabeledContent("Complete nutrition days") {
                Text("\(weeklyReview.completeNutritionDays) / 14")
            }
            LabeledContent("Incomplete nutrition days") {
                Text("\(weeklyReview.incompleteNutritionDays) / 14")
            }
            nutrientReviewRow(title: "Average calories", average: weeklyReview.averageCaloriesKcalPerObservedDay, unit: "kcal/day", coverage: weeklyReview.caloriesCoverageDays)
            nutrientReviewRow(title: "Average protein", average: weeklyReview.averageProteinGramsPerObservedDay, unit: "g/day", coverage: weeklyReview.proteinCoverageDays)

            LabeledContent("Weight days") {
                Text("\(weeklyReview.weightDayCount) / 14 · \(weeklyReview.firstWeekWeightDayCount) + \(weeklyReview.secondWeekWeightDayCount) by week")
            }
            LabeledContent("Mean observed weight") {
                if let kg = weeklyReview.meanWeightKg { Text("\(kg.formatted(.number.precision(.fractionLength(1)).locale(locale))) kg") }
                else { Text("Unknown").foregroundStyle(.secondary) }
            }
            LabeledContent("Unresolved weight matches") { Text("\(weeklyReview.unresolvedWeightConflictCount)") }

            Text("A goal review needs at least 10 of 14 complete nutrition days and 6 weight days, with at least 3 weight days in each 7-day week.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("These are summaries of recorded observations. They do not explain why weight changed. Unknown values remain missing, and activity is separate from food intake.")
                .font(.footnote).foregroundStyle(.secondary)

            if weeklyReview.isEligibleForGoalReview {
                Text("There is enough recorded coverage to review your goals. No goal change is proposed automatically.")
                    .font(.subheadline)
            } else {
                Label("More complete records are needed before a goal review.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("14-day review") } footer: {
            Text("Complete days come from explicit completed day closures. A historical spreadsheet day counts only when it was closed and has valid calorie and protein totals. Apple Health totals alone never mark a day complete.")
        }
    }

    private func nutrientReviewRow(title: LocalizedStringKey, average: Double?, unit: String, coverage: Int) -> some View {
        LabeledContent(title) {
            if let average {
                Text("\(average.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) \(unit) · \(coverage) days")
            } else { Text("Unknown · 0 days").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func weightRecordRow(_ observation: WeightObservation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(observation.kg.formatted(.number.precision(.fractionLength(1)).locale(locale))) kg").font(.headline)
                    Text(weightSourceName(for: observation.id)).font(.caption).foregroundStyle(.secondary)
                }
                Text(observation.date, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                if case let .health(record)? = weightReferences[observation.id] {
                    Text(verbatim: record.sourceBundleIdentifier).font(.caption2).foregroundStyle(.tertiary)
                    if let deviceName = record.deviceName { Text(verbatim: deviceName).font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Read-only record")
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func activityDayRow(_ day: ResolvedActivityDay) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.date, format: .dateTime.weekday(.abbreviated).day().month())
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if day.isUnresolved { Text("Overlapping sources").font(.caption).foregroundStyle(.orange) }
                else if let selected = day.selected { Text(selected.title).font(.caption).foregroundStyle(.secondary) }
            }
            if day.isUnresolved {
                Text("Overlapping data is excluded until its source is resolved.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let selected = day.selected {
                HStack(spacing: 12) {
                    if let duration = selected.durationMinutes {
                        Label("\(duration.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) min", systemImage: "clock")
                    } else { Label("Duration unknown", systemImage: "clock") }
                    if let energy = selected.activeEnergyKcal {
                        Label("\(energy.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) kcal", systemImage: "flame")
                    } else { Label("Energy unknown", systemImage: "flame") }
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(selected.detail).font(.caption2).foregroundStyle(.tertiary)
            }
            let localRecords = nutrition.snapshot.activities.filter { nutrition.dayID(for: $0.recordedAt) == day.dayID }
            ForEach(localRecords) { entry in activityRecordRow(entry) }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder private func activityRecordRow(_ entry: ManualActivityEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(verbatim: entry.kind).font(.subheadline)
                    Text(entry.source == .manual ? "Manual" : "Spreadsheet").font(.caption).foregroundStyle(.secondary)
                }
                Text(entry.recordedAt, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if let minutes = entry.durationMinutes { Text("\(minutes.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) min") }
                    else { Text("Duration unknown") }
                    if let energy = entry.activeEnergy { Text("\(energy.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) kcal") }
                    else { Text("Active energy unknown") }
                }.font(.caption2).foregroundStyle(.secondary)
                if !entry.notes.isEmpty {
                    Text(verbatim: entry.notes).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer()
            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Read-only record")
        }
        .padding(.leading, 8).padding(.top, 4)
    }



    private func activityCandidateValue(_ candidate: ResolvedActivityCandidate) -> String {
        var values = [String]()
        if let minutes = candidate.durationMinutes { values.append("\(minutes.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) min") }
        if let energy = candidate.activeEnergyKcal { values.append("\(energy.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) kcal") }
        return values.isEmpty ? "No measured totals" : values.joined(separator: " · ")
    }

    private func weightSourceName(for id: String) -> String {
        guard let reference = weightReferences[id] else { return "Imported" }
        return switch reference {
        case let .local(value): value.source == .manual ? "Manual" : "Spreadsheet"
        case let .health(value): value.sourceName
        }
    }

    private func weightID(_ entry: ManualWeightEntry) -> String { "\(entry.source.rawValue)-\(entry.id.uuidString)" }
    private func healthWeightID(_ record: HealthSampleRecord) -> String { "health-\(record.id.uuidString)" }
    private func healthSourceKey(_ record: HealthSampleRecord) -> String {
        let sourceID = record.sourceBundleIdentifier.isEmpty ? record.sourceName : record.sourceBundleIdentifier
        return "health:\(sourceID)"
    }

    private func isValid(_ value: ManualActivityEntry) -> Bool {
        (value.durationMinutes.map { $0.isFinite && $0 >= 0 } ?? true)
            && (value.activeEnergy.map { $0.isFinite && $0 >= 0 } ?? true)
    }

}

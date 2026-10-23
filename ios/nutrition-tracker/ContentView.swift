import SwiftUI

private enum HomeStyle {
    static let green = Color("NutritionGreen")
    static let buttonGreen = Color(red: 0.16, green: 0.45, blue: 0.35)
    static let protein = Color(red: 0.20, green: 0.52, blue: 0.61)
    static let carbs = Color(red: 0.72, green: 0.48, blue: 0.20)
    static let fat = Color(red: 0.56, green: 0.43, blue: 0.68)
}

struct ContentView: View {
    var refreshOnActivation = true
    @Environment(HealthWeightUpload.self) private var weights
    @Environment(AccountSession.self) private var account
    @Environment(HealthSyncModel.self) private var model
    @Environment(NutritionStore.self) private var nutrition
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var selectedDate = Date.now

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView(selectedDate: $selectedDate).tabItem { Label("Today", systemImage: "circle.grid.2x2.fill") }.tag(0)
            TrackingProgressView().tabItem { Label("Progress", systemImage: "chart.xyaxis.line") }.tag(1)
        }
        .tint(HomeStyle.green)
        .environment(\.timeZone, nutrition.snapshot.profile.calendar.timeZone)
        .task { await model.refreshIfConnected() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && refreshOnActivation { Task {
                await model.refreshIfConnected()
                await weights.sync(account: account, health: model)
                await nutrition.refresh(account: account)
            } }
        }
    }
}

private struct TodayView: View {
    @Environment(NutritionStore.self) private var nutrition
    @Environment(\.locale) private var locale
    @State private var showHealth = false
    @State private var showSettings = false
    @State private var referenceDate = Date.now
    @State private var firstDayOffset = -365
    @State private var visibleDay: Int? = 0
    @Binding var selectedDate: Date

    private var calendar: Calendar { nutrition.snapshot.profile.calendar }
    private var referenceDay: Date { calendar.startOfDay(for: referenceDate) }
    private var todayOffset: Int { offset(for: .now) }
    private var title: String {
        if calendar.isDate(selectedDate, inSameDayAs: .now) { return String(localized: "Today", locale: locale) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: .now), calendar.isDate(selectedDate, inSameDayAs: yesterday) {
            return String(localized: "Yesterday", locale: locale)
        }
        var format = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(locale)
        format.timeZone = calendar.timeZone
        if calendar.component(.year, from: selectedDate) != calendar.component(.year, from: .now) {
            format = format.year()
        }
        return selectedDate.formatted(format)
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(selectedDate, format: .dateTime.weekday(.wide).day().month(.wide).locale(locale))
                            .font(.subheadline).foregroundStyle(.secondary)
                        SelectedDayPicker(selection: Binding(
                            get: { selectedDate },
                            set: { selectedDate = min($0, Date.now) }
                        )).accessibilityIdentifier("today.selectedDay")
                    }
                    .padding(.horizontal, 20).padding(.top, 4)
                    .frame(maxWidth: 600).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("today.dayHeader")

                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(firstDayOffset...todayOffset, id: \.self) { dayOffset in
                                if let date = calendar.date(byAdding: .day, value: dayOffset, to: referenceDay) {
                                    DailyNutritionView(showHealth: $showHealth, selectedDate: date)
                                        .containerRelativeFrame(.horizontal)
                                        .id(dayOffset)
                                        .accessibilityHidden(visibleDay != dayOffset)
                                }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .defaultScrollAnchor(.trailing)
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $visibleDay)
                    .accessibilityIdentifier("today.dayPages")
                    .onScrollPhaseChange { _, phase in
                        if phase == .idle, let day = visibleDay, day <= firstDayOffset + 7 {
                            firstDayOffset -= 365
                        }
                    }
                }
                .background(Color(uiColor: .systemGroupedBackground))
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Settings").accessibilityIdentifier("tracking.settings")
            } }
            .sheet(isPresented: $showHealth) { HealthConnectionView() }
            .sheet(isPresented: $showSettings) { AppSettingsView() }
            .onAppear { selectDay(selectedDate, animated: false) }
            .onChange(of: visibleDay) { _, dayOffset in
                guard let dayOffset, let date = calendar.date(byAdding: .day, value: dayOffset, to: referenceDay),
                      !calendar.isDate(date, inSameDayAs: selectedDate) else { return }
                selectedDate = date
            }
            .onChange(of: selectedDate) { _, date in selectDay(date, animated: true) }
            .onChange(of: nutrition.snapshot.profile.timeZoneIdentifier) { _, _ in selectDay(selectedDate, animated: false) }
        }
    }

    private func offset(for date: Date) -> Int {
        calendar.dateComponents([.day], from: referenceDay, to: calendar.startOfDay(for: date)).day ?? 0
    }

    private func selectDay(_ date: Date, animated: Bool) {
        let day = min(offset(for: date), todayOffset)
        if day < firstDayOffset { firstDayOffset = day - 365 }
        guard visibleDay != day else { return }
        withAnimation(animated ? .snappy : nil) { visibleDay = day }
    }
}

private struct DailyNutritionView: View {
    @Environment(HealthWeightUpload.self) private var weights
    @Environment(AccountSession.self) private var account
    @Environment(HealthSyncModel.self) private var model
    @Environment(NutritionStore.self) private var nutrition
    @Environment(\.legacyHistory) private var history
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var ringSize = 138
    @Binding var showHealth: Bool
    let selectedDate: Date
    private var resolved: ResolvedDailyNutrition { TrackingBridge.nutrition(on: selectedDate, manual: nutrition.snapshot, health: model.snapshot, accountScope: history.accountScope) }
    private var dailyGoals: NutritionGoals? {
        if history.ownerID == nil && nutrition.snapshot.goals.isEmpty { return model.snapshot.goals }
        return nutrition.goals(on: selectedDate)
    }
    private var consumed: Double? { resolved.values.energy }
    private var goal: Double? { dailyGoals?.energy }
    private var dayID: String { nutrition.snapshot.profile.dayID(for: selectedDate) }
    private var fraction: Double {
        guard let consumed, let goal, goal > 0 else { return 0 }
        return min(max(consumed / goal, 0), 1)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                dayStatus
                if let error = nutrition.errorKey { OperationErrorView(key: error) }
                if let key = model.errorKey {
                    OperationErrorView(key: key)
                    if model.storageNeedsRecovery { Button("Retry reading local data") { model.reload() } }
                }
                nutritionCard
                if resolved.hasConflict || resolved.candidates.count > 1 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Nutrition sources").font(.headline)
                        Text("Overlapping sources are never added together.").font(.footnote).foregroundStyle(.secondary)
                        if resolved.hasConflict {
                            Text("Overlapping data is excluded until its source is resolved.").font(.footnote).foregroundStyle(.orange)
                        }
                        ForEach(resolved.candidates, id: \.self) { source in
                            Label(LocalizedStringKey(source.titleKey), systemImage: resolved.selection == source ? "checkmark.circle.fill" : "circle")
                        }
                    }.padding(20).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                }
                if !model.snapshot.isConnected && model.snapshot.lastSyncDate == nil {
                    Button { showHealth = true } label: {
                        Label("Connect Apple Health", systemImage: "heart")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).tint(HomeStyle.buttonGreen).controlSize(.large)
                    .disabled(model.isWorking || model.storageNeedsRecovery)
                }
                if model.snapshot.configuration != nil {
                    if !model.snapshot.isConnected { healthCard }
                    activityCard
                }
                mealsSection
            }
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 24)
            .frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .refreshable {
            await model.refreshIfConnected()
            await weights.sync(account: account, health: model)
            await nutrition.refresh(account: account)
        }
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("today.day.\(dayID)")
    }

    private var dayStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if nutrition.isRefreshing {
                HStack { ProgressView(); Text("Syncing diary…").font(.caption) }
            }
            if model.isWorking {
                HStack { ProgressView(); Text("Syncing Apple Health…").font(.caption) }
            } else if let selection = resolved.selection {
                Text(LocalizedStringKey(selection.titleKey)).font(.caption).foregroundStyle(.secondary)
            } else if !model.snapshot.isConnected && model.snapshot.lastSyncDate == nil {
                Text("Connect Health to start with your real data.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var nutritionCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Daily nutrition").font(.subheadline.weight(.semibold))
                    percentageBadge
                }
            } else {
                HStack {
                    Label("Daily nutrition", systemImage: "leaf").font(.subheadline.weight(.semibold))
                    Spacer()
                    percentageBadge
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 28) { calorieRing; calorieSummary; Spacer(minLength: 0) }
                VStack(spacing: 20) { calorieRing; calorieSummary }.frame(maxWidth: .infinity)
            }
            Divider()
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 20) { macros }
            } else {
                HStack(alignment: .top, spacing: 20) { macros }
            }
            if let saturated = resolved.values.saturatedFat {
                HStack { Text("Saturated fat"); Spacer(); Text("\(saturated.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) g") }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let fiber = resolved.values.fiber {
                HStack { Text("Fiber"); Spacer(); Text("\(fiber.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) g") }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if consumed == nil { Text("Missing data is not zero intake.").font(.footnote).foregroundStyle(.secondary) }
            if resolved.hasMissingNutrients && consumed != nil { Text("Partial totals · some nutrients are unknown.").font(.footnote).foregroundStyle(.orange) }
        }
        .padding(22)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
    }

    @ViewBuilder private var percentageBadge: some View {
        if let consumed, let goal, goal > 0 {
            Text(consumed / goal, format: .percent.precision(.fractionLength(0)))
                .font(.caption.weight(.semibold)).foregroundStyle(HomeStyle.green)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(HomeStyle.green.opacity(0.09), in: Capsule())
        }
    }

    private var calorieRing: some View {
        ZStack {
            Circle().stroke(HomeStyle.green.opacity(0.10), lineWidth: 10)
            Circle().trim(from: 0, to: fraction)
                .stroke(HomeStyle.green, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                amount(consumed).font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(consumed == nil ? "No data available" : "kcal consumed").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 8)
        }
        .frame(width: min(ringSize, 220), height: min(ringSize, 220)).padding(5)
        .accessibilityElement(children: .ignore).accessibilityLabel("Calories consumed")
        .accessibilityValue(consumed.map { Text($0, format: .number) } ?? Text("No data available"))
        .accessibilityIdentifier("today.energy")
    }

    private var calorieSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let goal {
                if let consumed {
                    amount(abs(goal - consumed)).font(.system(.largeTitle, design: .rounded, weight: .bold)).foregroundStyle(HomeStyle.green)
                    Text(consumed > goal ? "kcal above goal" : "kcal remaining").font(.subheadline).foregroundStyle(.secondary)
                } else { Text("No data available").font(.subheadline).foregroundStyle(.secondary) }
                Text("Daily goal").font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                Text("\(goal.formatted(.number.precision(.fractionLength(0)).locale(locale))) kcal").font(.subheadline.weight(.semibold))
            } else {
                Text("Your daily goals").font(.subheadline.weight(.semibold))
                Text("No goal set").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
    }

    @ViewBuilder private var macros: some View {
        macro("Protein", metric: .protein, target: dailyGoals?.protein, color: HomeStyle.protein)
        macro("Carbs", metric: .carbohydrates, target: dailyGoals?.carbohydrates, color: HomeStyle.carbs)
        macro("Fat", metric: .fat, target: dailyGoals?.fat, color: HomeStyle.fat)
    }

    private func macro(_ title: LocalizedStringKey, metric: HealthMetric, target: Double?, color: Color) -> some View {
        let value = metric == .protein ? resolved.values.protein : metric == .carbohydrates ? resolved.values.carbohydrates : resolved.values.fat
        return VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                amount(value, decimalPlaces: 1).font(.system(.title3, design: .rounded, weight: .bold))
                Text("g").font(.caption).foregroundStyle(.secondary)
            }
            if let target, target > 0 {
                ProgressView(value: min(max(value ?? 0, 0), target), total: target).tint(color)
                    .accessibilityLabel(Text(title))
                    .accessibilityValue(value.map { Text($0, format: .number) } ?? Text("No data available"))
                Text("of \(target.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) g").font(.caption2).foregroundStyle(.secondary)
            } else { Text("No goal set").font(.caption2).foregroundStyle(.secondary) }
        }.frame(minWidth: 76, maxWidth: .infinity, alignment: .leading)
    }

    private var healthCard: some View {
        Button { showHealth = true } label: {
            HStack(spacing: 13) {
                Image(systemName: "heart.fill").font(.title3).foregroundStyle(.pink)
                    .frame(width: 44, height: 44).background(Color.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple Health").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(model.snapshot.isConnected ? "Read access configured" : "Local copy · syncing off").font(.caption).foregroundStyle(.secondary)
                    if let date = model.snapshot.lastSyncDate { Text(date, format: .dateTime.day().month().hour().minute()).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain).disabled(model.isWorking)
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Activity and weight").font(.title3.weight(.bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 300 : 130), alignment: .leading)], alignment: .leading, spacing: 18) {
                activityValue("Steps", value: model.snapshot.value(for: .steps, on: selectedDate), unit: "", symbol: "figure.walk")
                activityValue("Active energy", value: model.snapshot.value(for: .activeEnergy, on: selectedDate), unit: "kcal", symbol: "flame")
                activityValue("Resting energy", value: model.snapshot.value(for: .restingEnergy, on: selectedDate), unit: "kcal", symbol: "bed.double")
                activityValue("Exercise time", value: model.snapshot.value(for: .exerciseMinutes, on: selectedDate), unit: "min", symbol: "figure.run")
                let end = nutrition.snapshot.profile.calendar.date(byAdding: .day, value: 1, to: nutrition.snapshot.profile.calendar.startOfDay(for: selectedDate)) ?? selectedDate
                let weight = model.snapshot.latestWeight(before: end)
                VStack(alignment: .leading, spacing: 4) {
                    activityValue("Latest weight", value: weight?.value, unit: "kg", symbol: "scalemass", decimals: 1)
                    if let weight { Text(weight.endDate, format: .dateTime.day().month()).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Text("Activity does not increase your food budget.").font(.footnote).foregroundStyle(.secondary)
        }.padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    private func activityValue(_ title: LocalizedStringKey, value: Double?, unit: String, symbol: String, decimals: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                amount(value, decimalPlaces: decimals).font(.title3.weight(.semibold))
                Text(verbatim: unit).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var mealsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your meals").font(.title3.weight(.bold))
            let entries = nutrition.entries(on: selectedDate).reversed()
            if entries.isEmpty {
                ContentUnavailableView("No meals recorded", systemImage: "fork.knife", description: Text("Daily summaries and Apple Health totals do not create meal records."))
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(verbatim: entry.draft.name).font(.headline); Spacer(); Text(entry.draft.amount, format: .number); Text(LocalizedStringKey(entry.draft.unit.titleKey)).font(.caption) }
                    HStack { Text(verbatim: entry.draft.mealName); Text(LocalizedStringKey(entry.draft.preparation.titleKey)); Text(LocalizedStringKey(entry.draft.source.titleKey)) }.font(.caption).foregroundStyle(.secondary)
                    FoodMacroRows(values: entry.values).font(.caption)
                }.padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }



    @ViewBuilder private func amount(_ value: Double?, decimalPlaces: Int = 0) -> some View {
        if let value { Text(value, format: .number.precision(.fractionLength(0...decimalPlaces))) }
        else { Text(verbatim: "—").accessibilityLabel("No data available") }
    }
}

#Preview("Today · empty") {
    ContentView().environment(HealthSyncModel(persistence: HealthFileRepository(fileURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))))
        .environment(AccountSession(enabled: false))
        .environment(HealthWeightUpload())
        .environment(NutritionStore()).environment(\.legacyHistory, LegacyHistory(ownerID: nil))
        .environment(\.locale, Locale(identifier: "es_UY"))
}

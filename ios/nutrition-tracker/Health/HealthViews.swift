import SwiftUI

struct HealthConnectionView: View {
    @Environment(HealthSyncModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set(HealthMetric.allCases)
    @State private var range = ImportRange.ninetyDays
    @State private var startDate = Date.now.addingTimeInterval(-90 * 86_400)

    private enum ImportRange: String, CaseIterable, Identifiable {
        case thirtyDays, ninetyDays, year, all, custom
        var id: String { rawValue }
        var key: String {
            switch self {
            case .thirtyDays: "Last 30 days"
            case .ninetyDays: "Last 90 days"
            case .year: "Last year"
            case .all: "All available history"
            case .custom: "Custom start date"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let staged = model.stagedImport {
                    importReview(staged)
                } else {
                    Section {
                        Text("Choose which data to read from Apple Health. Nothing is sent to a server or AI.")
                    }
                    Section("Data types") {
                        ForEach(HealthMetric.allCases) { metric in
                            Toggle(isOn: Binding(get: { selected.contains(metric) }, set: { enabled in
                                if enabled { selected.insert(metric) } else { selected.remove(metric) }
                            })) { Text(LocalizedStringKey(metric.titleKey)) }
                        }
                    }
                    Section("History") {
                        Picker("Import range", selection: $range) {
                            ForEach(ImportRange.allCases) { Text(LocalizedStringKey($0.key)).tag($0) }
                        }
                        if range == .custom {
                            DatePicker("From", selection: $startDate, in: ...Date.now, displayedComponents: .date)
                        }
                    }
                    Section {
                        Text("Read-only access. You choose permissions in Apple's Health dialog. Your original Health data stays unchanged.")
                        Text("No available data can mean no records or no read access. The app cannot distinguish those cases.")
                        Text("Saved historical Health summaries stay on this device when you change the import selection. Delete the local Health copy to erase them.")
                    }
                    if !model.isAvailable {
                        Section { Text("Apple Health is not available on this device.") }
                    }
                }
                if model.isWorking {
                    Section {
                        ProgressView()
                        if let metric = model.readingMetric {
                            Text(LocalizedStringKey(metric.titleKey))
                        }
                        Text("\(model.readCount) records read")
                    }
                }
                if let key = model.errorKey { Section { OperationErrorView(key: key) } }
            }
            .disabled(model.isWorking)
            .navigationTitle(model.stagedImport == nil ? "Connect Apple Health" : "Review import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.discardImport(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.stagedImport != nil {
                        Button("Import") {
                            model.confirmImport()
                            if model.stagedImport == nil { dismiss() }
                        }
                        .disabled(model.isWorking || model.storageNeedsRecovery)
                    } else {
                        Button("Continue") {
                            let calendar = model.snapshot.configuration?.calendar ?? Self.profileCalendar
                            let date: Date?
                            switch range {
                            case .all: date = nil
                            case .custom: date = calendar.startOfDay(for: startDate)
                            case .thirtyDays: date = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: .now))
                            case .ninetyDays: date = calendar.date(byAdding: .day, value: -90, to: calendar.startOfDay(for: .now))
                            case .year: date = calendar.date(byAdding: .year, value: -1, to: calendar.startOfDay(for: .now))
                            }
                            let configuration = HealthImportConfiguration(metrics: selected, startDate: date, timeZoneIdentifier: calendar.timeZone.identifier)
                            Task { await model.prepareImport(configuration: configuration) }
                        }
                        .disabled(selected.isEmpty || model.isWorking || !model.isAvailable || model.storageNeedsRecovery)
                    }
                }
            }
            .interactiveDismissDisabled(model.isWorking)
            .onAppear {
                if let configuration = model.snapshot.configuration {
                    selected = configuration.metrics
                    if let date = configuration.startDate { startDate = date; range = .custom } else { range = .all }
                }
            }
            .onDisappear { if !model.isWorking { model.discardImport() } }
        }
    }

    private static var profileCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Montevideo")!
        return calendar
    }

    @ViewBuilder private func importReview(_ staged: StagedHealthImport) -> some View {
        Section("Available history") {
            LabeledContent("Records") { Text(staged.snapshot.samples.count, format: .number) }
            if let first = staged.snapshot.samples.map(\.startDate).min(), let last = staged.snapshot.samples.map(\.endDate).max() {
                LabeledContent("From") { Text(first, format: .dateTime.day().month().year()) }
                LabeledContent("To") { Text(last, format: .dateTime.day().month().year()) }
            } else {
                Text("No data available")
                Text("Check access in the Health app and whether records exist for this range.")
            }
        }
        Section("By data type") {
            ForEach(HealthMetric.allCases.filter { staged.snapshot.configuration?.metrics.contains($0) == true }) { metric in
                LabeledContent { Text(staged.snapshot.samples.filter { $0.metric == metric }.count, format: .number) }
                label: { Text(LocalizedStringKey(metric.titleKey)) }
            }
        }
        let sources = Array(Set(staged.snapshot.samples.map(\.sourceName))).sorted()
        if !sources.isEmpty {
            Section("Sources") { ForEach(sources, id: \.self) { Text(verbatim: $0) } }
        }
        Section {
            Text("Health nutrition is imported as nutrients, without inventing meals. Active energy does not increase your food budget.")
            if model.snapshot.configuration != nil {
                Text("Confirming replaces the previous local Health copy with this selection. Your daily goals are kept.")
                Text("Saved historical Health summaries are preserved separately on this device.")
            }
            Text("Only confirm when you are ready to save this copy on your device.")
        }
        Section { Button("Change selection") { model.discardImport() } }
    }
}

struct OperationErrorView: View {
    let key: String
    var body: some View {
        Label { Text(LocalizedStringKey(key)) } icon: { Image(systemName: "exclamationmark.triangle") }
            .font(.footnote)
            .foregroundStyle(.orange)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

struct HealthHistoryView: View {
    @Environment(HealthSyncModel.self) private var model
    @State private var metric = HealthMetric.weight
    @State private var limit = 100
    @State private var showConnection = false
    private var records: [HealthSampleRecord] {
        model.snapshot.samples.filter { $0.metric == metric }.sorted { $0.startDate > $1.startDate }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Data type", selection: $metric) {
                        ForEach(HealthMetric.allCases) { Text(LocalizedStringKey($0.titleKey)).tag($0) }
                    }
                    if let date = model.snapshot.lastSyncDate {
                        LabeledContent("Last sync") { Text(date, format: .dateTime.day().month().hour().minute()) }
                    }
                }
                if records.isEmpty {
                    Section {
                        ContentUnavailableView("No data available", systemImage: "heart.text.square", description: Text("Connect Apple Health or check access and the selected range."))
                    }
                } else {
                    Section {
                        ForEach(Array(records.prefix(limit))) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(record.value, format: .number.precision(.fractionLength(0...2)))
                                        .font(.headline)
                                    Text(verbatim: metric.unit).font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(record.startDate, format: .dateTime.day().month().year().hour().minute()).font(.caption)
                                }
                                Text(verbatim: record.sourceName).font(.caption).foregroundStyle(.secondary)
                                if let device = record.deviceName { Text(verbatim: device).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        if records.count > limit { Button("Load more") { limit += 100 } }
                    } header: { Text("Apple Health records") } footer: {
                        Text("Original observations, not summed totals. Multiple sources can overlap; daily activity uses HealthKit's merged statistics.")
                    }
                }
                if let key = model.errorKey { Section { OperationErrorView(key: key) } }
            }
            .navigationTitle("Progress")
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { showConnection = true } label: { Image(systemName: "heart") }.accessibilityLabel("Apple Health")
            } }
            .sheet(isPresented: $showConnection) { HealthConnectionView() }
            .refreshable { await model.refreshIfConnected() }
            .onChange(of: metric) { _, _ in limit = 100 }
        }
    }
}

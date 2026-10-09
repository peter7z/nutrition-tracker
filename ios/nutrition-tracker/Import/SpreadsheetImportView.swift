import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

struct SpreadsheetImportView: View {
    @Environment(NutritionStore.self) private var store
    @Environment(HealthSyncModel.self) private var health
    @State private var showFile = false
    @State private var tables: [WorkbookTable] = []
    @State private var selectedSheet = 0
    @State private var comparisonSheet = -1
    @State private var headerRow = 1
    @State private var mapping = SpreadsheetColumnMapping()
    @State private var fileName = ""
    @State private var fileHash = ""
    @State private var excludedRows = Set<Int>()
    @State private var choices: [String: IntakeSelection] = [:]
    @State private var errorKey: String?
    @State private var imported = false
    @State private var isReading = false
    private var table: WorkbookTable? { tables.indices.contains(selectedSheet) ? tables[selectedSheet] : nil }
    private var headers: [String] { guard let table, table.rows.indices.contains(headerRow - 1) else { return [] }; return table.rows[headerRow - 1] }
    private var preview: SpreadsheetPreview? { table.map { SpreadsheetPreviewBuilder.build(table: $0, mapping: mapping, timeZone: store.snapshot.profile.calendar.timeZone, headerRowNumber: headerRow) } }
    private var included: [SpreadsheetRow] { preview?.rows.enumerated().filter { !excludedRows.contains($0.offset) }.map(\.element) ?? [] }
    private var conflicts: Set<String> {
        Set(included.compactMap { row -> String? in
            guard let date = row.date else { return nil }
            let day = store.dayID(for: date)
            return !store.entries(on: date).isEmpty || health.snapshot.value(for: .dietaryEnergy, on: date) != nil ? day : nil
        })
    }
    var body: some View {
        Form {
            Section {
                Text("Choose your XLSX or CSV file. This import reads the selected file and never edits it.")
                Button("Choose spreadsheet") { showFile = true }.disabled(isReading)
                if isReading { ProgressView("Reading spreadsheet…") }
                if !fileName.isEmpty { Text(verbatim: fileName).font(.caption) }
            }
            if table != nil {
                Section("Sheets and columns") {
                    Picker("Import sheet", selection: $selectedSheet) { ForEach(tables.indices, id: \.self) { Text(verbatim: tables[$0].name).tag($0) } }
                    Stepper("Header row: \(headerRow)", value: $headerRow, in: 1...max(table?.rows.count ?? 1, 1))
                    column("Date", $mapping.date); column("Energy (kcal)", $mapping.calories)
                    column("Protein (g)", $mapping.protein); column("Weight (kg)", $mapping.weight)
                    column("Active energy (kcal)", $mapping.activeEnergy); column("Exercise time (min)", $mapping.activityMinutes)
                    column("Notes", $mapping.notes); column("Closed day", $mapping.closed)
                    column("Carbs (g)", $mapping.carbohydrates); column("Fat (g)", $mapping.fat)
                    Picker("Compare with summary sheet", selection: $comparisonSheet) {
                        Text("None").tag(-1)
                        ForEach(tables.indices.filter { $0 != selectedSheet }, id: \.self) { Text(verbatim: tables[$0].name).tag($0) }
                    }
                    Text("Check both the daily log and summary mappings. Historical totals are saved as summaries, without inventing meals.").font(.footnote).foregroundStyle(.secondary)
                }
                if let preview {
                    Section("Import preview") {
                        Text("\(preview.rows.count) rows found")
                        Text("\(preview.skippedFutureEmptyRows.count) empty future rows skipped")
                        if !preview.unmappedHeaders.isEmpty { Text("Map the required date column and check column names.").foregroundStyle(.orange) }
                        ForEach(Array(preview.rows.enumerated()), id: \.offset) { index, row in
                            DisclosureGroup {
                                NutrientValuesRows(values: row.nutrients)
                                if let weight = row.weight { LabeledContent("Weight") { Text("\(weight.formatted()) kg") } }
                                if !row.notes.isEmpty { Text(verbatim: row.notes) }
                                Text(verbatim: row.originalRow).font(.caption2)
                                if !row.issues.isEmpty { Text("This row has missing or conflicting values. Correct the source mapping or exclude it before importing.").foregroundStyle(.orange) }
                                Toggle("Include this row", isOn: Binding(get: { !excludedRows.contains(index) }, set: { include in if include { excludedRows.remove(index) } else { excludedRows.insert(index) } }))
                                Text(row.isClosed == true ? "Day closed" : "Day not marked closed").font(.caption)
                            } label: {
                                HStack {
                                    if let date = row.date { Text(date, format: .dateTime.day().month().year()) } else { Text("Invalid date") }
                                    Spacer()
                                    if excludedRows.contains(index) { Image(systemName: "minus.circle") }
                                    else if !row.issues.isEmpty { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                                }
                            }
                        }
                    }
                }
                if comparisonSheet >= 0, tables.indices.contains(comparisonSheet) {
                    Section("Comparison report") {
                        let secondary = tables[comparisonSheet]
                        Text(verbatim: secondary.name).font(.caption)
                        let secondaryMapping = Self.autoMapping(secondary.rows.first ?? [])
                        let report = SpreadsheetPreviewBuilder.build(table: secondary, mapping: secondaryMapping, timeZone: store.snapshot.profile.calendar.timeZone)
                        Text("\(report.rows.count) summary rows")
                        ForEach(Array(included.enumerated()), id: \.offset) { _, row in
                            if let date = row.date {
                                let matching = report.rows.first { $0.date.map { store.snapshot.profile.calendar.isDate($0, inSameDayAs: date) } == true }
                                HStack {
                                    Text(date, format: .dateTime.day().month())
                                    Spacer()
                                    if let matching { Text(matching.nutrients == row.nutrients ? "Matches" : "Divergence · review source").foregroundStyle(matching.nutrients == row.nutrients ? Color.secondary : .orange) }
                                    else { Text("Missing in summary").foregroundStyle(.orange) }
                                }.font(.caption)
                            }
                        }
                        Text("Differences are shown for review. The selected daily sheet supplies the imported values.").font(.footnote)
                    }
                }
                if !conflicts.isEmpty {
                    Section("Overlapping days") {
                        Text("Choose one nutrition source for each overlap. Totals from different sources are never added.")
                        ForEach(conflicts.sorted(), id: \.self) { day in
                            Picker(selection: Binding(get: { choices[day]?.rawValue ?? "" }, set: { choices[day] = IntakeSelection(rawValue: $0) })) {
                                Text("Choose a source").tag("")
                                Text("Recorded meals").tag(IntakeSelection.manual.rawValue)
                                Text("Spreadsheet summary").tag(IntakeSelection.historical.rawValue)
                                Text("Apple Health").tag(IntakeSelection.health.rawValue)
                            } label: { Text(verbatim: day) }
                        }
                    }
                }
                Section {
                    Button("Confirm import") { confirmImport() }
                        .disabled(imported || included.isEmpty || included.contains { $0.date == nil || !$0.issues.isEmpty } || mapping.date == nil || conflicts.contains { choices[$0] == nil })
                    if imported { Label("Import saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
            }
            if let errorKey { Section { OperationErrorView(key: errorKey) } }
        }
        .navigationTitle("Import spreadsheet").navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedSheet) { _, _ in resetMapping() }
        .onChange(of: headerRow) { _, _ in resetMapping() }
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.commaSeparatedText, UTType(filenameExtension: "xlsx") ?? .data]) { result in
            Task { @MainActor in
                isReading = true; defer { isReading = false }
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= SpreadsheetReader.maximumFileBytes else { throw SpreadsheetReadError.fileTooLarge }
                    let data = try Data(contentsOf: url)
                    tables = try SpreadsheetReader.read(data: data, fileExtension: url.pathExtension)
                    guard !tables.isEmpty else { throw NutritionError.invalidData }
                    fileName = url.lastPathComponent; fileHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    selectedSheet = tables.firstIndex { SpreadsheetReader.normalizedHeader($0.name).contains("registro") } ?? 0
                    comparisonSheet = tables.firstIndex { SpreadsheetReader.normalizedHeader($0.name).contains("resumen") && $0.name != tables[selectedSheet].name } ?? -1
                    headerRow = 1; imported = false; resetMapping(); errorKey = nil
                } catch { errorKey = "Could not read the spreadsheet. Check its format and size; your saved data is unchanged." }
            }
        }
    }
    private func column(_ title: LocalizedStringKey, _ value: Binding<String?>) -> some View {
        Picker(title, selection: Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })) {
            Text("Not mapped").tag("")
            ForEach(Array(headers.enumerated()), id: \.offset) { _, header in Text(verbatim: header).tag(header) }
        }
    }
    private func resetMapping() { mapping = Self.autoMapping(headers); excludedRows = []; choices = [:]; imported = false }
    private static func autoMapping(_ headers: [String]) -> SpreadsheetColumnMapping {
        func match(_ aliases: [String]) -> String? { headers.first { aliases.contains(SpreadsheetReader.normalizedHeader($0)) } }
        return SpreadsheetColumnMapping(date: match(["fecha","date","dia"]), calories: match(["kcal","calorias","calorias kcal","energy","energia kcal"]), protein: match(["proteina","proteinas","proteina g","protein","protein g"]), weight: match(["peso","peso kg","weight","weight kg"]), activeEnergy: match(["actividad kcal","energia activa","active energy","active kcal"]), activityMinutes: match(["ejercicio min","actividad min","duracion min","exercise minutes"]), notes: match(["notas","notes","observaciones"]), closed: match(["cerrado","closed","estado"]), carbohydrates: match(["carbohidratos","carbohidratos g","carbs","carbohydrates g"]), fat: match(["grasas","grasas g","fat","fat g"]))
    }
    private func confirmImport() {
        do {
            let rows = included.compactMap { row -> HistoricalDaySummary? in
                guard let date = row.date else { return nil }
                return HistoricalDaySummary(date: date, nutrients: row.nutrients, weight: row.weight, activeEnergy: row.activeEnergy, activityMinutes: row.activityMinutes, notes: row.notes, isClosed: row.isClosed ?? false, originalRow: row.originalRow)
            }
            let selectionHash = SHA256.hash(data: Data((fileHash + (table?.name ?? "") + rows.map(\.originalRow).joined(separator: "|") + String(describing: mapping)).utf8)).map { String(format: "%02x", $0) }.joined()
            _ = try store.importBatch(fileFingerprint: selectionHash, fileName: fileName, summaries: rows, conflictChoices: choices)
            imported = true; errorKey = nil
        } catch { errorKey = (error as? NutritionError)?.userFacingKey ?? "Could not save the import. Your saved data is unchanged." }
    }
}

import Foundation
import zlib

struct WorkbookTable: Equatable {
    let name: String
    /// Rows retain worksheet row numbers: missing worksheet rows are empty arrays.
    let rows: [[String]]
}

enum SpreadsheetReadError: Error, Equatable {
    case fileTooLarge
    case unsupportedFileType
    case invalidUTF8
    case malformedCSV
    case malformedZIP
    case encryptedArchive
    case zip64Unsupported
    case tooManyEntries
    case tooManyRows
    case oversizedEntry
    case oversizedArchive
    case invalidEntryPath
    case unsupportedCompression
    case invalidWorkbook
    case malformedXML
}

enum SpreadsheetNutrient: String, Equatable {
    case carbohydrates
    case fat
}

enum SpreadsheetRowIssue: Equatable {
    case missingDate
    case invalidDate(String)
    case invalidNumber(column: String, value: String)
    case invalidClosedValue(String)
    case nutrientConflict(nutrient: SpreadsheetNutrient, columnValue: Double, notesValue: Double)
}

struct SpreadsheetColumnMapping: Equatable {
    var date: String? = nil
    var calories: String? = nil
    var protein: String? = nil
    var weight: String? = nil
    var activeEnergy: String? = nil
    var activityMinutes: String? = nil
    var notes: String? = nil
    var closed: String? = nil
    var carbohydrates: String? = nil
    var fat: String? = nil

    init(
        date: String? = nil,
        calories: String? = nil,
        protein: String? = nil,
        weight: String? = nil,
        activeEnergy: String? = nil,
        activityMinutes: String? = nil,
        notes: String? = nil,
        closed: String? = nil,
        carbohydrates: String? = nil,
        fat: String? = nil
    ) {
        self.date = date
        self.calories = calories
        self.protein = protein
        self.weight = weight
        self.activeEnergy = activeEnergy
        self.activityMinutes = activityMinutes
        self.notes = notes
        self.closed = closed
        self.carbohydrates = carbohydrates
        self.fat = fat
    }
}

struct SpreadsheetRow: Equatable {
    let date: Date?
    let nutrients: NutrientValues
    let weight: Double?
    let activeEnergy: Double?
    let activityMinutes: Double?
    let notes: String
    let isClosed: Bool?
    let originalRow: String
    let issues: [SpreadsheetRowIssue]
}

struct SpreadsheetPreview: Equatable {
    let sheetName: String
    let rows: [SpreadsheetRow]
    let skippedFutureEmptyRows: [String]
    let unmappedHeaders: [String]
}

enum SpreadsheetReader {
    static let maximumFileBytes = 20 * 1_024 * 1_024
    static let maximumEntryBytes = 50 * 1_024 * 1_024
    static let maximumUncompressedBytes = 100 * 1_024 * 1_024
    static let maximumEntries = 50_000
    static let maximumRows = 50_000
    static let maximumColumns = 16_384
    static let maximumExpandedCells = 2_000_000

    static func read(data: Data, fileExtension: String) throws -> [WorkbookTable] {
        guard data.count <= maximumFileBytes else { throw SpreadsheetReadError.fileTooLarge }
        switch fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() {
        case "csv":
            return [WorkbookTable(name: "CSV", rows: try CSVReader.read(data))]
        case "xlsx":
            return try XLSXReader.read(data)
        default:
            throw SpreadsheetReadError.unsupportedFileType
        }
    }

    /// Converts an Excel serial using the Gregorian 1900 or 1904 date system.
    /// The fictitious 1900-02-29 is rejected. Result components are anchored in UTC;
    /// the preview parser reconstructs those wall-clock components in the profile zone.
    static func excelDate(serial: Double, date1904: Bool = false) -> Date? {
        guard serial.isFinite, serial >= 0,
              serial <= (date1904 ? 2_957_003 : 2_958_465) else { return nil }
        let wholeDays = floor(serial)
        if !date1904, wholeDays == 60 { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let origin: DateComponents = date1904
            ? DateComponents(year: 1904, month: 1, day: 1)
            : DateComponents(year: 1899, month: 12, day: 31)
        guard let originDate = calendar.date(from: origin) else { return nil }
        let correctedDays = date1904 || wholeDays < 60 ? serial : serial - 1
        let seconds = correctedDays * 86_400
        guard seconds.isFinite else { return nil }
        let result = originDate.addingTimeInterval(seconds)
        return result.timeIntervalSinceReferenceDate.isFinite ? result : nil
    }

    nonisolated static func normalizedHeader(_ header: String) -> String {
        let folded = header.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "es_UY"))
        let words = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(words).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

enum SpreadsheetPreviewBuilder {
    static func build(
        table: WorkbookTable,
        mapping: SpreadsheetColumnMapping,
        timeZone: TimeZone,
        headerRowNumber: Int = 1,
        now: Date = Date()
    ) -> SpreadsheetPreview {
        guard headerRowNumber > 0, headerRowNumber <= table.rows.count else {
            return SpreadsheetPreview(sheetName: table.name, rows: [], skippedFutureEmptyRows: [], unmappedHeaders: [])
        }
        let header = table.rows[headerRowNumber - 1]
        let normalizedHeaders = header.map(SpreadsheetReader.normalizedHeader)
        let mappingValues: [(String, String?)] = [
            ("date", mapping.date), ("calories", mapping.calories), ("protein", mapping.protein),
            ("weight", mapping.weight), ("active energy", mapping.activeEnergy),
            ("activity minutes", mapping.activityMinutes), ("notes", mapping.notes),
            ("closed", mapping.closed), ("carbohydrates", mapping.carbohydrates), ("fat", mapping.fat)
        ]
        let unmapped = mappingValues.compactMap { label, name -> String? in
            guard let name, !normalizedHeaders.contains(SpreadsheetReader.normalizedHeader(name)) else { return nil }
            return "\(label): \(name)"
        } + (mapping.date == nil ? ["date: not mapped"] : [])
        let today = localDay(now, timeZone: timeZone)
        var previewRows = [SpreadsheetRow]()
        var skipped = [String]()

        for zeroBasedIndex in headerRowNumber..<table.rows.count {
            let values = table.rows[zeroBasedIndex]
            let sourceRow = sourceRowLabel(zeroBasedIndex + 1)
            func value(_ name: String?) -> String? {
                guard let name,
                      let index = normalizedHeaders.firstIndex(of: SpreadsheetReader.normalizedHeader(name)),
                      index < values.count else { return nil }
                let text = values[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }

            let dateText = value(mapping.date)
            let parsedDate = dateText.flatMap { parseDate($0, timeZone: timeZone) }
            let notes = value(mapping.notes) ?? ""
            let calories = parseMappedNumber(value(mapping.calories), name: mapping.calories)
            let protein = parseMappedNumber(value(mapping.protein), name: mapping.protein)
            let weight = parseMappedNumber(value(mapping.weight), name: mapping.weight)
            let activeEnergy = parseMappedNumber(value(mapping.activeEnergy), name: mapping.activeEnergy)
            let activityMinutes = parseMappedNumber(value(mapping.activityMinutes), name: mapping.activityMinutes)
            let columnCarbs = parseMappedNumber(value(mapping.carbohydrates), name: mapping.carbohydrates)
            let columnFat = parseMappedNumber(value(mapping.fat), name: mapping.fat)
            let notesCarbs = explicitNoteValue(notes, labels: ["carbohidratos", "carbs"])
            let notesFat = explicitNoteValue(notes, labels: ["grasas", "grasa", "fat"])
            let closedText = value(mapping.closed)
            let closed = closedText.flatMap(parseBoolean)

            let mappedValues = [
                value(mapping.calories), value(mapping.protein), value(mapping.weight),
                value(mapping.activeEnergy), value(mapping.activityMinutes), value(mapping.notes),
                value(mapping.closed), value(mapping.carbohydrates), value(mapping.fat)
            ]
            let containsData = mappedValues.contains { $0 != nil }
            if dateText == nil && !containsData { continue }
            if let parsedDate, localDay(parsedDate, timeZone: timeZone) > today, !containsData {
                skipped.append(sourceRow)
                continue
            }

            var issues = [SpreadsheetRowIssue]()
            if mapping.date != nil {
                if dateText == nil { issues.append(.missingDate) }
                else if parsedDate == nil { issues.append(.invalidDate(dateText!)) }
            }
            appendNumberIssue(value(mapping.calories), parsed: calories, name: mapping.calories, to: &issues)
            appendNumberIssue(value(mapping.protein), parsed: protein, name: mapping.protein, to: &issues)
            appendNumberIssue(value(mapping.weight), parsed: weight, name: mapping.weight, to: &issues)
            appendNumberIssue(value(mapping.activeEnergy), parsed: activeEnergy, name: mapping.activeEnergy, to: &issues)
            appendNumberIssue(value(mapping.activityMinutes), parsed: activityMinutes, name: mapping.activityMinutes, to: &issues)
            appendNumberIssue(value(mapping.carbohydrates), parsed: columnCarbs, name: mapping.carbohydrates, to: &issues)
            appendNumberIssue(value(mapping.fat), parsed: columnFat, name: mapping.fat, to: &issues)
            if let closedText, closed == nil { issues.append(.invalidClosedValue(closedText)) }

            let carbohydrates = resolvedNutrient(column: columnCarbs, notes: notesCarbs, nutrient: .carbohydrates, issues: &issues)
            let fat = resolvedNutrient(column: columnFat, notes: notesFat, nutrient: .fat, issues: &issues)
            let nutrients = NutrientValues(
                energy: calories.value,
                protein: protein.value,
                carbohydrates: carbohydrates,
                fat: fat
            )
            previewRows.append(SpreadsheetRow(
                date: parsedDate,
                nutrients: nutrients,
                weight: weight.value,
                activeEnergy: activeEnergy.value,
                activityMinutes: activityMinutes.value,
                notes: notes,
                isClosed: closed,
                originalRow: sourceRow,
                issues: issues
            ))
        }
        return SpreadsheetPreview(sheetName: table.name, rows: previewRows, skippedFutureEmptyRows: skipped, unmappedHeaders: unmapped)
    }

    static func parseDate(_ value: String, date1904: Bool = false, timeZone: TimeZone) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let serial = parseNumber(text), !text.contains("/") && !text.contains("-") {
            if let excelDate = SpreadsheetReader.excelDate(serial: serial, date1904: date1904) {
                return rebaseWallClock(excelDate, timeZone: timeZone)
            }
        }
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }

        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "dd/MM/yyyy", "d/M/yyyy", "dd-MM-yyyy", "d-M-yyyy", "yyyy/MM/dd", "yyyy-MM-dd HH:mm:ss", "dd/MM/yyyy HH:mm:ss", "d/M/yyyy H:mm"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static func sourceRowLabel(_ row: Int) -> String { "row \(row)" }

    private static func localDay(_ date: Date, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: date)
    }

    private static func rebaseWallClock(_ date: Date, timeZone: TimeZone) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var profileCalendar = Calendar(identifier: .gregorian)
        profileCalendar.timeZone = timeZone
        return profileCalendar.date(from: components)
    }

    private static func parseMappedNumber(_ text: String?, name: String?) -> ParsedNumber {
        guard let text else { return ParsedNumber(value: nil, isInvalid: false) }
        guard let number = parseNumber(text), number >= 0 else { return ParsedNumber(value: nil, isInvalid: true) }
        return ParsedNumber(value: number, isInvalid: false)
    }

    private static func appendNumberIssue(_ text: String?, parsed: ParsedNumber, name: String?, to issues: inout [SpreadsheetRowIssue]) {
        guard parsed.isInvalid, let text else { return }
        issues.append(.invalidNumber(column: name ?? "", value: text))
    }

    nonisolated private static func parseBoolean(_ text: String) -> Bool? {
        switch text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_UY")).trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true", "yes", "si", "1", "cerrado", "closed": true
        case "false", "no", "0", "abierto", "open": false
        default: nil
        }
    }

    private static func parseNumber(_ text: String) -> Double? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "\u{00a0}", with: "").replacingOccurrences(of: " ", with: "")
        value = value.replacingOccurrences(of: "(?i)(kcal|cal|kg|minutos?|mins?|g|gramos?)$", with: "", options: .regularExpression)
        guard !value.isEmpty else { return nil }
        if value.contains(",") && value.contains(".") {
            if value.lastIndex(of: ",")! > value.lastIndex(of: ".")! {
                value = value.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                value = value.replacingOccurrences(of: ",", with: "")
            }
        } else if value.contains(",") {
            value = value.replacingOccurrences(of: ",", with: ".")
        } else if let dot = value.lastIndex(of: "."), value[dot...].dropFirst().count == 3,
                  value[..<dot].allSatisfy(\.isNumber), value[dot...].dropFirst().allSatisfy(\.isNumber) {
            value.remove(at: dot)
        }
        return Double(value).flatMap { $0.isFinite ? $0 : nil }
    }

    private static func explicitNoteValue(_ notes: String, labels: [String]) -> Double? {
        let alternatives = labels.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = "(?i)(?:^|[;,.\\n])\\s*(?:\(alternatives))\\s*:\\s*([0-9][0-9.,]*)(?:\\s*(?:g|gr|gramos?))?\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: notes, range: NSRange(notes.startIndex..., in: notes)),
              let range = Range(match.range(at: 1), in: notes) else { return nil }
        return parseNumber(String(notes[range])).flatMap { $0 >= 0 ? $0 : nil }
    }

    private static func resolvedNutrient(
        column: ParsedNumber,
        notes: Double?,
        nutrient: SpreadsheetNutrient,
        issues: inout [SpreadsheetRowIssue]
    ) -> Double? {
        guard let columnValue = column.value else { return notes }
        guard let notesValue = notes else { return columnValue }
        if abs(columnValue - notesValue) > 0.000_001 {
            issues.append(.nutrientConflict(nutrient: nutrient, columnValue: columnValue, notesValue: notesValue))
        }
        return columnValue
    }

    private struct ParsedNumber {
        let value: Double?
        let isInvalid: Bool
    }
}

private enum CSVReader {
    static func read(_ data: Data) throws -> [[String]] {
        guard var text = String(data: data, encoding: .utf8) else { throw SpreadsheetReadError.invalidUTF8 }
        if text.isEmpty { return [] }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        let delimiter = detectDelimiter(text)
        var rows = [[String]]()
        var row = [String]()
        var field = ""
        var quoted = false
        var justClosedQuote = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if quoted {
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    quoted = false
                    justClosedQuote = true
                } else {
                    field.append(character)
                }
                index = next
                continue
            }
            if character == "\"" {
                guard field.isEmpty else { throw SpreadsheetReadError.malformedCSV }
                quoted = true
            } else if character == delimiter {
                row.append(field); field = ""
                guard row.count < SpreadsheetReader.maximumColumns else { throw SpreadsheetReadError.oversizedArchive }
                justClosedQuote = false
            } else if character == "\n" || character == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
                guard rows.count <= SpreadsheetReader.maximumRows else { throw SpreadsheetReadError.tooManyRows }
                guard rows.last?.count ?? 0 <= SpreadsheetReader.maximumColumns else { throw SpreadsheetReadError.oversizedArchive }
                justClosedQuote = false
                if character == "\r", next < text.endIndex, text[next] == "\n" { index = text.index(after: next); continue }
            } else {
                guard !justClosedQuote else { throw SpreadsheetReadError.malformedCSV }
                field.append(character)
            }
            index = next
        }
        guard !quoted else { throw SpreadsheetReadError.malformedCSV }
        if !field.isEmpty || !row.isEmpty || (text.last != "\n" && text.last != "\r") {
            row.append(field); rows.append(row)
            guard rows.count <= SpreadsheetReader.maximumRows else { throw SpreadsheetReadError.tooManyRows }
            guard row.count <= SpreadsheetReader.maximumColumns else { throw SpreadsheetReadError.oversizedArchive }
        }
        guard rows.count <= SpreadsheetReader.maximumRows else { throw SpreadsheetReadError.tooManyRows }
        let width = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: max(0, width - $0.count)) }
    }

    private static func detectDelimiter(_ text: String) -> Character {
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\"" {
                if quoted, next < text.endIndex, text[next] == "\"" { index = text.index(after: next); continue }
                quoted.toggle()
            } else if !quoted, counts[character] != nil {
                counts[character, default: 0] += 1
            } else if !quoted, character == "\n" || character == "\r" {
                break
            }
            index = next
        }
        return [",", ";", "\t"].max { counts[$0, default: 0] < counts[$1, default: 0] } ?? ","
    }
}

private struct ZIPEntry {
    let name: String
    let flags: UInt16
    let method: UInt16
    let crc: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let localOffset: Int
}

private final class SafeZIPArchive {
    private let data: Data
    private let entries: [String: ZIPEntry]

    init(data: Data) throws {
        self.data = data
        let allEntries = try Self.readDirectory(data)
        var lookup = [String: ZIPEntry]()
        for entry in allEntries {
            guard lookup[entry.name] == nil else { throw SpreadsheetReadError.malformedZIP }
            lookup[entry.name] = entry
        }
        entries = lookup
    }

    func contents(of path: String) throws -> Data {
        guard let entry = entries[path] else { throw SpreadsheetReadError.invalidWorkbook }
        guard entry.uncompressedSize <= SpreadsheetReader.maximumEntryBytes else { throw SpreadsheetReadError.oversizedEntry }
        guard entry.flags & 0x0001 == 0 else { throw SpreadsheetReadError.encryptedArchive }
        guard entry.method == 0 || entry.method == 8 else { throw SpreadsheetReadError.unsupportedCompression }
        let headerEnd = entry.localOffset.addingReportingOverflow(30)
        guard !headerEnd.overflow, data.containsRange(entry.localOffset..<headerEnd.partialValue),
              data.u32(at: entry.localOffset) == 0x04034b50 else { throw SpreadsheetReadError.malformedZIP }
        let nameLength = Int(data.u16(at: entry.localOffset + 26))
        let extraLength = Int(data.u16(at: entry.localOffset + 28))
        let nameStart = headerEnd.partialValue
        let dataStartResult = nameStart.addingReportingOverflow(nameLength + extraLength)
        guard !dataStartResult.overflow else { throw SpreadsheetReadError.malformedZIP }
        let dataStart = dataStartResult.partialValue
        guard data.containsRange(nameStart..<dataStart),
              let localName = String(data: data.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8),
              localName == entry.name else { throw SpreadsheetReadError.malformedZIP }
        let dataEndResult = dataStart.addingReportingOverflow(entry.compressedSize)
        guard !dataEndResult.overflow, data.containsRange(dataStart..<dataEndResult.partialValue) else { throw SpreadsheetReadError.malformedZIP }
        let compressed = data.subdata(in: dataStart..<dataEndResult.partialValue)
        let output: Data
        if entry.method == 0 {
            guard compressed.count == entry.uncompressedSize else { throw SpreadsheetReadError.malformedZIP }
            output = compressed
        } else {
            output = try Self.inflateRaw(compressed, expectedSize: entry.uncompressedSize)
        }
        guard Self.crc32(output) == entry.crc else { throw SpreadsheetReadError.malformedZIP }
        return output
    }

    private static func readDirectory(_ data: Data) throws -> [ZIPEntry] {
        guard data.count >= 22 else { throw SpreadsheetReadError.malformedZIP }
        let earliest = max(0, data.count - 22 - 65_535)
        var eocdOffset: Int?
        if data.count >= 4 {
            for offset in stride(from: data.count - 22, through: earliest, by: -1) {
                if data.u32(at: offset) == 0x06054b50 {
                    let commentLength = Int(data.u16(at: offset + 20))
                    if offset + 22 + commentLength == data.count { eocdOffset = offset; break }
                }
            }
        }
        guard let end = eocdOffset else { throw SpreadsheetReadError.malformedZIP }
        if end >= 20, data.u32(at: end - 20) == 0x07064b50 { throw SpreadsheetReadError.zip64Unsupported }
        let diskNumber = data.u16(at: end + 4)
        let directoryDisk = data.u16(at: end + 6)
        let entriesOnDisk = data.u16(at: end + 8)
        let entryCount = data.u16(at: end + 10)
        let directorySize = data.u32(at: end + 12)
        let directoryOffset = data.u32(at: end + 16)
        guard diskNumber == 0, directoryDisk == 0, entriesOnDisk == entryCount else { throw SpreadsheetReadError.malformedZIP }
        guard entryCount != UInt16.max, directorySize != UInt32.max, directoryOffset != UInt32.max else { throw SpreadsheetReadError.zip64Unsupported }
        guard Int(entryCount) <= SpreadsheetReader.maximumEntries else { throw SpreadsheetReadError.tooManyEntries }
        let start = Int(directoryOffset)
        let size = Int(directorySize)
        let directoryEnd = start.addingReportingOverflow(size)
        guard !directoryEnd.overflow, directoryEnd.partialValue <= end, data.containsRange(start..<directoryEnd.partialValue) else { throw SpreadsheetReadError.malformedZIP }
        var cursor = start
        var totalUncompressed = 0
        var result = [ZIPEntry]()
        result.reserveCapacity(Int(entryCount))
        for _ in 0..<entryCount {
            guard data.containsRange(cursor..<(cursor + 46)), data.u32(at: cursor) == 0x02014b50 else { throw SpreadsheetReadError.malformedZIP }
            let versionNeeded = data.u16(at: cursor + 6)
            let flags = data.u16(at: cursor + 8)
            let method = data.u16(at: cursor + 10)
            let crc = data.u32(at: cursor + 16)
            let compressed32 = data.u32(at: cursor + 20)
            let uncompressed32 = data.u32(at: cursor + 24)
            let nameLength = Int(data.u16(at: cursor + 28))
            let extraLength = Int(data.u16(at: cursor + 30))
            let commentLength = Int(data.u16(at: cursor + 32))
            let diskStart = data.u16(at: cursor + 34)
            let localOffset32 = data.u32(at: cursor + 42)
            if versionNeeded >= 45 { throw SpreadsheetReadError.zip64Unsupported }
            guard compressed32 != UInt32.max, uncompressed32 != UInt32.max, localOffset32 != UInt32.max, diskStart == 0 else { throw SpreadsheetReadError.zip64Unsupported }
            guard flags & 0x0001 == 0 else { throw SpreadsheetReadError.encryptedArchive }
            guard method == 0 || method == 8 else { throw SpreadsheetReadError.unsupportedCompression }
            let variableLength = nameLength.addingReportingOverflow(extraLength + commentLength)
            guard !variableLength.overflow else { throw SpreadsheetReadError.malformedZIP }
            let recordStart = cursor + 46
            let recordEndResult = recordStart.addingReportingOverflow(variableLength.partialValue)
            guard !recordEndResult.overflow, recordEndResult.partialValue <= directoryEnd.partialValue,
                  data.containsRange(recordStart..<recordEndResult.partialValue) else { throw SpreadsheetReadError.malformedZIP }
            let nameData = data.subdata(in: recordStart..<(recordStart + nameLength))
            guard let name = String(data: nameData, encoding: .utf8), validPackagePath(name) else { throw SpreadsheetReadError.invalidEntryPath }
            let extraStart = recordStart + nameLength
            guard !containsZIP64Extra(data, range: extraStart..<(extraStart + extraLength)) else { throw SpreadsheetReadError.zip64Unsupported }
            let uncompressed = Int(uncompressed32)
            guard uncompressed <= SpreadsheetReader.maximumEntryBytes else { throw SpreadsheetReadError.oversizedEntry }
            let total = totalUncompressed.addingReportingOverflow(uncompressed)
            guard !total.overflow else { throw SpreadsheetReadError.oversizedArchive }
            totalUncompressed = total.partialValue
            guard totalUncompressed <= SpreadsheetReader.maximumUncompressedBytes else { throw SpreadsheetReadError.oversizedArchive }
            let entry = ZIPEntry(
                name: name,
                flags: flags,
                method: method,
                crc: crc,
                compressedSize: Int(compressed32),
                uncompressedSize: uncompressed,
                localOffset: Int(localOffset32)
            )
            try validateLocalEntry(data, entry: entry, before: start)
            result.append(entry)
            cursor = recordEndResult.partialValue
        }
        guard cursor == directoryEnd.partialValue else { throw SpreadsheetReadError.malformedZIP }
        return result
    }

    private static func validPackagePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    private static func containsZIP64Extra(_ data: Data, range: Range<Int>) -> Bool {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard cursor + 4 <= range.upperBound else { return true }
            let identifier = data.u16(at: cursor)
            let length = Int(data.u16(at: cursor + 2))
            let end = cursor.addingReportingOverflow(4 + length)
            guard !end.overflow, end.partialValue <= range.upperBound else { return true }
            if identifier == 0x0001 { return true }
            cursor = end.partialValue
        }
        return false
    }

    private static func validateLocalEntry(_ data: Data, entry: ZIPEntry, before directoryOffset: Int) throws {
        let offset = entry.localOffset
        let fixedEnd = offset.addingReportingOverflow(30)
        guard !fixedEnd.overflow, fixedEnd.partialValue <= directoryOffset,
              data.containsRange(offset..<fixedEnd.partialValue), data.u32(at: offset) == 0x04034b50 else {
            throw SpreadsheetReadError.malformedZIP
        }
        let localVersion = data.u16(at: offset + 4)
        if localVersion >= 45 { throw SpreadsheetReadError.zip64Unsupported }
        let flags = data.u16(at: offset + 6)
        let method = data.u16(at: offset + 8)
        guard flags == entry.flags, method == entry.method else { throw SpreadsheetReadError.malformedZIP }
        let nameLength = Int(data.u16(at: offset + 26))
        let extraLength = Int(data.u16(at: offset + 28))
        let nameStart = fixedEnd.partialValue
        let dataStart = nameStart.addingReportingOverflow(nameLength + extraLength)
        guard !dataStart.overflow, dataStart.partialValue <= directoryOffset,
              data.containsRange(nameStart..<dataStart.partialValue) else { throw SpreadsheetReadError.malformedZIP }
        let localName = data.subdata(in: nameStart..<(nameStart + nameLength))
        guard String(data: localName, encoding: .utf8) == entry.name else { throw SpreadsheetReadError.malformedZIP }
        guard !containsZIP64Extra(data, range: (nameStart + nameLength)..<dataStart.partialValue) else { throw SpreadsheetReadError.zip64Unsupported }
        let dataEnd = dataStart.partialValue.addingReportingOverflow(entry.compressedSize)
        guard !dataEnd.overflow, dataEnd.partialValue <= directoryOffset,
              data.containsRange(dataStart.partialValue..<dataEnd.partialValue) else { throw SpreadsheetReadError.malformedZIP }
    }

    private static func inflateRaw(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize <= SpreadsheetReader.maximumEntryBytes else { throw SpreadsheetReadError.oversizedEntry }
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { throw SpreadsheetReadError.malformedZIP }
        defer { inflateEnd(&stream) }
        var output = Data(count: max(expectedSize, 1))
        let status: Int32 = compressed.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                guard let inputBase = inputBuffer.baseAddress, let outputBase = outputBuffer.baseAddress else { return Z_DATA_ERROR }
                stream.next_in = UnsafeMutablePointer(mutating: inputBase.assumingMemoryBound(to: Bytef.self))
                stream.avail_in = uInt(compressed.count)
                stream.next_out = outputBase.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(max(expectedSize, 1))
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, Int(stream.total_out) == expectedSize, Int(stream.total_in) == compressed.count else {
            throw SpreadsheetReadError.malformedZIP
        }
        return Data(output.prefix(expectedSize))
    }

    private static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return UInt32(zlib.crc32(0, nil, 0)) }
            return UInt32(zlib.crc32(0, base.assumingMemoryBound(to: Bytef.self), uInt(data.count)))
        }
    }
}

private enum XLSXReader {
    static func read(_ data: Data) throws -> [WorkbookTable] {
        let archive = try SafeZIPArchive(data: data)
        let workbook = try archive.contents(of: "xl/workbook.xml")
        let relationships = try archive.contents(of: "xl/_rels/workbook.xml.rels")
        let workbookInfo = try WorkbookXMLParser.parse(workbook)
        let relationMap = try WorkbookRelationshipsParser.parse(relationships)
        let sharedStrings: [String] = archiveHas(archive, "xl/sharedStrings.xml")
            ? try SharedStringsXMLParser.parse(archive.contents(of: "xl/sharedStrings.xml"))
            : []
        let dateStyles: Set<Int> = archiveHas(archive, "xl/styles.xml")
            ? try StylesXMLParser.dateStyles(archive.contents(of: "xl/styles.xml"))
            : []

        guard !workbookInfo.sheets.isEmpty else { throw SpreadsheetReadError.invalidWorkbook }
        var totalRows = 0
        var tables = [WorkbookTable]()
        for sheet in workbookInfo.sheets {
            guard let target = relationMap[sheet.relationshipID], let path = resolveSheetPath(target) else { throw SpreadsheetReadError.invalidWorkbook }
            let parsed = try WorksheetXMLParser.parse(archive.contents(of: path), sharedStrings: sharedStrings, dateStyles: dateStyles, date1904: workbookInfo.date1904)
            totalRows += parsed.count
            guard totalRows <= SpreadsheetReader.maximumRows else { throw SpreadsheetReadError.tooManyRows }
            tables.append(WorkbookTable(name: sheet.name, rows: parsed))
        }
        return tables
    }

    // Looking up path existence through the validated archive index is kept internal.
    private static func archiveHas(_ archive: SafeZIPArchive, _ path: String) -> Bool { archive.hasEntry(path) }

    private static func resolveSheetPath(_ target: String) -> String? {
        guard !target.contains("\\"), !target.contains(":") else { return nil }
        let path: String
        if target.hasPrefix("/") { path = String(target.dropFirst()) }
        else { path = "xl/" + target }
        guard !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return nil }
        return path
    }
}

private struct WorkbookInfo {
    struct Sheet { let name: String; let relationshipID: String }
    let date1904: Bool
    let sheets: [Sheet]
}

private final class WorkbookXMLParser: NSObject, XMLParserDelegate {
    private var date1904 = false
    private var sheets = [WorkbookInfo.Sheet]()
    private var parseError = false

    static func parse(_ data: Data) throws -> WorkbookInfo {
        guard SecureXML.isSafe(data) else { throw SpreadsheetReadError.malformedXML }
        let delegate = WorkbookXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !delegate.parseError else { throw SpreadsheetReadError.malformedXML }
        return WorkbookInfo(date1904: delegate.date1904, sheets: delegate.sheets)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "workbookPr" {
            date1904 = ["1", "true", "TRUE"].contains(attributes["date1904"] ?? "0")
        } else if elementName == "sheet" {
            guard let name = attributes["name"], let id = attributes["r:id"] ?? attributes["id"] else { parseError = true; return }
            sheets.append(.init(name: name, relationshipID: id))
            if sheets.count > SpreadsheetReader.maximumEntries { parseError = true }
        }
    }
}

private final class WorkbookRelationshipsParser: NSObject, XMLParserDelegate {
    private var relationships = [String: String]()
    private var invalid = false

    static func parse(_ data: Data) throws -> [String: String] {
        guard SecureXML.isSafe(data) else { throw SpreadsheetReadError.malformedXML }
        let delegate = WorkbookRelationshipsParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !delegate.invalid else { throw SpreadsheetReadError.malformedXML }
        return delegate.relationships
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard elementName == "Relationship" else { return }
        guard let id = attributes["Id"], let target = attributes["Target"], attributes["TargetMode"]?.lowercased() != "external" else { invalid = true; return }
        relationships[id] = target
    }
}

private final class SharedStringsXMLParser: NSObject, XMLParserDelegate {
    private var strings = [String]()
    private var inItem = false
    private var inText = false
    private var current = ""

    static func parse(_ data: Data) throws -> [String] {
        guard SecureXML.isSafe(data) else { throw SpreadsheetReadError.malformedXML }
        let delegate = SharedStringsXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw SpreadsheetReadError.malformedXML }
        return delegate.strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "si" { inItem = true; current = "" }
        else if elementName == "t", inItem { inText = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inItem && inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" { inText = false }
        else if elementName == "si" { strings.append(current); inItem = false }
    }
}

private final class StylesXMLParser: NSObject, XMLParserDelegate {
    private var customFormats = [Int: String]()
    private var cellFormats = [Int]()
    private var inCellXfs = false

    static func dateStyles(_ data: Data) throws -> Set<Int> {
        guard SecureXML.isSafe(data) else { throw SpreadsheetReadError.malformedXML }
        let delegate = StylesXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw SpreadsheetReadError.malformedXML }
        return Set(delegate.cellFormats.enumerated().compactMap { index, formatID in
            if isBuiltInDateFormat(formatID) { return index }
            guard let format = delegate.customFormats[formatID] else { return nil }
            return looksLikeDateFormat(format) ? index : nil
        })
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "numFmt", let id = Int(attributes["numFmtId"] ?? ""), let format = attributes["formatCode"] { customFormats[id] = format }
        else if elementName == "cellXfs" { inCellXfs = true }
        else if elementName == "xf", inCellXfs, let id = Int(attributes["numFmtId"] ?? "0") { cellFormats.append(id) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "cellXfs" { inCellXfs = false }
    }

    private static func isBuiltInDateFormat(_ id: Int) -> Bool {
        (14...22).contains(id) || (27...36).contains(id) || (45...47).contains(id) || (50...58).contains(id)
    }

    private static func looksLikeDateFormat(_ format: String) -> Bool {
        var cleaned = ""
        var inQuote = false
        var inBracket = false
        var escaped = false
        for character in format.lowercased() {
            if escaped { escaped = false; continue }
            if character == "\\" || character == "_" { escaped = true; continue }
            if character == "[" { inBracket = true; continue }
            if character == "]" { inBracket = false; continue }
            if inBracket { continue }
            if character == "\"" { inQuote.toggle(); continue }
            if !inQuote && character != "[" && character != "]" { cleaned.append(character) }
        }
        return cleaned.contains("y") || cleaned.contains("d") || (cleaned.contains("m") && (cleaned.contains("/") || cleaned.contains("-")))
    }
}

private final class WorksheetXMLParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private let dateStyles: Set<Int>
    private let date1904: Bool
    private var rows = [Int: [Int: String]]()
    private var currentRow = 0
    private var nextRow = 1
    private var nextColumn = 0
    private var currentColumn: Int?
    private var cellType = ""
    private var styleIndex = 0
    private var value = ""
    private var inlineValue = ""
    private var capture: String?
    private var invalid = false

    init(sharedStrings: [String], dateStyles: Set<Int>, date1904: Bool) {
        self.sharedStrings = sharedStrings
        self.dateStyles = dateStyles
        self.date1904 = date1904
    }

    static func parse(_ data: Data, sharedStrings: [String], dateStyles: Set<Int>, date1904: Bool) throws -> [[String]] {
        guard SecureXML.isSafe(data) else { throw SpreadsheetReadError.malformedXML }
        let delegate = WorksheetXMLParser(sharedStrings: sharedStrings, dateStyles: dateStyles, date1904: date1904)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !delegate.invalid else { throw SpreadsheetReadError.malformedXML }
        guard let maxRow = delegate.rows.keys.max() else { return [] }
        guard maxRow <= SpreadsheetReader.maximumRows else { throw SpreadsheetReadError.tooManyRows }
        var expandedCells = 0
        var result = [[String]]()
        result.reserveCapacity(maxRow)
        for rowNumber in 1...maxRow {
            guard let cells = delegate.rows[rowNumber], let maxColumn = cells.keys.max() else { result.append([]); continue }
            expandedCells += maxColumn + 1
            guard expandedCells <= SpreadsheetReader.maximumExpandedCells else { throw SpreadsheetReadError.oversizedArchive }
            result.append((0...maxColumn).map { cells[$0] ?? "" })
        }
        return result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        switch elementName {
        case "row":
            let row = Int(attributes["r"] ?? "") ?? nextRow
            guard row > 0, row <= SpreadsheetReader.maximumRows else { invalid = true; return }
            currentRow = row
            nextRow = row + 1
            if rows[row] != nil { invalid = true }
            rows[row] = [:]
            nextColumn = 0
        case "c":
            let reference = attributes["r"] ?? ""
            let coordinate = Self.coordinate(reference)
            guard !reference.isEmpty, let coordinate, coordinate.row == currentRow,
                  coordinate.column < SpreadsheetReader.maximumColumns else { invalid = true; return }
            currentColumn = coordinate.column
            nextColumn = coordinate.column + 1
            cellType = attributes["t"] ?? "n"
            styleIndex = Int(attributes["s"] ?? "0") ?? 0
            value = ""
            inlineValue = ""
        case "v": capture = "value"
        case "t":
            if cellType == "inlineStr" { capture = "inline" }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch capture {
        case "value": value += string
        case "inline": inlineValue += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v", "t": capture = nil
        case "c": storeCell()
        case "row": currentRow = 0
        default: break
        }
    }

    private func storeCell() {
        guard let column = currentColumn, currentRow > 0 else { invalid = true; return }
        var text = cellType == "inlineStr" ? inlineValue : value
        if cellType == "s" {
            guard let index = Int(value), index >= 0, index < sharedStrings.count else { invalid = true; return }
            text = sharedStrings[index]
        } else if cellType == "b" {
            text = value == "1" ? "TRUE" : (value == "0" ? "FALSE" : value)
        } else if dateStyles.contains(styleIndex), let serial = Double(value),
                  let date = SpreadsheetReader.excelDate(serial: serial, date1904: date1904) {
            text = Self.wallClockString(date)
        }
        rows[currentRow, default: [:]][column] = text
        currentColumn = nil
    }

    private static func coordinate(_ reference: String) -> (column: Int, row: Int)? {
        var letters = ""
        var numbers = ""
        for character in reference {
            if character.isASCII && character.isLetter && numbers.isEmpty { letters.append(character.uppercased()) }
            else if character.isNumber { numbers.append(character) }
            else { return nil }
        }
        guard !letters.isEmpty, let row = Int(numbers), row > 0 else { return nil }
        var column = 0
        for scalar in letters.unicodeScalars {
            let ascii = scalar.value
            guard ascii >= 65, ascii <= 90 else { return nil }
            column = column * 26 + Int(ascii - 64)
        }
        return (column - 1, row)
    }

    private static func wallClockString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

private extension Data {
    func containsRange(_ range: Range<Int>) -> Bool {
        range.lowerBound >= 0 && range.upperBound >= range.lowerBound && range.upperBound <= count
    }

    func u16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func u32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}

private enum SecureXML {
    static func isSafe(_ data: Data) -> Bool {
        guard let source = String(data: data, encoding: .utf8) else { return false }
        return !source.contains("<!DOCTYPE") && !source.contains("<!ENTITY")
    }
}

private extension SafeZIPArchive {
    func hasEntry(_ path: String) -> Bool { entries[path] != nil }
}

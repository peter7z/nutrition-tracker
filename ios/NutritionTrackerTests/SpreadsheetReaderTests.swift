import XCTest
@testable import nutrition_tracker

@MainActor final class SpreadsheetReaderTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "America/Montevideo")!

    func testCSVDetectsSemicolonAndPreservesEscapedQuotesAndMultilineCells() throws {
        let csv = "Fecha;Notas;Proteína\n"
            + "01/10/2026;\"pollo; asado \"\"rico\"\"\";120\n"
            + "02/10/2026;\"línea uno\nlínea dos\";115\n"
        let table = try XCTUnwrap(SpreadsheetReader.read(data: Data(csv.utf8), fileExtension: ".CSV").first)

        XCTAssertEqual(table.rows.count, 3)
        XCTAssertEqual(table.rows[0], ["Fecha", "Notas", "Proteína"])
        XCTAssertEqual(table.rows[1][1], "pollo; asado \"rico\"")
        XCTAssertEqual(table.rows[2][1], "línea uno\nlínea dos")
        XCTAssertEqual(SpreadsheetReader.normalizedHeader("  PROTEÍNA (g) "), "proteina g")
    }

    func testCSVSupportsTabAndRejectsMalformedQuotes() throws {
        let table = try XCTUnwrap(SpreadsheetReader.read(data: Data("date\tvalue\n2026-10-08\t7\n".utf8), fileExtension: "csv").first)
        XCTAssertEqual(table.rows[1], ["2026-10-08", "7"])
        XCTAssertThrowsError(try SpreadsheetReader.read(data: Data("a,b\n\"not closed,b".utf8), fileExtension: "csv")) { error in
            XCTAssertEqual(error as? SpreadsheetReadError, .malformedCSV)
        }
        XCTAssertThrowsError(try SpreadsheetReader.read(data: Data([0xff]), fileExtension: "csv")) { error in
            XCTAssertEqual(error as? SpreadsheetReadError, .invalidUTF8)
        }
    }

    func testExcelSerialDatesSupport1900And1904SystemsAndProfileTimezone() throws {
        let januaryFirst1900 = try XCTUnwrap(SpreadsheetReader.excelDate(serial: 1))
        let januaryFirst1904 = try XCTUnwrap(SpreadsheetReader.excelDate(serial: 0, date1904: true))
        XCTAssertNil(SpreadsheetReader.excelDate(serial: 60), "Excel's fictitious 1900-02-29 must not become a real date")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(utc.dateComponents([.year, .month, .day], from: januaryFirst1900), DateComponents(year: 1900, month: 1, day: 1))
        XCTAssertEqual(utc.dateComponents([.year, .month, .day], from: januaryFirst1904), DateComponents(year: 1904, month: 1, day: 1))

        let parsed = try XCTUnwrap(SpreadsheetPreviewBuilder.parseDate("08/10/2026", timeZone: timeZone))
        var local = Calendar(identifier: .gregorian); local.timeZone = timeZone
        XCTAssertEqual(local.dateComponents([.year, .month, .day], from: parsed), DateComponents(year: 2026, month: 10, day: 8))
    }

    func testPreviewMapsExplicitNutritionFlagsConflictsAndFutureEmptyRows() {
        let table = WorkbookTable(name: "Registro diario", rows: [
            ["Fecha", "Kcal", "Proteína", "Carbohidratos", "Grasas", "Notas", "Cerrado"],
            ["08/10/2026", "2.100", "130", "90", "30", "pollo; carbohidratos: 100g; grasas: 30g", "Sí"],
            ["09/10/2026", "", "", "", "", "", ""],
            ["09/10/2026", "2.000", "120", "", "", "", ""]
        ])
        let mapping = SpreadsheetColumnMapping(
            date: "Fecha", calories: "Kcal", protein: "Proteína", notes: "Notas", closed: "Cerrado",
            carbohydrates: "Carbohidratos", fat: "Grasas"
        )
        let now = localDate(8, hour: 10)
        let preview = SpreadsheetPreviewBuilder.build(table: table, mapping: mapping, timeZone: timeZone, now: now)

        XCTAssertEqual(preview.sheetName, "Registro diario")
        XCTAssertEqual(preview.rows.count, 2)
        XCTAssertEqual(preview.skippedFutureEmptyRows, ["row 3"])
        XCTAssertEqual(preview.rows[0].originalRow, "row 2")
        XCTAssertEqual(preview.rows[0].nutrients.energy, 2_100)
        XCTAssertEqual(preview.rows[0].nutrients.protein, 130)
        XCTAssertEqual(preview.rows[0].nutrients.carbohydrates, 90, "Column value is preserved while a difference with notes is reported")
        XCTAssertEqual(preview.rows[0].nutrients.fat, 30)
        XCTAssertEqual(preview.rows[0].isClosed, true)
        XCTAssertTrue(preview.rows[0].issues.contains(.nutrientConflict(nutrient: .carbohydrates, columnValue: 90, notesValue: 100)))
        XCTAssertFalse(preview.rows[0].issues.contains { if case .nutrientConflict(nutrient: .fat, _, _) = $0 { return true }; return false })
        XCTAssertEqual(preview.rows[1].originalRow, "row 4")
        XCTAssertEqual(preview.rows[1].date.map { localDay($0) }, localDay(localDate(9)))
        XCTAssertTrue(preview.rows[1].nutrients.carbohydrates == nil && preview.rows[1].nutrients.fat == nil)
    }

    func testXLSXReadsRelationshipsSharedRichTextInlineTextSparseRowsAndCachedFormula() throws {
        let archive = StoredZIPFixture.make([
            ("[Content_Types].xml", Data("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"></Types>".utf8)),
            ("xl/workbook.xml", Data("<workbook xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><workbookPr date1904=\"1\"/><sheets><sheet name=\"Registro\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>".utf8)),
            ("xl/_rels/workbook.xml.rels", Data("<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\" Type=\"worksheet\"/></Relationships>".utf8)),
            ("xl/sharedStrings.xml", Data("<sst><si><r><t>Fecha</t></r><r><t> / día</t></r></si><si><t>Kcal</t></si><si><t>Notas</t></si></sst>".utf8)),
            ("xl/styles.xml", Data("<styleSheet><numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"yyyy-mm-dd\"/></numFmts><cellXfs count=\"2\"><xf numFmtId=\"0\"/><xf numFmtId=\"164\"/></cellXfs></styleSheet>".utf8)),
            ("xl/worksheets/sheet1.xml", Data("<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\" t=\"s\"><v>1</v></c><c r=\"D1\" t=\"s\"><v>2</v></c></row><row r=\"3\"><c r=\"A3\" s=\"1\"><v>0</v></c><c r=\"B3\"><f>1000+200</f><v>1200</v></c><c r=\"D3\" t=\"inlineStr\"><is><r><t>nota </t></r><r><t>completa</t></r></is></c></row></sheetData></worksheet>".utf8))
        ])
        let tables = try SpreadsheetReader.read(data: archive, fileExtension: "xlsx")
        let table = try XCTUnwrap(tables.first)

        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(table.name, "Registro")
        XCTAssertEqual(table.rows.count, 3)
        XCTAssertTrue(table.rows[1].isEmpty, "Missing worksheet row numbers remain visible in the preview")
        XCTAssertEqual(table.rows[0][0], "Fecha / día")
        XCTAssertEqual(table.rows[2][0], "1904-01-01T00:00:00.000")
        XCTAssertEqual(table.rows[2][1], "1200", "Formula values come from Excel's cached result")
        XCTAssertEqual(table.rows[2][3], "nota completa")
    }

    func testXLSXParsesNamespacePrefixedWorkbookAndWorksheetElements() throws {
        let mainNS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let archive = StoredZIPFixture.make([
            ("xl/workbook.xml", Data("<x:workbook xmlns:x=\"\(mainNS)\" xmlns:r=\"\(relNS)\"><x:sheets><x:sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\"/></x:sheets></x:workbook>".utf8)),
            ("xl/_rels/workbook.xml.rels", Data("<p:Relationships xmlns:p=\"http://schemas.openxmlformats.org/package/2006/relationships\"><p:Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\" Type=\"worksheet\"/></p:Relationships>".utf8)),
            ("xl/worksheets/sheet1.xml", Data("<x:worksheet xmlns:x=\"\(mainNS)\"><x:sheetData><x:row r=\"1\"><x:c r=\"A1\" t=\"inlineStr\"><x:is><x:t>Date</x:t></x:is></x:c></x:row></x:sheetData></x:worksheet>".utf8))
        ])

        let tables = try SpreadsheetReader.read(data: archive, fileExtension: "xlsx")
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables.first?.rows, [["Date"]])
    }

    func testXLSXRejectsTraversalZip64EncryptionAndOversizedFiles() {
        let plain = StoredZIPFixture.make([("../escape", Data("x".utf8))])
        XCTAssertThrowsError(try SpreadsheetReader.read(data: plain, fileExtension: "xlsx")) { error in
            XCTAssertEqual(error as? SpreadsheetReadError, .invalidEntryPath)
        }
        let zip64 = StoredZIPFixture.make([("safe", Data())], zip64EOCD: true)
        XCTAssertThrowsError(try SpreadsheetReader.read(data: zip64, fileExtension: "xlsx")) { error in
            XCTAssertEqual(error as? SpreadsheetReadError, .zip64Unsupported)
        }
        let encrypted = StoredZIPFixture.make([("safe", Data("x".utf8))], encrypted: true)
        XCTAssertThrowsError(try SpreadsheetReader.read(data: encrypted, fileExtension: "xlsx")) { error in
            XCTAssertEqual(error as? SpreadsheetReadError, .encryptedArchive)
        }
        XCTAssertThrowsError(try SpreadsheetReader.read(data: Data(count: SpreadsheetReader.maximumFileBytes + 1), fileExtension: "csv")) { error in
            XCTAssertEqual(error as? SpreadsheetReadError, .fileTooLarge)
        }
    }

    private func localDate(_ day: Int, hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private func localDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return calendar.startOfDay(for: date)
    }
}

private enum StoredZIPFixture {
    private struct Entry {
        let name: String
        let bytes: Data
        let checksum: UInt32
        let offset: Int
        let flags: UInt16
    }

    static func make(_ files: [(String, Data)], zip64EOCD: Bool = false, encrypted: Bool = false) -> Data {
        var archive = Data()
        var entries = [Entry]()
        for (name, bytes) in files {
            let nameBytes = Data(name.utf8)
            let flags: UInt16 = encrypted ? 1 : 0
            let offset = archive.count
            let crc = checksum(bytes)
            archive.appendLE(UInt32(0x04034b50))
            archive.appendLE(UInt16(20)); archive.appendLE(flags); archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(crc)
            archive.appendLE(UInt32(bytes.count)); archive.appendLE(UInt32(bytes.count))
            archive.appendLE(UInt16(nameBytes.count)); archive.appendLE(UInt16(0))
            archive.append(nameBytes); archive.append(bytes)
            entries.append(Entry(name: name, bytes: bytes, checksum: crc, offset: offset, flags: flags))
        }
        let directoryOffset = archive.count
        for entry in entries {
            let name = Data(entry.name.utf8)
            archive.appendLE(UInt32(0x02014b50))
            archive.appendLE(UInt16(20)); archive.appendLE(UInt16(20))
            archive.appendLE(entry.flags); archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(entry.checksum)
            archive.appendLE(UInt32(entry.bytes.count)); archive.appendLE(UInt32(entry.bytes.count))
            archive.appendLE(UInt16(name.count)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(UInt32(0))
            archive.appendLE(UInt32(entry.offset)); archive.append(name)
        }
        let directorySize = archive.count - directoryOffset
        archive.appendLE(UInt32(0x06054b50)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
        archive.appendLE(zip64EOCD ? UInt16.max : UInt16(entries.count))
        archive.appendLE(zip64EOCD ? UInt16.max : UInt16(entries.count))
        archive.appendLE(UInt32(directorySize)); archive.appendLE(UInt32(directoryOffset)); archive.appendLE(UInt16(0))
        return archive
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

import XCTest
@testable import nutrition_tracker

@MainActor final class BackendDiaryTests: XCTestCase {
    private func wire(_ records: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["revision": 4, "records": records, "messages": []])
    }
    private func payload<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
    }
    func testMCPDraftMapsToOneEntryWithTimezoneFiberAndCurrentVersion() throws {
        let id = UUID()
        var draft = FoodEntryDraft(name: "Banana", mealName: "Merienda", consumedAt: Date(timeIntervalSince1970: 0),
            amount: 1, unit: .serving, nutrition: NutrientValues(energy: 133.5, protein: 1.65, carbohydrates: 34.2,
                fat: 0.45, saturatedFat: 0.1, fiber: 3.9), basis: .perServing, source: .estimate)
        draft.notes = "Una banana, 150 g"
        var object = try payload(draft)
        object["consumedAt"] = "2026-10-11T01:30:00.123456+00:00"
        let data = try wire([
            ["id": UUID().uuidString, "kind": "profile", "version": 1,
             "payload": ["timeZoneIdentifier": "America/Montevideo", "preferences": ""]],
            ["id": id.uuidString, "kind": "entry", "version": 3, "payload": ["draft": object]]
        ])
        let snapshot = try BackendDiary.decode(data)
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.entries[0].id, id)
        XCTAssertEqual(snapshot.entries[0].version, 3)
        XCTAssertEqual(snapshot.entries[0].dayID, "2026-10-10")
        XCTAssertEqual(snapshot.entries[0].values.fiber, 3.9)
        XCTAssertEqual(snapshot.entries[0].values.energy, 133.5)
        XCTAssertTrue(snapshot.messages.isEmpty)
    }
    func testDailyTotalsUseExplicitHistoricalSelectionWithoutAddingMeals() throws {
        let fixture = CompanionTestFixture.history(on: Date(timeIntervalSince1970: 1_791_475_200))
        let dayID = fixture.days[0].id
        let batch = UUID()
        let values = NutrientValues(energy: 2200, protein: 140, carbohydrates: 250, fat: 70, saturatedFat: 15, fiber: 30)
        var totals = NutritionTotals(); totals.include(values)
        let summary = DailyNutritionSnapshot(id: UUID(), version: 1, capturedAt: .now, completeness: .complete,
            totals: totals, entryVersions: [:], goalVersionID: nil, intakeSource: .historical)
        let day = NutritionDayLog(id: dayID, version: 1, summaries: [summary])
        let historical = HistoricalNutritionSummary(id: UUID(), dayID: dayID, nutrients: values,
            isComplete: true, notes: "Día completo", importBatchID: batch, sourceRow: "MCP whole-day totals")
        var records: [[String: Any]] = [
            ["id": UUID().uuidString, "kind": "day", "version": 1, "payload": try payload(day)],
            ["id": historical.id.uuidString, "kind": "historical", "version": 1, "payload": try payload(historical)]
        ]
        let withoutMeals = try BackendDiary.decode(wire(records))
        XCTAssertTrue(withoutMeals.entries.isEmpty)
        XCTAssertEqual(withoutMeals.importBatches.map(\.id), [batch])
        let entry = fixture.entries[0]
        records.append(["id": entry.id.uuidString, "kind": "entry", "version": entry.version,
            "payload": ["draft": try payload(entry.draft)]])
        records.append(["id": UUID().uuidString, "kind": "resolution", "version": 1,
            "payload": ["dayID": dayID, "selection": "historical"]])
        let snapshot = try BackendDiary.decode(wire(records))
        let result = TrackingBridge.nutrition(on: entry.draft.consumedAt, manual: snapshot, health: HealthSnapshot())
        XCTAssertEqual(result.values.energy, 2200)
        XCTAssertEqual(result.values.fiber, 30)
        XCTAssertFalse(result.hasConflict)
        XCTAssertEqual(snapshot.entries.count, 1)
    }
    func testLegacyDayFlagIsIgnoredAndOldSummaryTimestampRemainsReadable() throws {
        let fixture = CompanionTestFixture.history(on: .now)
        var day = try payload(fixture.days[0])
        day["isClosed"] = true
        let summaries = try XCTUnwrap(day["summaries"] as? [[String: Any]])
        XCTAssertNotNil(summaries[0]["closedAt"])
        let snapshot = try BackendDiary.decode(wire([["id": UUID().uuidString, "kind": "day", "version": 1, "payload": day]]))
        XCTAssertEqual(snapshot.days[0].summaries[0].capturedAt.timeIntervalSince1970,
            fixture.days[0].summaries[0].capturedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(try payload(snapshot.days[0])["isClosed"])
    }

    func testLegacyHistoricalCompletenessStillDecodes() throws {
        let id = UUID()
        let historical: [String: Any] = ["id": id.uuidString, "dayID": "2026-10-08",
            "nutrients": ["energy": 2200], "isClosed": true, "notes": "Legacy total",
            "importBatchID": UUID().uuidString, "sourceRow": "Legacy import"]
        let snapshot = try BackendDiary.decode(wire([["id": id.uuidString, "kind": "historical", "version": 1, "payload": historical]]))
        XCTAssertTrue(snapshot.historicalSummaries[0].isComplete)
        let encoded = try payload(snapshot.historicalSummaries[0])
        XCTAssertEqual(encoded["isComplete"] as? Bool, true)
        XCTAssertNil(encoded["isClosed"])
    }

    func testOldSummariesWithoutFiberStillDecodeAndMalformedStateFails() throws {
        let fixture = CompanionTestFixture.history(on: .now)
        var day = try payload(fixture.days[0])
        var summaries = try XCTUnwrap(day["summaries"] as? [[String: Any]])
        var totals = try XCTUnwrap(summaries[0]["totals"] as? [String: Any])
        totals.removeValue(forKey: "fiber"); summaries[0]["totals"] = totals; day["summaries"] = summaries
        let snapshot = try BackendDiary.decode(wire([["id": UUID().uuidString, "kind": "day", "version": 1, "payload": day]]))
        XCTAssertNil(snapshot.days[0].summaries[0].totals.fiber.value)
        XCTAssertThrowsError(try BackendDiary.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try BackendDiary.decode(wire([["kind": "entry", "id": "invalid", "version": 1, "payload": [:]]])))
    }
    func testAccountSwitchLoadsOnlyItsOwnCacheAndSignOutClearsVisibleData() throws {
        let first = UUID(); let second = UUID()
        let url = BackendDiary.cacheURL(owner: first)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = CompanionTestFixture.history(on: .now)
        try JSONEncoder().encode(fixture).write(to: url)
        let store = NutritionStore(persistence: NutritionFileRepository(fileURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        store.selectAccount(first.uuidString)
        XCTAssertEqual(store.snapshot.entries, fixture.entries)
        store.selectAccount(second.uuidString)
        XCTAssertTrue(store.snapshot.entries.isEmpty)
        store.selectAccount(first.uuidString)
        XCTAssertEqual(store.snapshot.entries, fixture.entries)
        store.selectAccount(nil)
        XCTAssertTrue(store.snapshot.entries.isEmpty)
        XCTAssertNil(store.ownerID)
    }
    func testUploadedHealthWeightPreservesSourceIDWithoutImportBatch() throws {
        let id = UUID(); let sampleID = UUID()
        let snapshot = try BackendDiary.decode(wire([["kind": "weight", "id": id.uuidString, "version": 1,
            "payload": ["id": id.uuidString, "recordedAt": "2026-10-12T08:00:00-03:00", "kilograms": 80.5,
                "source": "appleHealth", "sourceSampleID": sampleID.uuidString, "notes": "", "importBatchID": NSNull()]]]))
        XCTAssertEqual(snapshot.weights.count, 1)
        XCTAssertEqual(snapshot.weights[0].source, .appleHealth)
        XCTAssertEqual(snapshot.weights[0].sourceSampleID, sampleID)
        XCTAssertEqual(snapshot.weights[0].kilograms, 80.5)
        XCTAssertTrue(snapshot.importBatches.isEmpty)
        var health = HealthSnapshot()
        health.samples = [HealthSampleRecord(id: sampleID, metric: .weight, startDate: .now, endDate: .now,
            value: 80.5, sourceName: "Fixture", sourceBundleIdentifier: "fixture", deviceName: nil, workoutActivityCode: nil)]
        XCTAssertTrue(TrackingBridge.accountWeights(manual: snapshot, health: health).isEmpty)
        health.samples = []
        XCTAssertEqual(TrackingBridge.accountWeights(manual: snapshot, health: health).count, 1)
    }
}

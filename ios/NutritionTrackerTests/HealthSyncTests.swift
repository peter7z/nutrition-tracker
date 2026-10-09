import XCTest
import HealthKit
@testable import nutrition_tracker

@MainActor final class HealthSyncTests: XCTestCase {
    private let today = Date(timeIntervalSince1970: 1_791_475_200)
    private func configuration(_ metrics: Set<HealthMetric> = [.weight]) -> HealthImportConfiguration {
        HealthImportConfiguration(metrics: metrics, startDate: nil, timeZoneIdentifier: "America/Montevideo")
    }
    private func sample(id: UUID = UUID(), metric: HealthMetric = .weight, value: Double = 76) -> HealthSampleRecord {
        HealthSampleRecord(id: id, metric: metric, startDate: today, endDate: today, value: value, sourceName: "Test source", sourceBundleIdentifier: "test.source", deviceName: nil, workoutActivityCode: nil)
    }
    private func delta(_ samples: [HealthSampleRecord] = [], deleted: [UUID] = [], anchor: UInt8 = 1, more: Bool = false) -> HealthDelta {
        HealthDelta(samples: samples, deletedIDs: deleted, anchor: Data([anchor]), hasMore: more)
    }

    func testPreviewDoesNotPersistAndCancelDoesNotAdvanceAnchor() async {
        let client = FakeHealthClient(); let store = MemoryHealthPersistence()
        client.deltas = [delta([sample()])]
        let model = HealthSyncModel(client: client, persistence: store, now: { self.today })
        await model.prepareImport(configuration: configuration())
        XCTAssertEqual(model.stagedImport?.snapshot.samples.count, 1)
        XCTAssertTrue(model.snapshot.samples.isEmpty)
        XCTAssertEqual(store.saveCount, 0)
        model.discardImport()
        XCTAssertNil(model.stagedImport)
        XCTAssertTrue(store.snapshot.anchors.isEmpty)
    }

    func testPaginationRetriesAndSameTimestampPreserveDistinctUUIDs() async {
        let first = sample(); let second = sample()
        let client = FakeHealthClient(); let store = MemoryHealthPersistence()
        client.deltas = [delta([first], anchor: 1, more: true), delta([first, second], anchor: 2)]
        let model = HealthSyncModel(client: client, persistence: store, now: { self.today })
        await model.prepareImport(configuration: configuration())
        model.confirmImport()
        XCTAssertEqual(model.snapshot.samples.count, 2)
        XCTAssertEqual(model.snapshot.anchors[HealthMetric.weight.rawValue], Data([2]))
        XCTAssertEqual(client.receivedAnchors, [nil, Data([1])])
        client.deltas = [delta([first, second], anchor: 3)]
        await model.refreshIfConnected()
        XCTAssertEqual(model.snapshot.samples.count, 2)
        XCTAssertEqual(client.authorizations, 1, "Foreground refresh must not prompt for permissions")
    }

    func testMergedDailyTotalsAreUsedInsteadOfAddingOverlappingSources() async {
        let client = FakeHealthClient(); let store = MemoryHealthPersistence()
        client.deltas = [delta([sample(metric: .steps, value: 4_000), sample(metric: .steps, value: 5_000)])]
        let day = configuration().calendar.startOfDay(for: today)
        client.statistics = [HealthDayValue(metric: .steps, date: day, value: 5_400, sourceNames: ["iPhone", "Watch"])]
        let model = HealthSyncModel(client: client, persistence: store, now: { self.today })
        await model.prepareImport(configuration: configuration([.steps]))
        model.confirmImport()
        XCTAssertEqual(model.snapshot.value(for: .steps, on: today), 5_400)
        XCTAssertNil(model.snapshot.value(for: .dietaryEnergy, on: today))
    }

    func testDeletionRecomputesTotalsAndMissingValuesStayUnknown() async {
        let record = sample(metric: .steps, value: 500)
        let client = FakeHealthClient(); let store = MemoryHealthPersistence()
        client.deltas = [delta([record])]
        client.statistics = [HealthDayValue(metric: .steps, date: configuration().calendar.startOfDay(for: today), value: 500, sourceNames: ["Test"])]
        let model = HealthSyncModel(client: client, persistence: store, now: { self.today })
        await model.prepareImport(configuration: configuration([.steps]))
        model.confirmImport()
        client.deltas = [delta(deleted: [record.id], anchor: 2)]; client.statistics = []
        await model.refreshIfConnected()
        XCTAssertTrue(model.snapshot.samples.isEmpty)
        XCTAssertNil(model.snapshot.value(for: .steps, on: today))
        XCTAssertEqual(store.snapshot.anchors[HealthMetric.steps.rawValue], Data([2]))
    }

    func testFailedSaveDoesNotPublishSamplesOrAdvanceCursor() async {
        let client = FakeHealthClient(); let store = MemoryHealthPersistence()
        client.deltas = [delta([sample()])]
        let model = HealthSyncModel(client: client, persistence: store, now: { self.today })
        await model.prepareImport(configuration: configuration())
        store.shouldFail = true
        model.confirmImport()
        XCTAssertFalse(model.snapshot.isConnected)
        XCTAssertTrue(model.snapshot.anchors.isEmpty)
        XCTAssertTrue(store.snapshot.anchors.isEmpty)
        XCTAssertNotNil(model.stagedImport)
        store.shouldFail = false
        model.confirmImport()
        XCTAssertTrue(model.snapshot.isConnected)
        XCTAssertEqual(model.snapshot.samples.count, 1)
    }

    func testFailedSyncPreservesLastSuccessfulSnapshot() async {
        let client = FakeHealthClient(); let store = MemoryHealthPersistence()
        client.deltas = [delta([sample()])]
        let model = HealthSyncModel(client: client, persistence: store, now: { self.today })
        await model.prepareImport(configuration: configuration()); model.confirmImport()
        let previous = model.snapshot
        client.deltas = [delta([sample()], anchor: 2)]
        store.shouldFail = true
        await model.refreshIfConnected()
        XCTAssertEqual(model.snapshot, previous)
        XCTAssertEqual(store.snapshot, previous)
        XCTAssertNotNil(model.errorKey)
    }

    func testEmptyAuthorizationResultDoesNotInventPermissionOrData() async {
        let client = FakeHealthClient(); let store = MemoryHealthPersistence()
        client.deltas = [delta()]
        let model = HealthSyncModel(client: client, persistence: store, now: { self.today })
        await model.prepareImport(configuration: configuration())
        model.confirmImport()
        XCTAssertTrue(model.snapshot.isConnected) // Configured connection, not an assertion of read permission.
        XCTAssertTrue(model.snapshot.samples.isEmpty)
        XCTAssertNil(model.snapshot.latestWeight(before: today))
        XCTAssertNil(model.snapshot.value(for: .dietaryEnergy, on: today))
    }

    func testDisconnectStopsLateSyncFromRestoringData() async {
        let client = FakeHealthClient(); let store = MemoryHealthPersistence()
        client.deltas = [delta([sample()])]
        let model = HealthSyncModel(client: client, persistence: store, now: { self.today })
        await model.prepareImport(configuration: configuration()); model.confirmImport()
        client.pauseNext = true
        let started = expectation(description: "Sync query started")
        client.onPause = { started.fulfill() }
        let work = Task { await model.refreshIfConnected() }
        await fulfillment(of: [started], timeout: 2)
        guard client.waiting != nil else { work.cancel(); return }
        model.disconnect(removeLocalCopy: true)
        client.waiting?.resume(returning: delta([sample()], anchor: 2)); client.waiting = nil
        await work.value
        XCTAssertFalse(model.snapshot.isConnected)
        XCTAssertTrue(model.snapshot.samples.isEmpty)
        XCTAssertTrue(store.snapshot.anchors.isEmpty)
    }

    func testReconfigurationReplacesSelectionOnlyAfterConfirmation() async {
        let client = FakeHealthClient(); let store = MemoryHealthPersistence()
        client.deltas = [delta([sample()])]
        let model = HealthSyncModel(client: client, persistence: store, now: { self.today })
        await model.prepareImport(configuration: configuration()); model.confirmImport()
        let previous = model.snapshot
        client.deltas = [delta([sample(metric: .steps, value: 10)])]
        await model.prepareImport(configuration: configuration([.steps]))
        XCTAssertEqual(model.snapshot, previous)
        model.confirmImport()
        XCTAssertEqual(model.snapshot.samples.map(\.metric), [.steps])
        XCTAssertNil(model.snapshot.anchors[HealthMetric.weight.rawValue])
    }

    func testLocalDayBoundaryUsesProfileTimeZoneAndZeroIsARealValue() {
        var snapshot = HealthSnapshot(); snapshot.configuration = configuration()
        let midnightUTC = ISO8601DateFormatter().date(from: "2026-10-08T01:00:00Z")!
        let localDay = configuration().calendar.startOfDay(for: midnightUTC)
        snapshot.dailyValues = [HealthDayValue(metric: .dietaryEnergy, date: localDay, value: 0, sourceNames: ["Test"])]
        XCTAssertEqual(snapshot.value(for: .dietaryEnergy, on: midnightUTC), 0)
        XCTAssertNil(snapshot.value(for: .dietaryEnergy, on: midnightUTC.addingTimeInterval(4 * 3_600)))
    }

    func testFileRoundTripAndCorruptionAreNotSilentlyOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("health.json")
        let repository = HealthFileRepository(fileURL: url)
        var snapshot = HealthSnapshot(); snapshot.samples = [sample()]; snapshot.anchors = ["weight": Data([42])]
        try repository.save(snapshot)
        XCTAssertEqual(try repository.load(), snapshot)
        try Data("invalid-json".utf8).write(to: url)
        XCTAssertThrowsError(try repository.load())
        let model = HealthSyncModel(client: FakeHealthClient(), persistence: repository)
        XCTAssertTrue(model.storageNeedsRecovery)
        XCTAssertEqual(try Data(contentsOf: url), Data("invalid-json".utf8))
    }

    func testHealthKitUnitConversionsAndOpaqueAnchorRoundTrip() throws {
        XCTAssertEqual(HKQuantity(unit: .pound(), doubleValue: 180).doubleValue(for: HealthMetric.weight.healthUnit), 81.6466266, accuracy: 0.00001)
        XCTAssertEqual(HKQuantity(unit: .jouleUnit(with: .kilo), doubleValue: 418.4).doubleValue(for: HealthMetric.dietaryEnergy.healthUnit), 100, accuracy: 0.00001)
        XCTAssertEqual(HKQuantity(unit: .second(), doubleValue: 90).doubleValue(for: HealthMetric.exerciseMinutes.healthUnit), 1.5)
        let encoded = try NSKeyedArchiver.archivedData(withRootObject: HKQueryAnchor(fromValue: 50), requiringSecureCoding: true)
        XCTAssertNotNil(try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: encoded))
        for metric in HealthMetric.allCases { XCTAssertNotNil(try metric.sampleType) }
    }

    func testDisconnectKeepsCopyAndGoalsWithoutFurtherQueries() async {
        let client = FakeHealthClient(); let store = MemoryHealthPersistence()
        client.deltas = [delta([sample()])]
        let model = HealthSyncModel(client: client, persistence: store, now: { self.today })
        let goals = NutritionGoals(energy: 2000, protein: 100, carbohydrates: 200, fat: 70)
        model.saveGoals(goals)
        await model.prepareImport(configuration: configuration()); model.confirmImport()
        model.disconnect(removeLocalCopy: false)
        let calls = client.receivedAnchors.count
        await model.refreshIfConnected()
        XCTAssertEqual(client.receivedAnchors.count, calls)
        XCTAssertEqual(model.snapshot.samples.count, 1)
        model.disconnect(removeLocalCopy: true)
        XCTAssertTrue(model.snapshot.samples.isEmpty)
        XCTAssertNil(model.snapshot.configuration)
        XCTAssertEqual(model.snapshot.goals, goals)
    }

    func testWorkoutAndActiveEnergyAreSeparateFromDietaryEnergy() async {
        let client = FakeHealthClient(); let store = MemoryHealthPersistence()
        client.deltas = [delta([sample(metric: .activeEnergy, value: 600)]), delta([sample(metric: .workout, value: 45)]), delta([sample(metric: .dietaryEnergy, value: 1200)])]
        let day = configuration().calendar.startOfDay(for: today)
        client.statistics = [HealthDayValue(metric: .activeEnergy, date: day, value: 600, sourceNames: ["Watch"]), HealthDayValue(metric: .dietaryEnergy, date: day, value: 1200, sourceNames: ["Test"])]
        let model = HealthSyncModel(client: client, persistence: store, now: { self.today })
        await model.prepareImport(configuration: configuration([.activeEnergy, .workout, .dietaryEnergy])); model.confirmImport()
        XCTAssertEqual(model.snapshot.value(for: .dietaryEnergy, on: today), 1200)
        XCTAssertEqual(model.snapshot.value(for: .activeEnergy, on: today), 600)
        XCTAssertNil(model.snapshot.value(for: .workout, on: today))
    }

    func testInvalidSamplesAndUnconfirmedGoalsCannotBecomeData() async {
        let client = FakeHealthClient(); let store = MemoryHealthPersistence()
        client.deltas = [delta([sample(value: -1)])]
        let model = HealthSyncModel(client: client, persistence: store, now: { self.today })
        await model.prepareImport(configuration: configuration())
        XCTAssertNil(model.stagedImport)
        XCTAssertTrue(store.snapshot.samples.isEmpty)
        XCTAssertNil(model.snapshot.goals)
        model.saveGoals(NutritionGoals(energy: 0, protein: 100, carbohydrates: 200, fat: 50))
        XCTAssertNil(model.snapshot.goals)
    }

    func testStalledPaginationCannotCommitPartialData() async {
        let client = FakeHealthClient(); let store = MemoryHealthPersistence()
        client.deltas = [delta([sample()], anchor: 1, more: true), delta(anchor: 1, more: true)]
        let model = HealthSyncModel(client: client, persistence: store, now: { self.today })
        await model.prepareImport(configuration: configuration())
        XCTAssertNil(model.stagedImport)
        XCTAssertTrue(store.snapshot.samples.isEmpty)
        XCTAssertNotNil(model.errorKey)
    }
}

@MainActor private final class MemoryHealthPersistence: HealthPersistence {
    var snapshot = HealthSnapshot()
    var shouldFail = false
    var saveCount = 0
    func load() throws -> HealthSnapshot { snapshot }
    func save(_ value: HealthSnapshot) throws {
        if shouldFail { throw HealthOperationError.invalidData }
        snapshot = value; saveCount += 1
    }
}

@MainActor private final class FakeHealthClient: HealthDataClient {
    var isAvailable = true
    var authorizations = 0
    var deltas: [HealthDelta] = []
    var statistics: [HealthDayValue] = []
    var receivedAnchors: [Data?] = []
    var pauseNext = false
    var onPause: (() -> Void)?
    var waiting: CheckedContinuation<HealthDelta, Error>?
    func requestReadAccess(to metrics: Set<HealthMetric>) async throws { authorizations += 1 }
    func changes(for metric: HealthMetric, start: Date?, anchor: Data?) async throws -> HealthDelta {
        receivedAnchors.append(anchor)
        if pauseNext {
            pauseNext = false
            return try await withCheckedThrowingContinuation { waiting = $0; onPause?() }
        }
        guard !deltas.isEmpty else { throw HealthOperationError.invalidData }
        return deltas.removeFirst()
    }
    func dailyStatistics(for metric: HealthMetric, start: Date, end: Date, calendar: Calendar) async throws -> [HealthDayValue] {
        statistics.filter { $0.metric == metric }
    }
}

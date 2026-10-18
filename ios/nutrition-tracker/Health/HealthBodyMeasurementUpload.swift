import Foundation
import HealthKit
import Observation

private struct BodyMeasurementSyncPreference: Codable {
    var enabled = false
    var lastSyncDate: Date?
}

/// Exports the navel waist value to HealthKit's single waist-circumference type.
/// Other body measurements remain in Bocado because HealthKit has no matching types.
@MainActor @Observable final class HealthBodyMeasurementUpload {
    private let store = HKHealthStore()
    private let root: URL
    private var preference = BodyMeasurementSyncPreference()
    private(set) var ownerID: String?
    private(set) var isWorking = false
    private(set) var errorKey: String?

    var isEnabled: Bool { preference.enabled }
    var lastSyncDate: Date? { preference.lastSyncDate }
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appendingPathComponent("NutritionTracker/BodyMeasurementUpload", isDirectory: true)
    }

    func selectAccount(_ owner: String?) {
        guard owner != ownerID else { return }
        ownerID = owner
        preference = BodyMeasurementSyncPreference()
        errorKey = nil
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do { preference = try JSONDecoder().decode(BodyMeasurementSyncPreference.self, from: Data(contentsOf: fileURL)) }
        catch { errorKey = "Could not read body measurement sync settings. Apple Health was not changed." }
    }

    func enable(account: AccountSession) async {
        selectAccount(account.session?.user_id)
        guard ownerID != nil, !isWorking, isAvailable,
              let type = HKObjectType.quantityType(forIdentifier: .waistCircumference) else { return }
        isWorking = true; errorKey = nil
        defer { isWorking = false }
        do {
            try await store.requestAuthorization(toShare: [type], read: [])
            guard account.session?.user_id == ownerID else { return }
            preference.enabled = true
            try savePreference()
            isWorking = false
            await sync(account: account)
        } catch {
            errorKey = "Could not enable waist sync to Apple Health. Check Health access and try again."
        }
    }

    func disable() {
        preference.enabled = false
        do { try savePreference(); errorKey = nil }
        catch { errorKey = "Could not save body measurement sync settings. Try again." }
    }

    func sync(account: AccountSession) async {
        selectAccount(account.session?.user_id)
        guard preference.enabled, let ownerID, UUID(uuidString: ownerID) != nil,
              !isWorking, isAvailable,
              let type = HKObjectType.quantityType(forIdentifier: .waistCircumference) else { return }
        isWorking = true; errorKey = nil
        defer { isWorking = false }
        do {
            let data = try await account.fetchDiary()
            guard account.session?.user_id == ownerID else { return }
            let desired = try desiredSamples(data: data, ownerID: ownerID, type: type)
            let existing = try await ownSamples(type: type).reduce(into: [String: Int]()) { versions, sample in
                if let key = sample.metadata?[Self.recordKey] as? String {
                    versions[key] = max(versions[key] ?? 0, sample.metadata?[HKMetadataKeySyncVersion] as? Int ?? 0)
                }
            }
            let updates = desired.filter { key, sample in
                (existing[key] ?? 0) < (sample.metadata?[HKMetadataKeySyncVersion] as? Int ?? 1)
            }.map(\.value)
            if !updates.isEmpty { try await store.save(updates) }
            guard account.session?.user_id == ownerID else { return }
            preference.lastSyncDate = .now
            try savePreference()
        } catch is CancellationError { }
        catch { errorKey = "Could not sync body measurements to Apple Health. Check Health access and try again." }
    }

    private static let sourceKey = "NutritionTrackerGeneratedBy"
    private static let sourceValue = "Bocado Log"
    private static let recordKey = "NutritionTrackerBodyMeasurementRecordKey"

    private func desiredSamples(data: Data, ownerID: String, type: HKQuantityType) throws -> [String: HKQuantitySample] {
        guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = state["records"] as? [[String: Any]] else { throw AccountError.request }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var desired: [String: HKQuantitySample] = [:]
        for record in records where record["kind"] as? String == "body_measurement" {
            guard let id = record["id"] as? String,
                  let payload = record["payload"] as? [String: Any],
                  let stamp = payload["recorded_at"] as? String,
                  let date = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp),
                  let value = payload["waist_navel_cm"] as? Double, value.isFinite, value > 0, value < 400 else { continue }
            let key = "\(ownerID):\(id):waist_navel_cm"
            let version = record["version"] as? Int ?? 1
            let metadata: [String: Any] = [Self.sourceKey: Self.sourceValue, Self.recordKey: key,
                "NutritionTrackerMeasurementSite": "navel", HKMetadataKeySyncIdentifier: key,
                HKMetadataKeySyncVersion: version]
            desired[key] = HKQuantitySample(type: type,
                quantity: HKQuantity(unit: .meterUnit(with: .centi), doubleValue: value),
                start: date, end: date, metadata: metadata)
        }
        return desired
    }

    private func ownSamples(type: HKQuantityType) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForObjects(withMetadataKey: Self.sourceKey, allowedValues: [Self.sourceValue])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
            }
            store.execute(query)
        }
    }

    private var fileURL: URL? {
        ownerID.flatMap(UUID.init(uuidString:)).map { root.appendingPathComponent($0.uuidString + ".json") }
    }

    private func savePreference() throws {
        guard let fileURL else { throw AccountError.storage }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var folder = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        try JSONEncoder().encode(preference).write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

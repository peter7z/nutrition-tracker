import Foundation
import HealthKit
import Observation

private struct NutritionUploadPreference: Codable {
    var enabled = false
    var lastSyncDate: Date?
}

private struct NutritionHealthValue {
    var metric: HealthMetric
    var value: Double
}

@MainActor @Observable final class HealthNutritionUpload {
    private let store = HKHealthStore()
    private let root: URL
    private(set) var ownerID: String?
    private(set) var isWorking = false
    private(set) var errorKey: String?
    private var preference = NutritionUploadPreference()

    var isEnabled: Bool { preference.enabled }
    var lastSyncDate: Date? { preference.lastSyncDate }
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appendingPathComponent("NutritionTracker/NutritionHealthUpload", isDirectory: true)
    }

    func selectAccount(_ owner: String?) {
        guard ownerID != owner else { return }
        ownerID = owner
        preference = NutritionUploadPreference()
        errorKey = nil
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do { preference = try JSONDecoder().decode(NutritionUploadPreference.self, from: Data(contentsOf: fileURL)) }
        catch { errorKey = "Could not read nutrition sync settings. Your Health data was not changed." }
    }

    func enable(account: AccountSession, entries: [FoodEntry]) async {
        selectAccount(account.session?.user_id)
        guard ownerID != nil, !isWorking, isAvailable else { return }
        isWorking = true
        errorKey = nil
        defer { isWorking = false }
        do {
            let shareTypes = try Set(HealthMetric.nutritionWriteMetrics.map { try $0.sampleType })
            let readTypes = Set(shareTypes.map { $0 as HKObjectType })
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            guard account.session?.user_id == ownerID else { return }
            preference.enabled = true
            try savePreference()
            try await synchronize(entries: entries)
            guard account.session?.user_id == ownerID else { return }
            preference.lastSyncDate = .now
            try savePreference()
        } catch is CancellationError { }
        catch {
            errorKey = "Could not sync nutrition to Apple Health. Check Health access and try again."
        }
    }

    func disable() {
        preference.enabled = false
        do { try savePreference(); errorKey = nil }
        catch { errorKey = "Could not save nutrition sync settings. Try again." }
    }

    func syncIfEnabled(entries: [FoodEntry], owner: String?) async {
        selectAccount(owner)
        guard preference.enabled else { return }
        await sync(entries: entries)
    }

    func sync(entries: [FoodEntry]) async {
        guard preference.enabled, let syncOwner = ownerID, !isWorking, isAvailable else { return }
        isWorking = true
        errorKey = nil
        defer { isWorking = false }
        do {
            try await synchronize(entries: entries)
            guard ownerID == syncOwner else { return }
            preference.lastSyncDate = .now
            try savePreference()
        } catch is CancellationError { }
        catch {
            errorKey = "Could not sync nutrition to Apple Health. Check Health access and try again."
        }
    }

    private var fileURL: URL? {
        ownerID.flatMap(UUID.init(uuidString:)).map { root.appendingPathComponent($0.uuidString + ".json") }
    }

    private func savePreference() throws {
        guard let fileURL else { throw HealthOperationError.invalidConfiguration }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var folder = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        try JSONEncoder().encode(preference).write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private func synchronize(entries: [FoodEntry]) async throws {
        guard let ownerID, UUID(uuidString: ownerID) != nil else { throw HealthOperationError.invalidConfiguration }
        let desired = desiredRecords(entries: entries, ownerID: ownerID)
        var existing: [String: [HKQuantitySample]] = [:]
        for metric in HealthMetric.nutritionWriteMetrics {
            for sample in try await ownSamples(for: metric) {
                guard self.ownerID == ownerID else { throw CancellationError() }
                guard let key = sample.metadata?[Self.recordKey] as? String else { continue }
                guard key.hasPrefix("\(ownerID):") else { continue }
                existing[key, default: []].append(sample)
            }
        }

        var toSave: [HKQuantitySample] = []
        var toDelete: [HKQuantitySample] = []
        for (key, samples) in existing {
            guard let wanted = desired[key] else { toDelete.append(contentsOf: samples); continue }
            let matching = samples.first { $0.metadata?[Self.fingerprintKey] as? String == wanted.fingerprint }
            if matching == nil { toSave.append(wanted.sample) }
            toDelete.append(contentsOf: samples.filter { sample in
                guard let matching else { return true }
                return sample.uuid != matching.uuid
            })
        }
        for (key, wanted) in desired where existing[key] == nil { toSave.append(wanted.sample) }

        // Save replacements before deleting old versions. A failed save therefore keeps the old Health records.
        if !toSave.isEmpty { try await store.save(toSave.map { $0 as HKObject }) }
        guard self.ownerID == ownerID else { throw CancellationError() }
        if !toDelete.isEmpty { try await store.delete(toDelete.map { $0 as HKObject }) }
    }

    private struct DesiredRecord {
        var sample: HKQuantitySample
        var fingerprint: String
    }

    // Persisted metadata stays stable across app renames so existing samples are recognized.
    private static let sourceKey = "NutritionTrackerGeneratedBy"
    private static let sourceValue = "Bocado Log"
    private static let recordKey = "NutritionTrackerRecordKey"
    private static let fingerprintKey = "NutritionTrackerFingerprint"

    private func desiredRecords(entries: [FoodEntry], ownerID: String) -> [String: DesiredRecord] {
        var result: [String: DesiredRecord] = [:]
        for entry in entries where !entry.deleted {
            let values = entry.values
            let nutrients: [NutritionHealthValue] = [
                values.energy.map { NutritionHealthValue(metric: .dietaryEnergy, value: $0) },
                values.protein.map { NutritionHealthValue(metric: .protein, value: $0) },
                values.carbohydrates.map { NutritionHealthValue(metric: .carbohydrates, value: $0) },
                values.fat.map { NutritionHealthValue(metric: .fat, value: $0) },
                values.saturatedFat.map { NutritionHealthValue(metric: .saturatedFat, value: $0) },
                values.fiber.map { NutritionHealthValue(metric: .fiber, value: $0) },
                values.vitaminA.map { NutritionHealthValue(metric: .vitaminA, value: $0) },
                values.thiamin.map { NutritionHealthValue(metric: .thiamin, value: $0) },
                values.riboflavin.map { NutritionHealthValue(metric: .riboflavin, value: $0) },
                values.niacin.map { NutritionHealthValue(metric: .niacin, value: $0) },
                values.pantothenicAcid.map { NutritionHealthValue(metric: .pantothenicAcid, value: $0) },
                values.vitaminB6.map { NutritionHealthValue(metric: .vitaminB6, value: $0) },
                values.biotin.map { NutritionHealthValue(metric: .biotin, value: $0) },
                values.vitaminB12.map { NutritionHealthValue(metric: .vitaminB12, value: $0) },
                values.vitaminC.map { NutritionHealthValue(metric: .vitaminC, value: $0) },
                values.vitaminD.map { NutritionHealthValue(metric: .vitaminD, value: $0) },
                values.vitaminE.map { NutritionHealthValue(metric: .vitaminE, value: $0) },
                values.vitaminK.map { NutritionHealthValue(metric: .vitaminK, value: $0) },
                values.folate.map { NutritionHealthValue(metric: .folate, value: $0) },
                values.calcium.map { NutritionHealthValue(metric: .calcium, value: $0) },
                values.chloride.map { NutritionHealthValue(metric: .chloride, value: $0) },
                values.iron.map { NutritionHealthValue(metric: .iron, value: $0) },
                values.magnesium.map { NutritionHealthValue(metric: .magnesium, value: $0) },
                values.phosphorus.map { NutritionHealthValue(metric: .phosphorus, value: $0) },
                values.potassium.map { NutritionHealthValue(metric: .potassium, value: $0) },
                values.sodium.map { NutritionHealthValue(metric: .sodium, value: $0) },
                values.zinc.map { NutritionHealthValue(metric: .zinc, value: $0) },
                values.chromium.map { NutritionHealthValue(metric: .chromium, value: $0) },
                values.copper.map { NutritionHealthValue(metric: .copper, value: $0) },
                values.iodine.map { NutritionHealthValue(metric: .iodine, value: $0) },
                values.manganese.map { NutritionHealthValue(metric: .manganese, value: $0) },
                values.molybdenum.map { NutritionHealthValue(metric: .molybdenum, value: $0) },
                values.selenium.map { NutritionHealthValue(metric: .selenium, value: $0) }
            ].compactMap { $0 }

            for nutrient in nutrients where nutrient.value.isFinite && nutrient.value >= 0 {
                guard let type = try? nutrient.metric.sampleType as? HKQuantityType else { continue }
                let key = "\(ownerID):\(entry.id.uuidString):\(nutrient.metric.rawValue)"
                let amount = String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), nutrient.value)
                let fingerprint = "\(entry.draft.consumedAt.timeIntervalSince1970)|\(amount)|\(entry.draft.mealName)"
                let quantity = HKQuantity(unit: nutrient.metric.healthUnit, doubleValue: nutrient.value)
                let metadata: [String: Any] = [
                    Self.sourceKey: Self.sourceValue,
                    Self.recordKey: key,
                    Self.fingerprintKey: fingerprint,
                    HKMetadataKeyFoodType: entry.draft.mealName
                ]
                let sample = HKQuantitySample(type: type, quantity: quantity,
                    start: entry.draft.consumedAt, end: entry.draft.consumedAt, metadata: metadata)
                result[key] = DesiredRecord(sample: sample, fingerprint: fingerprint)
            }
        }
        return result
    }

    private func ownSamples(for metric: HealthMetric) async throws -> [HKQuantitySample] {
        guard let type = try metric.sampleType as? HKQuantityType else { return [] }
        let predicate = HKQuery.predicateForObjects(withMetadataKey: Self.sourceKey, allowedValues: [Self.sourceValue])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
            }
            store.execute(query)
        }
    }
}

private extension HealthMetric { static var nutritionWriteMetrics: [HealthMetric] { Array(nutritionMetrics) } }

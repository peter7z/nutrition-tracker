import Foundation
import Observation

struct WeightPermission: Codable { var enabled: Bool; var version: Int }
struct UploadedWeight: Codable { var sample_id: UUID; var recorded_at: Date; var kilograms: Double }
struct WeightUploadBatch: Codable {
    var request_id: UUID
    var consent_version: Int
    var samples: [UploadedWeight]
    var deleted_ids: [UUID]
}
private struct PendingWeightUpload: Codable { var body: WeightUploadBatch; var nextAnchor: Data }
private struct WeightUploadState: Codable {
    var enabled = false
    var consentVersion = 0
    var anchor: Data?
    var pending: PendingWeightUpload?
    var pendingRevocation: Bool?
    var lastSyncDate: Date?
}
private struct WeightReceipt: Decodable { var saved: Bool; var request_id: UUID }

@MainActor @Observable final class HealthWeightUpload {
    private var state = WeightUploadState()
    private(set) var ownerID: String?
    private(set) var isWorking = false
    private(set) var errorKey: String?
    private var generation = UUID()
    private let root: URL
    var isEnabled: Bool { state.enabled }
    var lastSyncDate: Date? { state.lastSyncDate }
    init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appendingPathComponent("NutritionTracker/WeightUpload", isDirectory: true)
    }
    private var fileURL: URL? { ownerID.flatMap(UUID.init(uuidString:)).map { root.appendingPathComponent($0.uuidString + ".json") } }
    func selectAccount(_ owner: String?) {
        guard owner != ownerID else { return }
        generation = UUID(); ownerID = owner; state = WeightUploadState(); isWorking = false; errorKey = nil
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do { state = try JSONDecoder().decode(WeightUploadState.self, from: Data(contentsOf: fileURL)) }
        catch { errorKey = "Could not read weight upload state. No weights were uploaded." }
    }
    private func save() throws {
        guard let fileURL else { throw AccountError.storage }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var folder = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        try JSONEncoder().encode(state).write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
    private func body<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    func setConsent(enabled: Bool, deleteData: Bool = false, account: AccountSession, health: HealthSyncModel) async {
        selectAccount(account.session?.user_id)
        guard ownerID != nil, !isWorking else { return }
        let attempt = generation; let owner = ownerID; isWorking = true; errorKey = nil
        defer { if generation == attempt { isWorking = false } }
        do {
            if !enabled {
                state.enabled = false; state.pendingRevocation = deleteData; state.pending = nil
                try save()  // Stop locally even when remote revocation must wait for connectivity.
            }
            let permission: WeightPermission = try await account.weightRequest("v1/health/weight/consent",
                body: JSONSerialization.data(withJSONObject: ["enabled": enabled, "delete_data": deleteData]))
            guard generation == attempt, account.session?.user_id == owner else { return }
            state = WeightUploadState(); state.enabled = permission.enabled; state.consentVersion = permission.version
            try save()
        } catch {
            if generation == attempt { errorKey = "Could not update weight sharing. Retry when connected." }
        }
        // Sync is triggered by the Settings action after the consent operation finishes.
    }
    func sync(account: AccountSession, health: HealthSyncModel) async {
        selectAccount(account.session?.user_id)
        guard ownerID != nil, !isWorking else { return }
        let attempt = generation; let owner = ownerID; isWorking = true; errorKey = nil
        defer { if generation == attempt { isWorking = false } }
        do {
            if let deleteData = state.pendingRevocation {
                let _: WeightPermission = try await account.weightRequest("v1/health/weight/consent",
                    body: JSONSerialization.data(withJSONObject: ["enabled": false, "delete_data": deleteData]))
                guard generation == attempt, account.session?.user_id == owner else { return }
                state = WeightUploadState(); try save(); return
            }
            guard state.enabled else { return }
            let permission: WeightPermission = try await account.weightRequest("v1/health/weight/consent")
            guard generation == attempt, account.session?.user_id == owner else { return }
            if !permission.enabled { state = WeightUploadState(); try save(); return }
            if permission.version != state.consentVersion {
                state.anchor = nil; state.pending = nil; state.consentVersion = permission.version; try save()
            }
            guard health.snapshot.isConnected, health.snapshot.configuration?.metrics.contains(.weight) == true else { return }
            var hasMore = true
            while hasMore {
                try Task.checkCancellation()
                if state.pending == nil {
                    let delta = try await health.weightUploadChanges(anchor: state.anchor)
                    guard generation == attempt, account.session?.user_id == owner else { return }
                    guard delta.samples.allSatisfy({ $0.metric == .weight && $0.value.isFinite && $0.value > 0 && $0.value < 1000 }),
                          !delta.hasMore || delta.anchor != state.anchor else { throw HealthOperationError.invalidData }
                    hasMore = delta.hasMore
                    if delta.samples.isEmpty && delta.deletedIDs.isEmpty {
                        state.anchor = delta.anchor; state.lastSyncDate = .now; try save()
                        continue
                    }
                    state.pending = PendingWeightUpload(body: WeightUploadBatch(request_id: UUID(), consent_version: state.consentVersion,
                        samples: delta.samples.map { UploadedWeight(sample_id: $0.id, recorded_at: $0.endDate, kilograms: $0.value) },
                        deleted_ids: delta.deletedIDs), nextAnchor: delta.anchor)
                    try save()  // Persist the identical retry body before any network write.
                }
                guard let pending = state.pending else { return }
                guard health.snapshot.isConnected, health.snapshot.configuration?.metrics.contains(.weight) == true else { return }
                let receipt: WeightReceipt = try await account.weightRequest("v1/health/weight/sync", body: body(pending.body))
                guard generation == attempt, account.session?.user_id == owner else { return }
                guard receipt.saved, receipt.request_id == pending.body.request_id else { throw AccountError.request }
                state.anchor = pending.nextAnchor; state.pending = nil; state.lastSyncDate = .now
                try save()  // Advance only after the server's successful receipt.
            }
        } catch is CancellationError { }
        catch { if generation == attempt { errorKey = "Weight upload is pending. It will retry when connected." } }
    }
}

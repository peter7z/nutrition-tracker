import Foundation
import Observation
import CryptoKit

@MainActor protocol TrackingRemoteTransport {
    var ownerID: String? { get }
    var endpoint: String { get }
    func state() async throws -> RemoteState
    func sync(_ body: RemoteSyncRequest) async throws -> RemoteState
}
extension RemoteSession: TrackingRemoteTransport {}

@MainActor protocol TrackingCheckpointPersistence {
    func load(scope: String) throws -> Data?
    func save(_ data: Data, scope: String) throws
}
@MainActor final class TrackingCheckpointFiles: TrackingCheckpointPersistence {
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NutritionTracker/Sync", isDirectory: true)
    }
    func load(scope: String) throws -> Data? {
        let file = directory.appendingPathComponent(scope + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }
    func save(_ data: Data, scope: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directory = directory; var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        try data.write(to: directory.appendingPathComponent(scope + ".json"), options: [.atomic, .completeFileProtection])
    }
}

private struct TrackingWireRequest: Codable {
    var request_id: String
    var base_revision: Int
    var operations: [RemoteOperation]
    var request: RemoteSyncRequest { RemoteSyncRequest(request_id: request_id, base_revision: base_revision, operations: operations) }
}
private struct TrackingWireState: Codable { var revision: Int; var records: [RemoteRecord]; var messages: [RemoteMessage]? }
private struct TrackingPending: Codable {
    var request: TrackingWireRequest
    var candidate: NutritionSnapshot
    var beforeFingerprint: String
    var remaining: [RemoteOperation] = []
    var batchIndex = 0
    var rootRequestID: String
    var messages: [RemoteMessage]?
    var accepted: TrackingWireState?
    var acceptedFingerprint: String?
}
private struct TrackingCheckpoint: Codable {
    var schemaVersion = 1
    var revision = 0
    var hashes: [String: String] = [:]
    var versions: [String: Int] = [:]
    var pending: TrackingPending?
}

enum TrackingConflictChoice: String { case local, server }
struct TrackingRecordConflict: Identifiable {
    let id: String
    let kind: String
    let local: RemoteRecord?
    let server: RemoteRecord?
}
struct TrackingConflictReview: Identifiable {
    let id = UUID()
    let ownerID: String
    let endpoint: String
    let revision: Int
    let conflicts: [TrackingRecordConflict]
    fileprivate let localFingerprint: String
}

@MainActor @Observable final class TrackingSync {
    private(set) var isWorking = false
    private(set) var errorKey: String?
    private(set) var lastSyncDate: Date?
    @ObservationIgnored private let persistence: any TrackingCheckpointPersistence
    init(persistence: (any TrackingCheckpointPersistence)? = nil) { self.persistence = persistence ?? TrackingCheckpointFiles() }

    func sync(store: NutritionStore, remote: any TrackingRemoteTransport) async throws {
        try await run(proposed: nil, store: store, remote: remote, operationID: UUID())
    }
    /// Keep a staged assistant mutation unpublished until the server acknowledges the entire batch.
    func applyConfirmed(_ proposed: NutritionSnapshot, store: NutritionStore, remote: any TrackingRemoteTransport, operationID: UUID) async throws {
        try NutritionBackup.validate(proposed)
        try await run(proposed: proposed, store: store, remote: remote, operationID: operationID)
    }
    func conflictReview(store: NutritionStore, remote: any TrackingRemoteTransport) async throws -> TrackingConflictReview {
        guard !isWorking, let owner = remote.ownerID else { throw RemoteError.authentication }
        isWorking = true; defer { isWorking = false }
        let endpoint = remote.endpoint
        let local = try Self.records(store.snapshot, owner: owner)
        let fingerprint = try Self.fingerprint(local)
        let checkpoint = try load(Self.hash(Data((endpoint + "|" + owner.lowercased()).utf8)))
        let server = try await remote.state(); try checkOwner(remote, owner: owner, endpoint: endpoint)
        guard fingerprint == (try Self.fingerprint(Self.records(store.snapshot, owner: owner))) else { throw RemoteError.conflict }
        _ = try Self.checkpoint(server.records, revision: server.revision)
        let records = Dictionary(uniqueKeysWithValues: server.records.map { ($0.id.lowercased(), $0) })
        var conflicts: [TrackingRecordConflict] = []
        for key in Set(checkpoint.hashes.keys).union(local.keys).union(records.keys).sorted() {
            let localHash = try local[key].map { try Self.payloadHash($0.payload) }
            let serverHash = try records[key].map { try Self.payloadHash($0.payload) }
            if localHash != checkpoint.hashes[key] && serverHash != checkpoint.hashes[key] && localHash != serverHash {
                conflicts.append(TrackingRecordConflict(id: key, kind: local[key]?.kind ?? records[key]!.kind, local: local[key], server: records[key]))
            }
        }
        return TrackingConflictReview(ownerID: owner, endpoint: endpoint, revision: server.revision, conflicts: conflicts, localFingerprint: fingerprint)
    }
    func resolve(_ review: TrackingConflictReview, choices: [String: TrackingConflictChoice], store: NutritionStore, remote: any TrackingRemoteTransport) async throws {
        guard Set(choices.keys) == Set(review.conflicts.map(\.id)) else { throw RemoteError.conflict }
        try await run(proposed: nil, store: store, remote: remote, operationID: UUID(), review: review, choices: choices)
    }
    /// Call only after the user explicitly chooses the server version in conflict review.
    func replaceLocalWithRemote(store: NutritionStore, remote: any TrackingRemoteTransport) async throws {
        guard !isWorking, let owner = remote.ownerID else { throw RemoteError.authentication }
        isWorking = true; defer { isWorking = false }
        let endpoint = remote.endpoint
        let before = try Self.fingerprint(Self.records(store.snapshot, owner: owner))
        let state = try await remote.state(); try checkOwner(remote, owner: owner, endpoint: endpoint)
        guard try Self.fingerprint(Self.records(store.snapshot, owner: owner)) == before else { throw RemoteError.conflict }
        let checkpoint = try Self.checkpoint(state.records, revision: state.revision)
        let desired = Dictionary(uniqueKeysWithValues: state.records.map { ($0.id.lowercased(), $0) })
        try Self.publish(Self.mergeMessages(state.messages, into: Self.merge(desired, into: store.snapshot), owner: owner), to: store)
        try save(checkpoint, scope: Self.hash(Data((endpoint + "|" + owner.lowercased()).utf8)))
        errorKey = nil; lastSyncDate = Date()
    }
    private func run(proposed: NutritionSnapshot?, store: NutritionStore, remote: any TrackingRemoteTransport, operationID: UUID, review: TrackingConflictReview? = nil, choices: [String: TrackingConflictChoice] = [:]) async throws {
        guard !isWorking else { throw RemoteError.conflict }
        guard let owner = remote.ownerID, !remote.endpoint.isEmpty, !store.storageNeedsRecovery else { throw RemoteError.authentication }
        let endpoint = remote.endpoint
        let scope = Self.hash(Data((endpoint + "|" + owner.lowercased()).utf8))
        isWorking = true; errorKey = nil
        defer { isWorking = false }
        do {
            var checkpoint = try load(scope)
            let original = store.snapshot
            let before = try Self.records(original, owner: owner)
            let beforeFingerprint = try Self.fingerprint(before)
            if let review {
                guard review.ownerID == owner, review.endpoint == endpoint, review.localFingerprint == beforeFingerprint else { throw RemoteError.conflict }
                // Explicit review supersedes an old pending request only after a fresh state proves its revision.
            }
            if checkpoint.pending == nil || review != nil {
                let server = try await remote.state()
                try checkOwner(remote, owner: owner, endpoint: endpoint)
                guard try Self.fingerprint(Self.records(store.snapshot, owner: owner)) == beforeFingerprint else { throw RemoteError.conflict }
                if let review { guard server.revision == review.revision else { throw RemoteError.conflict }; checkpoint.pending = nil }
                guard Set(server.records.map { $0.id.lowercased() }).count == server.records.count else { throw RemoteError.invalidResponse }
                var local = try Self.records(proposed ?? original, owner: owner)
                let remoteRecords = Dictionary(uniqueKeysWithValues: server.records.map { ($0.id.lowercased(), $0) })
                // A new account-scoped file starts with an untouched default profile. Prefer its existing remote profile.
                let profileID = Self.stableID("profile/" + owner.lowercased()).uuidString.lowercased()
                if checkpoint.hashes.isEmpty, original.profile == NutritionProfile(), proposed == nil, remoteRecords[profileID] != nil { local.removeValue(forKey: profileID) }
                var desired = remoteRecords
                for key in Set(checkpoint.hashes.keys).union(local.keys).union(remoteRecords.keys) {
                    let baseHash = checkpoint.hashes[key]
                    let localHash = try local[key].map { try Self.payloadHash($0.payload) }
                    let remoteHash = try remoteRecords[key].map { try Self.payloadHash($0.payload) }
                    let localChanged = localHash != baseHash
                    let remoteChanged = remoteHash != baseHash
                    if localChanged && remoteChanged && localHash != remoteHash {
                        guard let choice = choices[key] else { throw RemoteError.conflict }
                        if choice == .server { continue }
                        var chosen = local[key]
                        // A chosen local domain revision must advance beyond its current server revision.
                        if var record = chosen, case .object(var payload) = record.payload,
                           case .number(let localVersion)? = payload["version"],
                           let serverRecord = remoteRecords[key], case .object(let serverPayload) = serverRecord.payload,
                           case .number(let serverVersion)? = serverPayload["version"], localVersion <= serverVersion {
                            payload["version"] = .number(serverVersion + 1)
                            record.payload = .object(payload); chosen = record
                        }
                        desired[key] = chosen
                    } else if localChanged { desired[key] = local[key] }
                }
                var candidate = try Self.mergeMessages(server.messages, into: Self.merge(desired, into: store.snapshot), owner: owner)
                if let proposed {
                    candidate.changes = proposed.changes
                    let stagedIDs = Set(proposed.operations.map(\.id))
                    candidate.operations = proposed.operations + store.snapshot.operations.filter { !stagedIDs.contains($0.id) }
                }
                var operations: [RemoteOperation] = []
                for key in Set(desired.keys).union(remoteRecords.keys).sorted() {
                    let target = desired[key], current = remoteRecords[key]
                    if try target.map({ try Self.payloadHash($0.payload) }) == current.map({ try Self.payloadHash($0.payload) }) { continue }
                    let opID = Self.stableID(operationID.uuidString + "/" + key + "/" + (target == nil ? "delete" : "upsert"))
                    operations.append(RemoteOperation(operation_id: opID.uuidString, action: target == nil ? "delete" : "upsert", kind: target?.kind ?? current!.kind, id: key, expected_version: current?.version ?? 0, payload: target?.payload))
                }
                // Offline reopen → edit → reclose has a final closed snapshot. Send the explicit intermediate reopen first.
                var affectedDays = Set<String>()
                for operation in operations where operation.kind == "entry" {
                    if let r = remoteRecords[operation.id], let entry = try? r.payload.decode(FoodEntry.self) { affectedDays.insert(entry.dayID) }
                    if let r = desired[operation.id], let entry = try? r.payload.decode(FoodEntry.self) { affectedDays.insert(entry.dayID) }
                }
                for day in affectedDays {
                    let key = Self.stableID("day/" + day).uuidString.lowercased()
                    guard let existing = remoteRecords[key], let old = try? existing.payload.decode(NutritionDayLog.self), old.isClosed else { continue }
                    guard let target = desired[key], let final = try? target.payload.decode(NutritionDayLog.self), final.version > old.version else { throw RemoteError.conflict }
                    if !final.isClosed { continue }
                    guard final.version >= old.version + 2, let closeIndex = operations.firstIndex(where: { $0.id == key && $0.kind == "day" }) else { throw RemoteError.conflict }
                    var opened = old; opened.isClosed = false; opened.version += 1
                    operations[closeIndex].expected_version += 1
                    operations.append(RemoteOperation(operation_id: Self.stableID(operationID.uuidString + "/reopen/" + key).uuidString, action: "upsert", kind: "day", id: key, expected_version: existing.version, payload: try JSONValue.encode(opened)))
                }
                operations.sort { Self.order($0) < Self.order($1) }
                if operations.isEmpty {
                    try checkOwner(remote, owner: owner, endpoint: endpoint)
                    try Self.publish(candidate, to: store)
                    checkpoint = try Self.checkpoint(server.records, revision: server.revision)
                    try save(checkpoint, scope: scope); lastSyncDate = Date(); return
                }
                checkpoint.pending = TrackingPending(request: TrackingWireRequest(request_id: operationID.uuidString, base_revision: server.revision, operations: Array(operations.prefix(200))), candidate: candidate, beforeFingerprint: beforeFingerprint, remaining: Array(operations.dropFirst(200)), batchIndex: 0, rootRequestID: operationID.uuidString, messages: server.messages, accepted: nil, acceptedFingerprint: nil)
                try save(checkpoint, scope: scope)
            }
            guard var pending = checkpoint.pending else { throw RemoteError.invalidResponse }
            while !pending.remaining.isEmpty {
                guard try Self.fingerprint(Self.records(store.snapshot, owner: owner)) == pending.beforeFingerprint else { throw RemoteError.conflict }
                let response = try await remote.sync(pending.request.request)
                try checkOwner(remote, owner: owner, endpoint: endpoint)
                _ = try Self.checkpoint(response.records, revision: response.revision)
                pending.batchIndex += 1
                pending.request = TrackingWireRequest(request_id: Self.stableID(pending.rootRequestID + "/batch/" + String(pending.batchIndex)).uuidString, base_revision: response.revision, operations: Array(pending.remaining.prefix(200)))
                pending.remaining = Array(pending.remaining.dropFirst(200))
                checkpoint.pending = pending; try save(checkpoint, scope: scope)
            }
            // Never overwrite edits made after a lost acknowledgement or account switch.
            let currentFingerprint = try Self.fingerprint(Self.records(store.snapshot, owner: owner))
            guard currentFingerprint == pending.beforeFingerprint || currentFingerprint == pending.acceptedFingerprint else { throw RemoteError.conflict }
            let accepted: TrackingWireState
            if let old = pending.accepted { accepted = old }
            else {
                let response = try await remote.sync(pending.request.request)
                try checkOwner(remote, owner: owner, endpoint: endpoint)
                _ = try Self.checkpoint(response.records, revision: response.revision)
                accepted = TrackingWireState(revision: response.revision, records: response.records, messages: response.messages ?? pending.messages)
                let candidate = try Self.merge(Dictionary(uniqueKeysWithValues: accepted.records.map { ($0.id.lowercased(), $0) }), into: pending.candidate)
                pending.accepted = accepted; pending.acceptedFingerprint = try Self.fingerprint(Self.records(candidate, owner: owner))
                checkpoint.pending = pending; try save(checkpoint, scope: scope)
            }
            try checkOwner(remote, owner: owner, endpoint: endpoint)
            let afterWait = try Self.fingerprint(Self.records(store.snapshot, owner: owner))
            guard afterWait == pending.beforeFingerprint || afterWait == pending.acceptedFingerprint else { throw RemoteError.conflict }
            // Preserve drafts/messages changed while the request ran; only domain records are merged.
            let merged = try Self.mergeMessages(accepted.messages, into: Self.merge(Dictionary(uniqueKeysWithValues: accepted.records.map { ($0.id.lowercased(), $0) }), into: store.snapshot), owner: owner)
            var published = merged
            // Staged operations also carry undo receipts/change history; publish only after server ack.
            if proposed != nil || pending.candidate.changes != store.snapshot.changes {
                published.changes = pending.candidate.changes
                let stagedIDs = Set(pending.candidate.operations.map(\.id))
                published.operations = pending.candidate.operations + store.snapshot.operations.filter { !stagedIDs.contains($0.id) }
            }
            try Self.publish(published, to: store)
            checkpoint = try Self.checkpoint(accepted.records, revision: accepted.revision)
            try save(checkpoint, scope: scope); lastSyncDate = Date()
        } catch { errorKey = error.userFacingRemoteKey; throw error }
    }
    private func checkOwner(_ remote: any TrackingRemoteTransport, owner: String, endpoint: String) throws {
        guard remote.ownerID == owner, remote.endpoint == endpoint else { throw CancellationError() }
    }
    private func load(_ scope: String) throws -> TrackingCheckpoint {
        guard let data = try persistence.load(scope: scope) else { return TrackingCheckpoint() }
        let result = try JSONDecoder().decode(TrackingCheckpoint.self, from: data)
        guard result.schemaVersion == 1 else { throw NutritionError.unsupportedSchema }
        return result
    }
    private func save(_ value: TrackingCheckpoint, scope: String) throws { try persistence.save(JSONEncoder().encode(value), scope: scope) }
    private static func checkpoint(_ records: [RemoteRecord], revision: Int) throws -> TrackingCheckpoint {
        guard Set(records.map { $0.id.lowercased() }).count == records.count, revision >= 0 else { throw RemoteError.invalidResponse }
        var result = TrackingCheckpoint(); result.revision = revision
        for record in records { result.hashes[record.id.lowercased()] = try payloadHash(record.payload); result.versions[record.id.lowercased()] = record.version }
        return result
    }
    private static func publish(_ snapshot: NutritionSnapshot, to store: NutritionStore) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try store.restoreJSON(encoder.encode(snapshot))
    }
    static func stableID(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("nutrition-tracker/v1/" + value).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func payloadHash(_ payload: JSONValue) throws -> String { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return hash(try e.encode(payload)) }
    private static func fingerprint(_ records: [String: RemoteRecord]) throws -> String {
        var hashes: [String: String] = [:]; for (key, value) in records { hashes[key] = try payloadHash(value.payload) }
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return hash(try e.encode(hashes))
    }
    private static func order(_ op: RemoteOperation) -> String {
        if op.kind == "day", op.action == "upsert", case .object(let payload)? = op.payload, payload["isClosed"] == .bool(false) { return "0/" + op.id }
        if op.kind == "day" { return "9/" + op.id }
        return "5/" + op.kind + "/" + op.id
    }
    private static func mergeMessages(_ messages: [RemoteMessage]?, into original: NutritionSnapshot, owner: String) throws -> NutritionSnapshot {
        guard let messages else { return original }
        guard !original.messages.contains(where: { $0.remoteOwnerID != nil && $0.remoteOwnerID?.lowercased() != owner.lowercased() }) else { throw RemoteError.conflict }
        var result = original
        let responses = Set(messages.filter { $0.role == "assistant" }.compactMap { UUID(uuidString: $0.request_id) })
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        for message in messages {
            guard let id = UUID(uuidString: message.id), let requestID = UUID(uuidString: message.request_id),
                  let created = fractional.date(from: message.created_at) ?? standard.date(from: message.created_at),
                  message.content.count <= 100_000, ["user", "assistant"].contains(message.role) else { throw RemoteError.invalidResponse }
            let role: PersistentChatRole = message.role == "user" ? .user : .assistant
            let acknowledged = role == .assistant || responses.contains(requestID)
            if let index = result.messages.firstIndex(where: { $0.operationID == requestID && $0.role == role }) {
                // Preserve IDs/attachments locally; never erase a new draft or duplicate a retry.
                result.messages[index].remoteOwnerID = owner
                if acknowledged {
                    result.messages[index].state = .delivered
                    if let outboxIndex = result.outbox.firstIndex(where: { $0.messageID == result.messages[index].id }) { result.outbox[outboxIndex].state = .delivered }
                }
            } else {
                // Other devices cannot reconstruct the exact photo/consented context of the original request.
                result.messages.append(PersistentChatMessage(id: id, role: role, text: message.content, createdAt: created, dayID: message.day, state: acknowledged ? .delivered : .failed, operationID: requestID, remoteOwnerID: owner, requiresSavedResponse: true))
                if role == .user && !acknowledged { result.outbox.append(ChatOutboxItem(id: requestID, messageID: id, state: .failed)) }
            }
        }
        result.messages.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        try NutritionBackup.validate(result)
        return result
    }
    private static func records(_ s: NutritionSnapshot, owner: String) throws -> [String: RemoteRecord] {
        var result: [String: RemoteRecord] = [:]
        func add<T: Encodable>(_ value: T, kind: String, id: UUID) throws { let key = id.uuidString.lowercased(); guard result[key] == nil else { throw RemoteError.invalidResponse }; result[key] = RemoteRecord(id: key, kind: kind, version: 0, payload: try JSONValue.encode(value)) }
        try add(s.profile, kind: "profile", id: stableID("profile/" + owner.lowercased()))
        for value in s.entries where !value.deleted { try add(value, kind: "entry", id: value.id) }
        for value in s.days { try add(value, kind: "day", id: stableID("day/" + value.id)) }
        for value in s.goals { try add(value, kind: "goal", id: value.id) }
        for value in s.products { try add(value, kind: "product", id: value.id) }
        for value in s.recipes { try add(value, kind: "recipe", id: value.id) }
        for value in s.weights { try add(value, kind: "weight", id: value.id) }
        for value in s.activities { try add(value, kind: "activity", id: value.id) }
        for value in s.importBatches { try add(value, kind: "import", id: value.id) }
        for value in s.historicalSummaries { try add(value, kind: "historical", id: value.id) }
        for value in s.intakeResolutions { try add(value, kind: "resolution", id: stableID("resolution/" + value.dayID)) }
        return result
    }
    private static func merge(_ records: [String: RemoteRecord], into original: NutritionSnapshot) throws -> NutritionSnapshot {
        var result = original
        result.entries = []; result.days = []; result.goals = []; result.products = []; result.recipes = []; result.weights = []; result.activities = []; result.importBatches = []; result.historicalSummaries = []; result.intakeResolutions = []
        for record in records.values.sorted(by: { $0.id < $1.id }) {
            guard record.version >= 0, UUID(uuidString: record.id) != nil else { throw RemoteError.invalidResponse }
            switch record.kind {
            case "entry": result.entries.append(try record.payload.decode(FoodEntry.self))
            case "day": result.days.append(try record.payload.decode(NutritionDayLog.self))
            case "goal": result.goals.append(try record.payload.decode(NutritionGoalVersion.self))
            case "product": result.products.append(try record.payload.decode(FoodProduct.self))
            case "recipe": result.recipes.append(try record.payload.decode(FoodRecipe.self))
            case "weight": result.weights.append(try record.payload.decode(ManualWeightEntry.self))
            case "activity": result.activities.append(try record.payload.decode(ManualActivityEntry.self))
            case "import": result.importBatches.append(try record.payload.decode(NutritionImportBatch.self))
            case "historical": result.historicalSummaries.append(try record.payload.decode(HistoricalNutritionSummary.self))
            case "resolution": result.intakeResolutions.append(try record.payload.decode(IntakeResolution.self))
            case "profile": result.profile = try record.payload.decode(NutritionProfile.self)
            default: throw RemoteError.invalidResponse
            }
        }
        // Keep deletion history locally without sending tombstones as live intake.
        for old in original.entries where !result.entries.contains(where: { $0.id == old.id }) { var deleted = old; deleted.deleted = true; result.entries.append(deleted) }
        try NutritionBackup.validate(result); return result
    }
}

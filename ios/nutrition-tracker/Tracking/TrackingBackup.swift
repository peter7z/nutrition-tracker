import Foundation

struct TrackingBackup: Codable {
    var formatVersion = 1
    var exportedAt: Date
    var nutrition: NutritionSnapshot
    var health: HealthSnapshot?
    var attachmentFiles: [String: Data]?
    var ownerID: String? = nil
    var sourceAccountID: String? {
        ownerID ?? nutrition.messages.compactMap(\.remoteOwnerID).first ?? nutrition.attachments.compactMap(\.remoteOwnerID).first
    }
}

enum TrackingBackupError: Error, Equatable {
    case accountMismatch, rollbackFailed
    var userFacingKey: String {
        switch self {
        case .accountMismatch: return "This backup belongs to another account. Sign in to that account before restoring it."
        case .rollbackFailed: return "Restore failed and some saved files could not be recovered. Keep your backup and try restoring it again."
        }
    }
}

/// All decoding and validation happens before the replacement confirmation or any file writes.
enum TrackingBackupCodec {
    static let maximumBytes = 100_000_000
    static func encode(_ backup: TrackingBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let seconds = date.timeIntervalSinceReferenceDate
            guard seconds.isFinite else { throw NutritionError.invalidData }
            var whole = floor(seconds); var nanos = Int(((seconds - whole) * 1_000_000_000).rounded())
            if nanos == 1_000_000_000 { whole += 1; nanos = 0 }
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
            let base = formatter.string(from: Date(timeIntervalSinceReferenceDate: whole))
            var container = encoder.singleValueContainer()
            try container.encode(String(base.dropLast()) + String(format: ".%09dZ", nanos))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(backup)
        guard data.count <= maximumBytes else { throw NutritionError.invalidData }
        return data
    }

    static func decode(_ data: Data, ownerID: String?, validateHealth: (HealthSnapshot) throws -> Void,
                       validateImage: (Data) throws -> Void) throws -> TrackingBackup {
        guard data.count <= maximumBytes,
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NutritionError.invalidData }
        // Earlier manual-only exports were a standalone schema-1 snapshot. Missing newer schema-1
        // collections receive empty defaults; existing records are never replaced with defaults.
        if object["nutrition"] == nil {
            guard object["schemaVersion"] as? Int == 1 else { throw NutritionError.unsupportedSchema }
            object = ["formatVersion": 1, "exportedAt": "1970-01-01T00:00:00Z", "nutrition": object]
        }
        guard object["formatVersion"] as? Int == 1,
              var nutrition = object["nutrition"] as? [String: Any], nutrition["schemaVersion"] as? Int == 1 else { throw NutritionError.unsupportedSchema }
        nutrition = try NutritionBackup.normalizeSchemaOne(nutrition)
        object["nutrition"] = nutrition
        let normalized = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            // Original repository schema-1 files used Foundation's reference-date numeric format.
            if let seconds = try? container.decode(Double.self), seconds.isFinite { return Date(timeIntervalSinceReferenceDate: seconds) }
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
            if let dot = string.firstIndex(of: ".") {
                let remainder = string[string.index(after: dot)...]
                guard let zone = remainder.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else { throw NutritionError.invalidData }
                let digits = remainder[..<zone]
                guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let fraction = Double("0." + digits), let base = formatter.date(from: String(string[..<dot]) + remainder[zone...]) else { throw NutritionError.invalidData }
                return Date(timeIntervalSinceReferenceDate: base.timeIntervalSinceReferenceDate + fraction)
            }
            guard let date = formatter.date(from: string) else { throw NutritionError.invalidData }
            return date
        }
        var backup = try decoder.decode(TrackingBackup.self, from: normalized)
        guard backup.exportedAt.timeIntervalSince1970.isFinite else { throw NutritionError.invalidData }
        try NutritionBackup.validate(backup.nutrition)
        let owner = try normalizedOwner(ownerID)
        if let source = backup.ownerID, try normalizedOwner(source) != owner { throw TrackingBackupError.accountMismatch }
        for index in backup.nutrition.messages.indices {
            // Portable backups omit transient consent contexts and may replace uploaded photo IDs.
            // Retrieve the original response instead of changing the body under its request identity.
            backup.nutrition.messages[index].requiresSavedResponse = true
            if let source = backup.nutrition.messages[index].remoteOwnerID {
                guard try normalizedOwner(source) == owner else { throw TrackingBackupError.accountMismatch }
                backup.nutrition.messages[index].remoteOwnerID = ownerID
            }
        }
        let expectedKeys = Set(backup.nutrition.attachments.map { $0.id.uuidString })
        guard Set(backup.attachmentFiles?.keys.map { $0 } ?? []) == expectedKeys else { throw NutritionError.attachmentMissing }
        for index in backup.nutrition.attachments.indices {
            let item = backup.nutrition.attachments[index]
            if let source = item.remoteOwnerID, try normalizedOwner(source) != owner { throw TrackingBackupError.accountMismatch }
            guard item.relativePath == "\(item.id.uuidString).jpg", item.mimeType == "image/jpeg",
                  let image = backup.attachmentFiles?[item.id.uuidString], image.count == item.byteCount else { throw NutritionError.attachmentMissing }
            try validateImage(image)
            // Remote objects may have been deleted even when restoring into the same account.
            backup.nutrition.attachments[index].remoteAttachmentID = nil
            backup.nutrition.attachments[index].remoteOwnerID = ownerID
        }
        if let snapshot = backup.health { try validateHealth(snapshot) }
        return backup
    }
    private static func normalizedOwner(_ owner: String?) throws -> String? {
        guard let owner else { return nil }
        guard let id = UUID(uuidString: owner) else { throw NutritionError.invalidData }
        return id.uuidString.lowercased()
    }
}

/// Missing files are distinct from unreadable files: an I/O error must abort before replacement.
struct TrackingBackupPhotoIO {
    var read: (UUID) throws -> Data?
    var write: (UUID, Data) throws -> Void
    var remove: (UUID) throws -> Void
}

@MainActor enum TrackingBackupRestorer {
    static func restore(_ backup: TrackingBackup, original: NutritionSnapshot, recoveringUnreadableStore: Bool = false,
                        photos: TrackingBackupPhotoIO,
                        replaceNutrition: (NutritionSnapshot, NutritionSnapshot) throws -> Void,
                        rollbackNutrition: ((NutritionSnapshot) throws -> Void)? = nil,
                        restoreHealth: (HealthSnapshot) throws -> Void) throws {
        guard !recoveringUnreadableStore || rollbackNutrition != nil else { throw NutritionError.storageUnavailable }
        let oldIDs = Set(original.attachments.map(\.id)); let newIDs = Set(backup.nutrition.attachments.map(\.id))
        var originalPhotos: [UUID: Data] = [:]
        for id in oldIDs.union(newIDs) { if let data = try photos.read(id) { originalPhotos[id] = data } }
        var attempted: [UUID] = []; var nutritionReplaced = false
        do {
            for item in backup.nutrition.attachments {
                guard let data = backup.attachmentFiles?[item.id.uuidString], data.count == item.byteCount else { throw NutritionError.attachmentMissing }
                attempted.append(item.id); try photos.write(item.id, data)
            }
            for id in oldIDs.subtracting(newIDs) { attempted.append(id); try photos.remove(id) }
            try replaceNutrition(backup.nutrition, original); nutritionReplaced = true
            if let value = backup.health { try restoreHealth(value) }
        } catch {
            var rollbackFailed = false
            if nutritionReplaced {
                do {
                    if let rollbackNutrition { try rollbackNutrition(backup.nutrition) }
                    else { try replaceNutrition(original, backup.nutrition) }
                } catch { rollbackFailed = true }
            }
            for id in attempted.reversed() {
                do { if let data = originalPhotos[id] { try photos.write(id, data) } else { try photos.remove(id) } }
                catch { rollbackFailed = true }
            }
            if rollbackFailed { throw TrackingBackupError.rollbackFailed }
            throw error
        }
    }
}

#if canImport(UIKit)
extension AttachmentFiles {
    var backupIO: TrackingBackupPhotoIO {
        TrackingBackupPhotoIO(read: { id in
            let url = directory.appendingPathComponent("\(id.uuidString).jpg")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000 else { throw NutritionError.invalidData }
            return try Data(contentsOf: url)
        }, write: { id, data in _ = try save(data, id: id, ownerID: nil) }, remove: { id in
            let url = directory.appendingPathComponent("\(id.uuidString).jpg")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        })
    }
}
#endif

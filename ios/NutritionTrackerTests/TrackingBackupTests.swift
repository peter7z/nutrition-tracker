import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import nutrition_tracker

@MainActor final class TrackingBackupTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_791_475_200)
    private func history() throws -> NutritionSnapshot {
        let store = NutritionStore(persistence: BackupMemoryPersistence(), now: { self.date })
        try store.addEntry(FoodEntryDraft(name: "Label fixture", mealName: "Lunch", consumedAt: date, amount: 50,
                                          nutrition: NutrientValues(energy: 120, protein: 10), source: .label))
        try store.saveGoals(NutritionGoals(energy: 2000, protein: 100, carbohydrates: 200, fat: 70), effectiveDate: date)
        try store.closeDay(date)
        return store.snapshot
    }
    private func attachment(_ id: UUID, data: Data, owner: String? = nil) -> NutritionAttachment {
        NutritionAttachment(id: id, relativePath: "\(id.uuidString).jpg", mimeType: "image/jpeg", byteCount: data.count,
                            createdAt: date, remoteOwnerID: owner, remoteAttachmentID: UUID().uuidString)
    }
    private func decode(_ data: Data, owner: String? = nil, healthCalls: (() -> Void)? = nil) throws -> TrackingBackup {
        try TrackingBackupCodec.decode(data, ownerID: owner, validateHealth: { _ in healthCalls?() }, validateImage: { value in
            guard value == Data([0xFF, 0xD8, 0xFF, 0xD9]) else { throw NutritionError.invalidData }
        })
    }
    func testFullBackupKeepsManualFrozenHistoryPhotosAndHealthOnlyWhenIncluded() async throws {
        var snapshot = try history(); let photo = Data([0xFF, 0xD8, 0xFF, 0xD9]); let id = UUID()
        snapshot.attachments = [attachment(id, data: photo)]
        let backup = TrackingBackup(exportedAt: date, nutrition: snapshot, attachmentFiles: [id.uuidString: photo])
        let restored = try decode(TrackingBackupCodec.encode(backup))
        XCTAssertEqual(restored.nutrition.entries, snapshot.entries)
        XCTAssertEqual(restored.nutrition.days, snapshot.days); XCTAssertEqual(restored.nutrition.goals, snapshot.goals)
        XCTAssertEqual(restored.attachmentFiles?[id.uuidString], photo); XCTAssertNil(restored.health)
        XCTAssertNil(restored.nutrition.attachments.first?.remoteAttachmentID)
        var withHealth = backup; withHealth.health = HealthSnapshot(); var calls = 0
        let healthRestored = try decode(TrackingBackupCodec.encode(withHealth), healthCalls: { calls += 1 })
        XCTAssertEqual(calls, 1); XCTAssertEqual(healthRestored.health, withHealth.health)
    }
    func testBackupPreservesFractionalTimestampsAndGoalVersionOrderingExactly() async throws {
        var snapshot = try history()
        snapshot.entries[0].draft.consumedAt = date.addingTimeInterval(0.123456)
        snapshot.entries[0].createdAt = date.addingTimeInterval(0.654321)
        snapshot.entries[0].updatedAt = date.addingTimeInterval(0.987654)
        snapshot.goals[0].createdAt = date.addingTimeInterval(0.112233)
        snapshot.days[0].summaries[0].closedAt = date.addingTimeInterval(0.445566)
        let exportedAt = date.addingTimeInterval(0.778899)
        let restored = try decode(TrackingBackupCodec.encode(TrackingBackup(exportedAt: exportedAt, nutrition: snapshot)))
        XCTAssertEqual(restored.nutrition, snapshot); XCTAssertEqual(restored.exportedAt, exportedAt)
    }
    #if canImport(UIKit)
    func testActualJPEGBackupUsesProductionImageValidationAndRejectsDamagedImage() async throws {
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        var snapshot = try history(); let id = UUID(); snapshot.attachments = [attachment(id, data: photo)]
        var backup = TrackingBackup(exportedAt: date, nutrition: snapshot, attachmentFiles: [id.uuidString: photo])
        let decoded = try TrackingBackupCodec.decode(TrackingBackupCodec.encode(backup), ownerID: nil,
            validateHealth: { _ in }, validateImage: { _ = try AttachmentFiles.sanitizedJPEG($0) })
        XCTAssertEqual(decoded.attachmentFiles?[id.uuidString], photo)
        backup.attachmentFiles = [id.uuidString: Data(repeating: 0, count: photo.count)]
        XCTAssertThrowsError(try TrackingBackupCodec.decode(TrackingBackupCodec.encode(backup), ownerID: nil,
            validateHealth: { _ in }, validateImage: { _ = try AttachmentFiles.sanitizedJPEG($0) }))
    }
    #endif
    func testLegacyStandaloneNumericDatesAndMissingNewCollectionsMigrateWithoutChangingFood() async throws {
        let original = try history(); let encoder = JSONEncoder() // Original local repository date format.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        for key in ["weightConflictSelections", "activitySourceSelections", "historicalSummaries", "importBatches", "intakeResolutions", "messages", "outbox", "attachments", "chatDraft"] { object.removeValue(forKey: key) }
        let restored = try decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.nutrition.entries, original.entries); XCTAssertEqual(restored.nutrition.days, original.days)
        XCTAssertEqual(restored.nutrition.goals, original.goals); XCTAssertEqual(restored.nutrition.chatDraft, "")
        XCTAssertTrue(restored.nutrition.weightConflictSelections.isEmpty); XCTAssertNil(restored.health)
        object["schemaVersion"] = 2
        XCTAssertThrowsError(try decode(JSONSerialization.data(withJSONObject: object))) { XCTAssertEqual($0 as? NutritionError, .unsupportedSchema) }
    }
    func testAccountIsolationAndRemotePhotoObjectsAreNeverTrustedOnRestore() async throws {
        let owner = UUID().uuidString; let foreign = UUID().uuidString
        let manualOnly = TrackingBackup(exportedAt: date, nutrition: try history(), ownerID: owner)
        XCTAssertThrowsError(try decode(TrackingBackupCodec.encode(manualOnly), owner: foreign)) { XCTAssertEqual($0 as? TrackingBackupError, .accountMismatch) }
        XCTAssertEqual(try decode(TrackingBackupCodec.encode(manualOnly), owner: owner).sourceAccountID, owner)
        var snapshot = try history(); let photo = Data([0xFF, 0xD8, 0xFF, 0xD9]); let id = UUID()
        snapshot.attachments = [attachment(id, data: photo, owner: owner)]
        snapshot.messages = [PersistentChatMessage(id: UUID(), role: .user, text: "Fixture", createdAt: date,
            dayID: snapshot.profile.dayID(for: date), state: .queued, remoteOwnerID: owner)]
        let data = try TrackingBackupCodec.encode(TrackingBackup(exportedAt: date, nutrition: snapshot, attachmentFiles: [id.uuidString: photo]))
        XCTAssertThrowsError(try decode(data, owner: foreign)) { XCTAssertEqual($0 as? TrackingBackupError, .accountMismatch) }
        XCTAssertThrowsError(try decode(data)) { XCTAssertEqual($0 as? TrackingBackupError, .accountMismatch) }
        let same = try decode(data, owner: owner.lowercased())
        XCTAssertNil(same.nutrition.attachments[0].remoteAttachmentID)
        XCTAssertEqual(same.nutrition.messages[0].requiresSavedResponse, true, "Restoring must not replay a changed original request after photo/context replacement")
        XCTAssertEqual(same.nutrition.attachments[0].remoteOwnerID, owner.lowercased())
        snapshot.messages[0].remoteOwnerID = nil; snapshot.attachments[0].remoteOwnerID = nil
        let guest = try decode(TrackingBackupCodec.encode(TrackingBackup(exportedAt: date, nutrition: snapshot, attachmentFiles: [id.uuidString: photo])), owner: owner)
        XCTAssertNil(guest.nutrition.messages[0].remoteOwnerID, "Local messages must not silently become remote queued messages")
        XCTAssertEqual(guest.nutrition.attachments[0].remoteOwnerID, owner)
    }
    func testCorruptMissingAndUnreferencedPhotoPayloadsRejectBeforeAnyRestore() async throws {
        var snapshot = try history(); let id = UUID(); let photo = Data([0xFF, 0xD8, 0xFF, 0xD9])
        snapshot.attachments = [attachment(id, data: photo)]
        var backup = TrackingBackup(exportedAt: date, nutrition: snapshot, attachmentFiles: [:])
        XCTAssertThrowsError(try decode(TrackingBackupCodec.encode(backup)))
        backup.attachmentFiles = [id.uuidString: Data([0, 0, 0, 0])]
        XCTAssertThrowsError(try decode(TrackingBackupCodec.encode(backup)))
        backup.attachmentFiles = [id.uuidString: photo, UUID().uuidString: photo]
        XCTAssertThrowsError(try decode(TrackingBackupCodec.encode(backup)))
        backup.attachmentFiles = [id.uuidString: photo]; backup.nutrition.attachments[0].relativePath = "../private.jpg"
        XCTAssertThrowsError(try decode(TrackingBackupCodec.encode(backup)))
        XCTAssertThrowsError(try decode(Data("{broken".utf8)))
    }
    func testHealthSaveFailureRestoresExactManualStateAndOverwrittenOrphanPhotos() async throws {
        var original = try history(); let obsolete = UUID(); let incoming = UUID()
        let oldPhoto = Data([1]); let orphanPhoto = Data([2]); let imported = Data([3])
        original.attachments = [attachment(obsolete, data: oldPhoto)]
        var replacement = original; replacement.attachments = [attachment(incoming, data: imported)]
        replacement.profile.preferences = "Imported fixture"
        let backup = TrackingBackup(exportedAt: date, nutrition: replacement, health: HealthSnapshot(), attachmentFiles: [incoming.uuidString: imported])
        let photos = BackupMemoryPhotos([obsolete: oldPhoto, incoming: orphanPhoto]); let beforePhotos = photos.values
        var persisted = original
        XCTAssertThrowsError(try TrackingBackupRestorer.restore(backup, original: original, photos: photos.io,
            replaceNutrition: { new, expected in XCTAssertEqual(persisted, expected); persisted = new },
            restoreHealth: { _ in throw NutritionError.storageUnavailable })) { XCTAssertEqual($0 as? NutritionError, .storageUnavailable) }
        XCTAssertEqual(persisted, original); XCTAssertEqual(photos.values, beforePhotos)
    }
    func testPhotoWriteThatMutatesThenThrowsIsRolledBackAndRollbackFailureIsVisible() async throws {
        let original = try history(); let incoming = UUID(); let imported = Data([3]); let orphan = Data([2])
        var replacement = original; replacement.attachments = [attachment(incoming, data: imported)]
        let backup = TrackingBackup(exportedAt: date, nutrition: replacement, attachmentFiles: [incoming.uuidString: imported])
        let photos = BackupMemoryPhotos([incoming: orphan]); photos.failWriteNumber = 1
        var writes = 0
        XCTAssertThrowsError(try TrackingBackupRestorer.restore(backup, original: original, photos: photos.io,
            replaceNutrition: { _, _ in writes += 1 }, restoreHealth: { _ in }))
        XCTAssertEqual(writes, 0); XCTAssertEqual(photos.values[incoming], orphan)
        photos.writeCount = 0; photos.failEveryWrite = true
        XCTAssertThrowsError(try TrackingBackupRestorer.restore(backup, original: original, photos: photos.io,
            replaceNutrition: { _, _ in }, restoreHealth: { _ in })) { XCTAssertEqual($0 as? TrackingBackupError, .rollbackFailed) }
    }
    func testSuccessfulRestoreRemovesObsoletePhotosAndNoHealthBackupDoesNotChangeHealth() async throws {
        var original = try history(); let old = UUID(); let new = UUID(); let bytes = Data([9])
        original.attachments = [attachment(old, data: bytes)]
        var replacement = original; replacement.attachments = [attachment(new, data: bytes)]
        let photos = BackupMemoryPhotos([old: bytes]); var persisted = original; var healthCalls = 0
        try TrackingBackupRestorer.restore(TrackingBackup(exportedAt: date, nutrition: replacement, attachmentFiles: [new.uuidString: bytes]),
            original: original, photos: photos.io, replaceNutrition: { new, expected in XCTAssertEqual(persisted, expected); persisted = new },
            restoreHealth: { _ in healthCalls += 1 })
        XCTAssertEqual(persisted, replacement); XCTAssertEqual(photos.values, [new: bytes]); XCTAssertEqual(healthCalls, 0)
    }
    func testUnreadableOriginalPhysicalCheckpointRollsBackBytesFlagsAndPhotosAfterHealthFailure() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("Backup-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tracking.json"); let corrupt = Data("{original-invalid-fixture".utf8)
        try corrupt.write(to: file)
        let store = NutritionStore(persistence: NutritionFileRepository(fileURL: file))
        XCTAssertTrue(store.storageNeedsRecovery); let checkpoint = try store.captureCheckpoint()
        var replacement = try history(); replacement.entries[0].updatedAt = date.addingTimeInterval(0.123456)
        let photoID = UUID(); let photo = Data([6]); replacement.attachments = [attachment(photoID, data: photo)]
        let photos = BackupMemoryPhotos([photoID: Data([7])]); let originalPhotos = photos.values
        XCTAssertThrowsError(try TrackingBackupRestorer.restore(TrackingBackup(exportedAt: date, nutrition: replacement, health: HealthSnapshot(), attachmentFiles: [photoID.uuidString: photo]),
            original: checkpoint.snapshot, recoveringUnreadableStore: true, photos: photos.io,
            replaceNutrition: { new, expected in try store.restorePreparedSnapshot(new, expectedSnapshot: expected) },
            rollbackNutrition: { try store.restoreCheckpoint(checkpoint, expectedSnapshot: $0) },
            restoreHealth: { _ in throw NutritionError.storageUnavailable })) { XCTAssertEqual($0 as? NutritionError, .storageUnavailable) }
        XCTAssertEqual(try Data(contentsOf: file), corrupt); XCTAssertEqual(store.snapshot, checkpoint.snapshot)
        XCTAssertTrue(store.storageNeedsRecovery); XCTAssertEqual(store.errorKey, checkpoint.errorKey); XCTAssertEqual(photos.values, originalPhotos)
        // The same explicit recovery can succeed once the independent Health write is available.
        try TrackingBackupRestorer.restore(TrackingBackup(exportedAt: date, nutrition: replacement, attachmentFiles: [photoID.uuidString: photo]), original: checkpoint.snapshot,
            recoveringUnreadableStore: true, photos: photos.io,
            replaceNutrition: { new, expected in try store.restorePreparedSnapshot(new, expectedSnapshot: expected) },
            rollbackNutrition: { try store.restoreCheckpoint(checkpoint, expectedSnapshot: $0) }, restoreHealth: { _ in })
        XCTAssertFalse(store.storageNeedsRecovery); XCTAssertEqual(store.snapshot, replacement)
        XCTAssertEqual(try NutritionFileRepository(fileURL: file).load(), replacement)
    }
    func testMissingOriginalFileCheckpointAndForeignStoreCheckpointNeverOverwriteLaterWork() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("Backup-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tracking.json")
        let store = NutritionStore(persistence: NutritionFileRepository(fileURL: file)); let checkpoint = try store.captureCheckpoint()
        let replacement = try history(); try store.publishPreparedSnapshot(replacement, expectedSnapshot: checkpoint.snapshot)
        try store.restoreCheckpoint(checkpoint, expectedSnapshot: replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)); XCTAssertEqual(store.snapshot, checkpoint.snapshot)
        let foreign = NutritionStore(persistence: BackupMemoryPersistence())
        XCTAssertThrowsError(try foreign.restoreCheckpoint(checkpoint, expectedSnapshot: foreign.snapshot)) { XCTAssertEqual($0 as? NutritionError, .conflict) }
        try store.publishPreparedSnapshot(replacement, expectedSnapshot: checkpoint.snapshot)
        XCTAssertThrowsError(try store.restoreCheckpoint(checkpoint, expectedSnapshot: checkpoint.snapshot)) { XCTAssertEqual($0 as? NutritionError, .conflict) }
        XCTAssertEqual(store.snapshot, replacement)
    }
    func testGoalVersionIdentitySurvivesRestartAndSyncedReceiptAbsence() async throws {
        let persistence = BackupMemoryPersistence(); let store = NutritionStore(persistence: persistence)
        let operation = UUID(); let version = UUID(); let goals = NutritionGoals(energy: 2000, protein: 100, carbohydrates: 200, fat: 70)
        try store.saveGoals(goals, effectiveDate: date, operationID: operation, versionID: version)
        XCTAssertEqual(store.snapshot.goals.first?.id, version)
        let restarted = NutritionStore(persistence: persistence)
        try restarted.saveGoals(goals, effectiveDate: date, operationID: operation, versionID: version)
        XCTAssertEqual(restarted.snapshot.goals.count, 1)
        persistence.snapshot.operations = [] // Synced goal already exists without the local operation receipt.
        let synced = NutritionStore(persistence: persistence)
        try synced.saveGoals(goals, effectiveDate: date, operationID: operation, versionID: version)
        XCTAssertEqual(synced.snapshot.goals.count, 1)
        XCTAssertThrowsError(try synced.saveGoals(nil, effectiveDate: date, operationID: UUID(), versionID: version)) { XCTAssertEqual($0 as? NutritionError, .conflict) }
        let auto = UUID(); try synced.saveGoals(nil, effectiveDate: date, operationID: auto)
        XCTAssertEqual(synced.snapshot.goals.last?.id, auto)
    }

}

@MainActor private final class BackupMemoryPersistence: NutritionPersistence {
    var snapshot = NutritionSnapshot()
    func load() throws -> NutritionSnapshot { snapshot }
    func save(_ candidate: NutritionSnapshot) throws { snapshot = candidate }
}
private final class BackupMemoryPhotos {
    var values: [UUID: Data]; var writeCount = 0; var failWriteNumber: Int?; var failEveryWrite = false
    init(_ values: [UUID: Data] = [:]) { self.values = values }
    var io: TrackingBackupPhotoIO {
        TrackingBackupPhotoIO(read: { self.values[$0] }, write: { id, data in
            self.values[id] = data; self.writeCount += 1
            if self.failEveryWrite || self.failWriteNumber == self.writeCount { throw NutritionError.storageUnavailable }
        }, remove: { self.values.removeValue(forKey: $0) })
    }
}

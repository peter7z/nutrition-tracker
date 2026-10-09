import Foundation

enum AttachmentRemovalError: Error { case rollbackFailed }

enum AttachmentRemoval {
    @MainActor static func remove(id: UUID, photos: TrackingBackupPhotoIO, detach: () throws -> Void) throws {
        let original = try photos.read(id)
        try photos.remove(id)
        do { try detach() }
        catch {
            do { if let original { try photos.write(id, original) } }
            catch { throw AttachmentRemovalError.rollbackFailed }
            throw error
        }
    }
}

extension AttachmentFiles {
    var removalIO: TrackingBackupPhotoIO {
        TrackingBackupPhotoIO(read: { id in
            let file = directory.appendingPathComponent("\(id.uuidString).jpg")
            return FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        }, write: { id, bytes in _ = try save(bytes, id: id, ownerID: nil) }, remove: { id in
            let file = directory.appendingPathComponent("\(id.uuidString).jpg")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        })
    }
}

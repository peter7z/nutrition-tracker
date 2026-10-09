import XCTest
@testable import nutrition_tracker

@MainActor final class AttachmentRemovalTests: XCTestCase {
    func testMetadataSaveFailureRestoresPhotoBytes() throws {
        let id = UUID(); var images = [id: Data("Original photo fixture".utf8)]
        let before = images
        let io = TrackingBackupPhotoIO(read: { images[$0] }, write: { images[$0] = $1 }, remove: { images.removeValue(forKey: $0) })
        XCTAssertThrowsError(try AttachmentRemoval.remove(id: id, photos: io) { throw NutritionError.storageUnavailable })
        XCTAssertEqual(images, before)
    }
    func testUnreadablePhotoDoesNotDetachAndSuccessfulDeleteRemovesBoth() throws {
        let id = UUID(); var detached = false
        let unreadable = TrackingBackupPhotoIO(read: { _ in throw NutritionError.storageUnavailable }, write: { _, _ in }, remove: { _ in XCTFail("Read must succeed before removing") })
        XCTAssertThrowsError(try AttachmentRemoval.remove(id: id, photos: unreadable) { detached = true })
        XCTAssertFalse(detached)
        var images = [id: Data([1,2,3])]
        let io = TrackingBackupPhotoIO(read: { images[$0] }, write: { images[$0] = $1 }, remove: { images.removeValue(forKey: $0) })
        try AttachmentRemoval.remove(id: id, photos: io) { detached = true }
        XCTAssertTrue(detached); XCTAssertNil(images[id])
    }
}

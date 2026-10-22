import XCTest
@testable import nutrition_tracker

@MainActor private final class ObservationStub: HealthObservationDriver {
    var handlers: [BackgroundHealthType: (@escaping () -> Void) -> Void] = [:]
    var stopped: Set<BackgroundHealthType> = []
    func observe(_ type: BackgroundHealthType, changed: @escaping (@escaping () -> Void) -> Void) {
        handlers[type] = changed
    }
    func stop(_ type: BackgroundHealthType) { stopped.insert(type); handlers[type] = nil }
}

@MainActor final class HealthBackgroundSyncTests: XCTestCase {
    func testOnlyConfiguredTypesAreObservedAndRemovedOnLogout() {
        let driver = ObservationStub()
        let sync = HealthBackgroundSync(driver: driver) { _ in XCTFail("No delivery expected") }
        sync.configure([.weight])
        XCTAssertNotNil(driver.handlers[.weight])
        XCTAssertNil(driver.handlers[.waist])
        sync.configure([])
        XCTAssertEqual(driver.stopped, [.weight])
        XCTAssertTrue(driver.handlers.isEmpty)
    }

    func testDeliveryAcknowledgedOnlyAfterUploadAndConcurrentChangeGetsAnotherPass() async {
        let driver = ObservationStub()
        let started = expectation(description: "First upload started")
        let finished = expectation(description: "Both changes processed")
        var release: CheckedContinuation<Void, Never>?
        var passes = 0
        var acknowledgements = 0
        let sync = HealthBackgroundSync(driver: driver) { types in
            XCTAssertEqual(types, [.weight])
            passes += 1
            if passes == 1 {
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.fulfill()
                }
            }
        }
        sync.configure([.weight])
        driver.handlers[.weight]? { acknowledgements += 1 }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(acknowledgements, 0)
        driver.handlers[.weight]? { acknowledgements += 1; finished.fulfill() }
        release?.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(passes, 2)
        XCTAssertEqual(acknowledgements, 2)
    }

    func testLateDeliveryAfterDisableIsAcknowledgedWithoutUploading() {
        let driver = ObservationStub()
        let sync = HealthBackgroundSync(driver: driver) { _ in XCTFail("Disabled sync must not upload") }
        sync.configure([.weight])
        let late = driver.handlers[.weight]
        sync.configure([])
        var acknowledgements = 0
        late? { acknowledgements += 1 }
        XCTAssertEqual(acknowledgements, 1)
    }

    func testDisablingQueuedTypeDoesNotProcessItsData() async {
        let driver = ObservationStub()
        let finished = expectation(description: "Queued delivery acknowledged")
        let sync = HealthBackgroundSync(driver: driver) { _ in XCTFail("Disabled type must not sync") }
        sync.configure([.weight])
        driver.handlers[.weight]? { finished.fulfill() }
        sync.configure([])
        await fulfillment(of: [finished], timeout: 2)
    }
}

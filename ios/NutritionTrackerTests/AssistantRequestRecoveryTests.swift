import XCTest
@testable import nutrition_tracker

@MainActor final class AssistantRequestRecoveryTests: XCTestCase {
    func testLostAcknowledgmentRetrievesOriginalResponseWithoutRegeneratingOrCharging() async throws {
        let request = UUID()
        let server = RecoveryServer(response: AssistantResponse(request_id: request.uuidString, message: "Original response", intent: "query", proposals: [], totals: NutrientValues(energy: 250)))
        var generations = 0
        let answer = try await AssistantRequestRecovery.response(requestID: request, wasDelivered: false, remote: server) {
            generations += 1
            throw RemoteError.budget
        }
        XCTAssertEqual(server.requests, [request]); XCTAssertEqual(generations, 0)
        XCTAssertEqual(answer.message, "Original response"); XCTAssertEqual(answer.totals.energy, 250)
    }
    func testMissingUndeliveredRequestCanBeExplicitlyRetriedOnce() async throws {
        let server = RecoveryServer(error: .notFound); let request = UUID()
        var generations = 0
        _ = try await AssistantRequestRecovery.response(requestID: request, wasDelivered: false, remote: server) {
            generations += 1
            return AssistantResponse(request_id: request.uuidString, message: "New response", intent: "query", proposals: [], totals: NutrientValues())
        }
        XCTAssertEqual(generations, 1); XCTAssertEqual(server.requests, [request])
    }
    func testDeliveredButDeletedResponseAndTransientCacheErrorsNeverGenerateNewRequests() async throws {
        for (delivered, error) in [(true, RemoteError.notFound), (false, .offline), (false, .authentication), (false, .invalidResponse)] {
            let server = RecoveryServer(error: error); var generations = 0
            do {
                _ = try await AssistantRequestRecovery.response(requestID: UUID(), wasDelivered: delivered, remote: server) { generations += 1; throw RemoteError.budget }
                XCTFail("Expected original retrieval failure")
            } catch { XCTAssertEqual(generations, 0) }
        }
    }
}

@MainActor private final class RecoveryServer: AssistantCacheTransport {
    var requests: [UUID] = []
    let response: AssistantResponse?
    let error: RemoteError?
    init(response: AssistantResponse? = nil, error: RemoteError? = nil) { self.response = response; self.error = error }
    func cachedChat(requestID: UUID) async throws -> AssistantResponse {
        requests.append(requestID)
        if let error { throw error }
        return response!
    }
}

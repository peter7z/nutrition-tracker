import Foundation

@MainActor protocol AssistantCacheTransport {
    func cachedChat(requestID: UUID) async throws -> AssistantResponse
}
extension RemoteSession: AssistantCacheTransport {}

enum AssistantRequestRecovery {
    @MainActor static func response(requestID: UUID, wasDelivered: Bool, remote: any AssistantCacheTransport, create: () async throws -> AssistantResponse) async throws -> AssistantResponse {
        do { return try await remote.cachedChat(requestID: requestID) }
        catch RemoteError.notFound {
            guard !wasDelivered else { throw RemoteError.notFound }
            try Task.checkCancellation()
            return try await create()
        }
    }
}

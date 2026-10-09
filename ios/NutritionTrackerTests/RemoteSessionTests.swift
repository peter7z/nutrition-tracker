import XCTest
import Foundation
@testable import nutrition_tracker

final class RemoteSessionTestProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data, Double))?
    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.notConnectedToInternet) }
            let (status,data,delay) = try handler(request)
            let finish: @Sendable () -> Void = { [self] in
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            }
            if delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: finish) } else { finish() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    nonisolated override func stopLoading() {}
}

@MainActor final class RemoteSessionTests: XCTestCase {
    private func make(service: String = "nutrition.remote-tests." + UUID().uuidString, restore: Bool = false) -> RemoteSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RemoteSessionTestProtocol.self]
        return RemoteSession(session: URLSession(configuration: config), restoreCredentials: restore, credentialService: service)
    }
    private func loginHandler(owner: UUID = UUID(), token: String = "synthetic-session-token") {
        RemoteSessionTestProtocol.handler = { request in
            if request.url?.path.contains("auth/login") == true { return (200, Data("{\"token\":\"\(token)\",\"user_id\":\"\(owner.uuidString)\"}".utf8), 0) }
            return (200, Data("{\"revision\":0,\"records\":[],\"messages\":[]}".utf8), 0)
        }
    }
    func testRejectsInsecureRemoteEndpointAndAcceptsHTTPSWithBearer() async throws {
        let remote = make(); var requested = false
        RemoteSessionTestProtocol.handler = { _ in requested = true; return (200,Data(),0) }
        await remote.authenticate(endpoint: "http://nutrition.example.com", email: "fixture@example.com", password: "synthetic password", createAccount: false)
        XCTAssertFalse(requested); XCTAssertFalse(remote.isAuthenticated)
        loginHandler(); await remote.authenticate(endpoint: "https://nutrition.example.com", email: "fixture@example.com", password: "synthetic password", createAccount: false)
        XCTAssertTrue(remote.isAuthenticated, remote.errorKey ?? "No error key")
        RemoteSessionTestProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-session-token")
            return (200,Data("{\"revision\":0,\"records\":[]}".utf8),0)
        }
        let state = try await remote.state(); XCTAssertEqual(state.revision,0)
        await remote.logout()
    }
    func testPrivateKeychainNamespaceRestoresOnlyThatSessionAndOfflineLogoutClearsIt() async throws {
        let service = "nutrition.remote-tests." + UUID().uuidString; let remote = make(service: service)
        loginHandler(); await remote.authenticate(endpoint: "https://nutrition.example.com", email: "fixture@example.com", password: "synthetic password", createAccount: false)
        XCTAssertTrue(remote.isAuthenticated, remote.errorKey ?? "No error key")
        let restored = make(service: service,restore: true); XCTAssertEqual(restored.ownerID,remote.ownerID)
        let other = make(restore:true); XCTAssertFalse(other.isAuthenticated)
        RemoteSessionTestProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await restored.logout()
        XCTAssertFalse(restored.isAuthenticated); XCTAssertFalse(make(service:service,restore:true).isAuthenticated)
        await remote.logout()
    }
    func testServerErrorCannotBecomeFakeAssistantAnswerOrLeakServerContent() async throws {
        let remote = make(); loginHandler(); await remote.authenticate(endpoint: "https://nutrition.example.com", email: "fixture@example.com", password: "synthetic password", createAccount: false)
        XCTAssertTrue(remote.isAuthenticated, remote.errorKey ?? "No error key")
        guard remote.isAuthenticated else { throw RemoteError.authentication }
        var requested = false
        RemoteSessionTestProtocol.handler = { request in
            requested = true
            XCTAssertEqual(request.url?.path, "/v1/chat")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-session-token")
            return (503,Data("{\"error\":{\"message\":\"private server fixture\"}}".utf8),0)
        }
        do { _ = try await remote.chat(requestID: UUID(),day:"2026-10-08",text:"Synthetic query"); XCTFail() }
        catch {
            XCTAssertFalse(error.userFacingRemoteKey.contains("private server fixture"))
            guard case RemoteError.unavailable = error else { XCTFail("Expected authenticated server 503"); throw error }
        }
        XCTAssertTrue(requested)
        RemoteSessionTestProtocol.handler = { _ in (200, Data("{}".utf8), 0) }
        await remote.logout()
    }
    func testLogoutInvalidatesInFlightOwnerResponse() async throws {
        let remote = make(); loginHandler(); await remote.authenticate(endpoint: "https://nutrition.example.com", email: "fixture@example.com", password: "synthetic password", createAccount: false)
        XCTAssertTrue(remote.isAuthenticated, remote.errorKey ?? "No error key")
        guard remote.isAuthenticated else { throw RemoteError.authentication }
        let started = expectation(description:"Request started")
        RemoteSessionTestProtocol.handler = { request in
            if request.url?.path == "/v1/state" { started.fulfill(); return (200,Data("{\"revision\":99,\"records\":[]}".utf8),0.15) }
            return (200,Data("{}".utf8),0)
        }
        let task = Task { try await remote.state() }
        await fulfillment(of:[started],timeout:2); await remote.logout()
        do { _ = try await task.value; XCTFail("Late private data published") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(remote.isAuthenticated)
    }
}

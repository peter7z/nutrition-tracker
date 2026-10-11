import Foundation
import Observation
import AuthenticationServices
import Security

struct ServerSession: Codable, Equatable {
    let token: String
    let user_id: String
    let expires_at: String
}

protocol SessionPersistence {
    func load() throws -> ServerSession?
    func save(_ session: ServerSession) throws
    func clear() throws
}

struct KeychainSessionPersistence: SessionPersistence {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.peter7z.NutritionTracker.session",
         kSecAttrAccount as String: "backend"]
    }
    func load() throws -> ServerSession? {
        var values = query
        values[kSecReturnData as String] = true
        values[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(values as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AccountError.storage }
        return try JSONDecoder().decode(ServerSession.self, from: data)
    }
    func save(_ session: ServerSession) throws {
        let data = try JSONEncoder().encode(session)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var values = query
            values[kSecValueData as String] = data
            values[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(values as CFDictionary, nil) == errSecSuccess else { throw AccountError.storage }
        } else if status != errSecSuccess { throw AccountError.storage }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountError.storage }
    }
}

enum AccountError: Error { case storage, request, expired }
struct AppleChallenge: Decodable { let challenge_id: String; let nonce: String }
struct AccountProfile: Decodable { let user_id: String; let email: String }

@MainActor @Observable final class AccountSession {
    private(set) var session: ServerSession?
    private(set) var email: String?
    private(set) var isWorking = false
    var errorKey: String?
    private(set) var challenge: AppleChallenge?
    private let persistence: any SessionPersistence
    private let network: URLSession
    private let enabled: Bool
    private let base: URL

    init(persistence: any SessionPersistence = KeychainSessionPersistence(), network: URLSession = .shared,
         enabled: Bool = true, base: URL = URL(string: "https://nutrition-tracker-api-cljy.onrender.com")!) {
        self.persistence = persistence; self.network = network; self.base = base; self.enabled = enabled
        do { session = enabled ? try persistence.load() : nil } catch { errorKey = "Could not securely restore your session." }
    }
    private func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = false) async throws -> T {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, let session { request.setValue("Bearer " + session.token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await network.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AccountError.request }
        if response.statusCode == 401 { throw AccountError.expired }
        guard (200..<300).contains(response.statusCode) else { throw AccountError.request }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func prepareApple(clearError: Bool = true) async {
        guard enabled, session == nil, !isWorking else { return }
        isWorking = true
        if clearError { errorKey = nil }
        defer { isWorking = false }
        do { challenge = try await request("v1/auth/apple/challenge", method: "POST") }
        catch { challenge = nil; errorKey = "Could not connect. Try again." }
    }
    func completeApple(_ result: Result<ASAuthorization, any Error>) async {
        guard !isWorking else { return }
        defer { challenge = nil }
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled { errorKey = "Could not sign in with Apple. Try again." }
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8),
                  let challenge else { errorKey = "Could not sign in with Apple. Try again."; return }
            isWorking = true; errorKey = nil
            defer { isWorking = false }
            do {
                let body = try JSONEncoder().encode(["challenge_id": challenge.challenge_id, "identity_token": token])
                let received: ServerSession = try await request("v1/auth/apple", method: "POST", body: body)
                try persistence.save(received)
                session = received
                await refreshProfile()
            } catch { errorKey = "Could not sign in with Apple. Try again." }
        }
    }
    func refreshProfile() async {
        guard enabled, session != nil else { return }
        do {
            let profile: AccountProfile = try await request("v1/auth/me", authenticated: true)
            guard profile.user_id == session?.user_id else { throw AccountError.request }
            email = profile.email
        } catch AccountError.expired {
            do { try persistence.clear(); session = nil; email = nil; errorKey = "Your session expired. Sign in again." }
            catch { errorKey = "Could not securely remove your session." }
        } catch { errorKey = "Could not connect. Try again." }
    }
    func fetchDiary() async throws -> Data {
        guard enabled, let captured = session else { throw AccountError.expired }
        var request = URLRequest(url: base.appendingPathComponent("v1/state"))
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + captured.token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await network.data(for: request)
        guard session == captured else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw AccountError.request }
        if response.statusCode == 401 {
            try persistence.clear(); session = nil; email = nil
            errorKey = "Your session expired. Sign in again."
            throw AccountError.expired
        }
        guard (200..<300).contains(response.statusCode) else { throw AccountError.request }
        return data
    }
    func signOut() async {
        guard !isWorking else { return }
        isWorking = true; errorKey = nil
        defer { isWorking = false }
        struct Receipt: Decodable { let ok: Bool }
        do {
            let _: Receipt = try await request("v1/auth/logout", method: "POST", authenticated: true)
        } catch AccountError.expired { /* Already invalid on the server. */ }
        catch { errorKey = "Could not sign out. Check your connection and try again."; return }
        do { try persistence.clear(); session = nil; email = nil; challenge = nil }
        catch { errorKey = "Could not securely remove your session." }
    }
}

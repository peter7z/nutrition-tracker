import Foundation
import Observation
import Security
import Network

enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: JSONEncoder().encode(self))
    }
}

struct RemoteRecord: Codable, Equatable { var id: String; var kind: String; var version: Int; var payload: JSONValue }
struct RemoteMessage: Codable { var id: String; var request_id: String; var role: String; var content: String; var day: String; var created_at: String; var proposals: [AssistantProposal] }
struct RemoteState: Decodable { var revision: Int; var records: [RemoteRecord]; var messages: [RemoteMessage]? = nil }
struct RemoteOperation: Codable { var operation_id: String; var action: String; var kind: String; var id: String; var expected_version: Int; var payload: JSONValue? }
struct RemoteSyncRequest: Encodable { var request_id: String; var base_revision: Int; var operations: [RemoteOperation] }
struct AssistantProposal: Codable, Identifiable {
    var operation_id: String
    var action: String
    var entry_id: String?
    var expected_version: Int?
    var name: String?
    var quantity: Double?
    var unit: String?
    var state: String?
    var day: String
    var nutrients: NutrientValues?
    var assumptions: [String]
    var requires_clarification: Bool
    var product_id: String? = nil
    var product_version: Int? = nil
    var recipe_id: String? = nil
    var recipe_version: Int? = nil
    var weight_kg: Double? = nil
    var recorded_at: String? = nil
    var activity_kind: String? = nil
    var duration_minutes: Double? = nil
    var active_kcal: Double? = nil
    var id: String { operation_id }
}
struct AssistantGoalProposal: Codable {
    var energy: Double?
    var protein: Double?
    var carbohydrates: Double?
    var fat: Double?
    var effective_day: String
    var rationale: String
    var assumptions: [String]
    var requires_confirmation: Bool
}
struct AssistantReviewCoverage: Codable {
    var window_days: Int
    var complete_days: Int
    var weight_observed_days: Int
    var complete_days_by_week: [Int]
    var weight_days_by_week: [Int]
    var goal_adjustment_allowed: Bool
    var limitations: [String]
}
struct AssistantResponse: Codable {
    var request_id: String
    var message: String
    var intent: String?
    var proposals: [AssistantProposal]
    var totals: NutrientValues
    var goal_proposal: AssistantGoalProposal? = nil
    var review_coverage: AssistantReviewCoverage? = nil
}
struct RemoteAttachment: Decodable { var id: String; var media_type: String; var width: Int; var height: Int }
private struct RemoteCredentials: Codable { var endpoint: String; var token: String; var userID: String; var email: String }
enum RemoteError: Error { case endpoint, authentication, conflict, unavailable, offline, budget, invalidResponse, credentialStorage, notFound }

@MainActor @Observable final class RemoteSession {
    private(set) var ownerID: String?
    private(set) var email = ""
    private(set) var endpoint = ""
    private(set) var isWorking = false
    private(set) var isOnline = true
    private(set) var errorKey: String?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let keychainService: String
    init(session: URLSession? = nil, restoreCredentials: Bool = true, forceOffline: Bool = false, credentialService: String = "com.peter7z.NutritionTracker.remote-session") {
        keychainService = credentialService
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 60
        self.session = session ?? URLSession(configuration: config)
        if restoreCredentials, let saved = try? loadCredentials(), (try? validatedURL(saved.endpoint)) != nil {
            token = saved.token; ownerID = saved.userID; email = saved.email; endpoint = saved.endpoint
        }
        isOnline = !forceOffline
        if !forceOffline {
            monitor.pathUpdateHandler = { [weak self] path in
                let online = path.status == .satisfied
                Task { @MainActor [weak self] in self?.isOnline = online }
            }
            monitor.start(queue: DispatchQueue(label: "NutritionTracker.Network"))
        }
    }
    var isAuthenticated: Bool { token != nil && ownerID != nil }
    func authenticate(endpoint: String, email: String, password: String, createAccount: Bool) async {
        guard !isWorking else { return }; generation += 1; let operation = generation; isWorking = true; errorKey = nil
        defer { if operation == generation { isWorking = false } }
        do {
            _ = try validatedURL(endpoint)
            struct Login: Encodable { var email: String; var password: String }
            struct Result: Decodable { var token: String; var user_id: String }
            let result: Result = try await request(path: createAccount ? "v1/auth/signup" : "v1/auth/login", method: "POST", body: Login(email: email, password: password), base: endpoint, authenticated: false)
            guard operation == generation, UUID(uuidString: result.user_id) != nil else { throw RemoteError.invalidResponse }
            let credentials = RemoteCredentials(endpoint: endpoint, token: result.token, userID: result.user_id, email: email)
            try saveCredentials(credentials)
            self.endpoint = endpoint; self.token = result.token; self.ownerID = result.user_id; self.email = email
        } catch { if operation == generation { errorKey = error.userFacingRemoteKey } }
    }
    func logout() async {
        generation += 1
        let oldToken = token
        let logoutURL = try? validatedURL(endpoint).appendingPathComponent("v1/auth/logout")
        SecItemDelete(keychainQuery() as CFDictionary)
        token = nil; ownerID = nil; email = ""; endpoint = ""; isWorking = false
        // Remove local access immediately. Revocation is best effort when offline.
        if let oldToken, let logoutURL {
            var request = URLRequest(url: logoutURL); request.httpMethod = "POST"
            request.setValue("Bearer \(oldToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10
            _ = try? await session.data(for: request)
        }
    }
    func deleteAccount() async throws {
        let _: EmptyResponse = try await request(path: "v1/account", method: "DELETE", body: Optional<String>.none)
        await logout()
    }
    func state() async throws -> RemoteState { try await request(path: "v1/state", method: "GET", body: Optional<String>.none) }
    func cachedChat(requestID: UUID) async throws -> AssistantResponse { try await request(path: "v1/chat/\(requestID.uuidString)", method: "GET", body: Optional<String>.none) }
    func sync(_ body: RemoteSyncRequest) async throws -> RemoteState { try await request(path: "v1/sync", method: "POST", body: body) }
    func chat(requestID: UUID, day: String, text: String, attachmentID: String? = nil, healthContext: JSONValue? = nil, review: Bool = false) async throws -> AssistantResponse {
        struct Request: Encodable { var request_id: String; var day: String; var text: String; var attachment_id: String?; var health_context: JSONValue? }
        return try await request(path: review ? "v1/review" : "v1/chat", method: "POST", body: Request(request_id: requestID.uuidString, day: day, text: text, attachment_id: attachmentID, health_context: healthContext))
    }
    func weeklyReview(requestID: UUID, day: String, text: String, healthReviewContext: JSONValue?) async throws -> AssistantResponse {
        struct Request: Encodable {
            var request_id: String
            var day: String
            var text: String
            var health_review_context: JSONValue?
        }
        return try await request(
            path: "v1/review",
            method: "POST",
            body: Request(request_id: requestID.uuidString, day: day, text: text, health_review_context: healthReviewContext)
        )
    }
    func uploadJPEG(_ data: Data) async throws -> RemoteAttachment {
        guard data.count <= 10_000_000 else { throw RemoteError.invalidResponse }
        let boundary = "Nutrition-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let data = try await rawRequest(path: "v1/attachments", method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        return try JSONDecoder().decode(RemoteAttachment.self, from: data)
    }
    func deleteAttachment(id: String) async throws { let _: EmptyResponse = try await request(path: "v1/attachments/\(id)", method: "DELETE", body: Optional<String>.none) }
    private struct EmptyResponse: Decodable {}
    private func request<B: Encodable, R: Decodable>(path: String, method: String, body: B?, base: String? = nil, authenticated: Bool = true) async throws -> R {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try await rawRequest(path: path, method: method, body: try body.map { try encoder.encode($0) }, contentType: "application/json", base: base, authenticated: authenticated)
        if data.isEmpty, let empty = EmptyResponse() as? R { return empty }
        do { return try JSONDecoder().decode(R.self, from: data) } catch { throw RemoteError.invalidResponse }
    }
    private func rawRequest(path: String, method: String, body: Data?, contentType: String, base: String? = nil, authenticated: Bool = true) async throws -> Data {
        let currentGeneration = generation
        let url = try validatedURL(base ?? endpoint).appendingPathComponent(path)
        if authenticated && !isAuthenticated { throw RemoteError.authentication }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if authenticated, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw RemoteError.offline }
        guard currentGeneration == generation else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse, data.count <= 10_000_000 else { throw RemoteError.invalidResponse }
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw RemoteError.authentication
        case 404: throw RemoteError.notFound
        case 409: throw RemoteError.conflict
        case 429: throw RemoteError.budget
        case 503: throw RemoteError.unavailable
        default: throw RemoteError.invalidResponse
        }
    }
    private func validatedURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw RemoteError.endpoint }
        if url.scheme == "https" { return url }
        #if DEBUG
        if url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host) { return url }
        #endif
        throw RemoteError.endpoint
    }
    private func keychainQuery() -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "session"] }
    private func loadCredentials() throws -> RemoteCredentials? {
        var query = keychainQuery(); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw RemoteError.credentialStorage }
        return try JSONDecoder().decode(RemoteCredentials.self, from: data)
    }
    private func saveCredentials(_ value: RemoteCredentials) throws {
        let data = try JSONEncoder().encode(value)
        var query = keychainQuery(); query[kSecValueData as String] = data; query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemDelete(keychainQuery() as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw RemoteError.credentialStorage }
    }
}

extension Error {
    var userFacingRemoteKey: String {
        guard let remote = self as? RemoteError else { return "The request failed. Your saved records are unchanged." }
        return switch remote {
        case .endpoint: "Enter a valid HTTPS server address."
        case .authentication: "Sign in again or check your email and password."
        case .conflict: "Changes conflict with another session. Refresh and review before retrying."
        case .unavailable: "AI is unavailable. Check the server configuration and try again."
        case .offline: "No connection. Your draft and records remain on this device."
        case .budget: "The request limit was reached. Try again later."
        case .credentialStorage: "Could not securely save your session."
        case .invalidResponse: "The server returned an unexpected response. Try again."
        case .notFound: "This item is no longer available on the server."
        }
    }
}

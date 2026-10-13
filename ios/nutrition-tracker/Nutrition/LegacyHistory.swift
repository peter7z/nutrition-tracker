import Foundation
import Security

/// Retains access to the previously selected account's local history. This does
/// not authenticate, contact a server, modify credentials or replay old requests.
struct LegacyHistory {
    let ownerID: UUID?
    var accountScope: String { ownerID?.uuidString.lowercased() ?? "local" }

    static func stored() -> LegacyHistory {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            // This is the historical service used by the original app.
            kSecAttrService as String: "com.peter7z.NutritionTracker.remote-session",
            kSecAttrAccount as String: "session",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return LegacyHistory(ownerID: nil) }
        return decodeOwner(from: data)
    }

    static func decodeOwner(from data: Data) -> LegacyHistory {
        struct Identity: Decodable { let userID: String }
        let identity = try? JSONDecoder().decode(Identity.self, from: data)
        return LegacyHistory(ownerID: identity.flatMap { UUID(uuidString: $0.userID) })
    }

    var fileURL: URL {
        Self.fileURL(ownerID: ownerID, root: URL.applicationSupportDirectory.appendingPathComponent("NutritionTracker", isDirectory: true))
    }
    static func fileURL(ownerID: UUID?, root: URL) -> URL {
        if let ownerID { return root.appendingPathComponent("Accounts", isDirectory: true).appendingPathComponent("\(ownerID.uuidString).json") }
        return root.appendingPathComponent("tracking-v1.json")
    }
}

import SwiftUI
private struct LegacyHistoryKey: EnvironmentKey {
    static let defaultValue = LegacyHistory(ownerID: nil)
}
extension EnvironmentValues {
    var legacyHistory: LegacyHistory {
        get { self[LegacyHistoryKey.self] }
        set { self[LegacyHistoryKey.self] = newValue }
    }
}

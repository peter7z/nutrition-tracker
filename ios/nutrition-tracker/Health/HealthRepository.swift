import Foundation

@MainActor protocol HealthPersistence {
    func load() throws -> HealthSnapshot
    func save(_ snapshot: HealthSnapshot) throws
}

@MainActor final class HealthFileRepository: HealthPersistence {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NutritionTracker", isDirectory: true)
            .appendingPathComponent("health-v1.json")
    }

    func load() throws -> HealthSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return HealthSnapshot() }
        let snapshot = try JSONDecoder().decode(HealthSnapshot.self, from: Data(contentsOf: fileURL))
        guard snapshot.schemaVersion == 1 else { throw HealthOperationError.unsupportedSchema }
        return snapshot
    }

    func save(_ snapshot: HealthSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var protectedDirectory = directory
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(attributes)
        let encoded = try JSONEncoder().encode(snapshot)
        // Data and opaque HealthKit anchors move forward together, or neither does.
        try encoded.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

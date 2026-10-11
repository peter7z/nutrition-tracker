import Foundation

/// Read adapter for /v1/state. No tracking mutations are sent by the companion.
enum BackendDiary {
    static func decode(_ data: Data) throws -> NutritionSnapshot {
        guard data.count <= 50_000_000 else { throw NutritionError.invalidData }
        guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = state["records"] as? [[String: Any]], state["revision"] is Int else { throw NutritionError.invalidData }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let text = try value.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw NutritionError.invalidData }
            return date
        }
        func decode<T: Decodable>(_ type: T.Type, _ value: [String: Any]) throws -> T {
            try decoder.decode(type, from: JSONSerialization.data(withJSONObject: value))
        }
        var snapshot = NutritionSnapshot()
        for record in records where record["kind"] as? String == "profile" {
            guard let payload = record["payload"] as? [String: Any] else { throw NutritionError.invalidData }
            var profile: [String: Any] = ["timeZoneIdentifier": "America/Montevideo", "preferences": ""]
            profile.merge(payload) { _, new in new }
            snapshot.profile = try decode(NutritionProfile.self, profile)
        }
        for record in records {
            guard let kind = record["kind"] as? String, let id = record["id"] as? String,
                  let version = record["version"] as? Int, var payload = record["payload"] as? [String: Any] else { throw NutritionError.invalidData }
            switch kind {
            case "entry":
                let draft = try decode(FoodEntryDraft.self, payload["draft"] as? [String: Any] ?? payload)
                guard let identifier = UUID(uuidString: id) else { throw NutritionError.invalidData }
                snapshot.entries.append(FoodEntry(id: identifier, version: version,
                    dayID: snapshot.profile.dayID(for: draft.consumedAt), draft: draft,
                    createdAt: draft.consumedAt, updatedAt: draft.consumedAt))
            case "day":
                payload["version"] = version
                snapshot.days.append(try decode(NutritionDayLog.self, payload))
            case "goal": snapshot.goals.append(try decode(NutritionGoalVersion.self, payload))
            case "weight": snapshot.weights.append(try decode(ManualWeightEntry.self, payload))
            case "activity": snapshot.activities.append(try decode(ManualActivityEntry.self, payload))
            case "historical": snapshot.historicalSummaries.append(try decode(HistoricalNutritionSummary.self, payload))
            case "resolution": snapshot.intakeResolutions.append(try decode(IntakeResolution.self, payload))
            case "import": snapshot.importBatches.append(try decode(NutritionImportBatch.self, payload))
            default: break
            }
        }
        // MCP summaries carry an operation/batch ID without an import record.
        // Supply cache provenance for display validation, never upload it.
        let references = snapshot.historicalSummaries.map(\.importBatchID)
            + snapshot.weights.compactMap(\.importBatchID) + snapshot.activities.compactMap(\.importBatchID)
        for id in Set(references) where !snapshot.importBatches.contains(where: { $0.id == id }) {
            snapshot.importBatches.append(NutritionImportBatch(id: id, fingerprint: "server:" + id.uuidString,
                importedAt: Date(timeIntervalSince1970: 0), fileName: "Server diary"))
        }
        try NutritionBackup.validate(snapshot)
        return snapshot
    }

    static func cacheURL(owner: UUID) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("NutritionTracker/ServerDiary", isDirectory: true)
            .appendingPathComponent(owner.uuidString + ".json")
    }
}

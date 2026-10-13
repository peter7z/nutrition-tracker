import Foundation

@MainActor protocol NutritionPersistence {
    func load() throws -> NutritionSnapshot
}

@MainActor final class NutritionFileRepository: NutritionPersistence {
    let fileURL: URL
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NutritionTracker", isDirectory: true).appendingPathComponent("tracking-v1.json")
    }
    func load() throws -> NutritionSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return NutritionSnapshot() }
        return try NutritionBackup.decode(Data(contentsOf: fileURL), datesISO8601: false)
    }
}

enum NutritionBackup {
    static func decode(_ data: Data, datesISO8601: Bool) throws -> NutritionSnapshot {
        guard data.count <= 50_000_000 else { throw NutritionError.invalidData }
        let decoder = JSONDecoder(); if datesISO8601 { decoder.dateDecodingStrategy = .iso8601 }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NutritionError.invalidData }
        let normalized = try normalizeSchemaOne(object)
        let result = try decoder.decode(NutritionSnapshot.self, from: JSONSerialization.data(withJSONObject: normalized))
        try validate(result); return result
    }
    /// Additive schema-1 migration shared by repository loads and full-backup restoration.
    /// Core identity fields remain required; explicit nulls or malformed values are never replaced.
    static func normalizeSchemaOne(_ object: [String: Any]) throws -> [String: Any] {
        guard let version = object["schemaVersion"] as? Int else { throw NutritionError.invalidData }
        guard version == 1 else { throw NutritionError.unsupportedSchema }
        guard object["profile"] is [String: Any], object["entries"] is [Any] else { throw NutritionError.invalidData }
        guard let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(NutritionSnapshot())) as? [String: Any] else { throw NutritionError.invalidData }
        var normalized = object
        for (key, value) in defaults where normalized[key] == nil { normalized[key] = value }
        return normalized
    }
    static func validate(_ snapshot: NutritionSnapshot) throws {
        guard snapshot.schemaVersion == 1 else { throw NutritionError.unsupportedSchema }
        guard TimeZone(identifier: snapshot.profile.timeZoneIdentifier) != nil, snapshot.profile.preferences.count <= 20_000,
              Set(snapshot.entries.map(\.id)).count == snapshot.entries.count,
              Set(snapshot.days.map(\.id)).count == snapshot.days.count,
              Set(snapshot.operations.map(\.id)).count == snapshot.operations.count,
              Set(snapshot.products.map(\.id)).count == snapshot.products.count,
              Set(snapshot.recipes.map(\.id)).count == snapshot.recipes.count,
              Set(snapshot.weights.map(\.id)).count == snapshot.weights.count,
              Set(snapshot.activities.map(\.id)).count == snapshot.activities.count,
              Set(snapshot.importBatches.map(\.id)).count == snapshot.importBatches.count,
              Set(snapshot.historicalSummaries.map(\.dayID)).count == snapshot.historicalSummaries.count,
              Set(snapshot.attachments.map(\.id)).count == snapshot.attachments.count,
              Set(snapshot.messages.map(\.id)).count == snapshot.messages.count,
              snapshot.chatDraft.count <= 50_000 else { throw NutritionError.invalidData }
        func validDay(_ id: String) -> Bool {
            let formatter = DateFormatter(); formatter.calendar = snapshot.profile.calendar; formatter.timeZone = snapshot.profile.calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            return formatter.date(from: id).map { formatter.string(from: $0) == id } ?? false
        }
        for entry in snapshot.entries { try entry.draft.validate(); guard entry.version > 0, validDay(entry.dayID) else { throw NutritionError.invalidData } }
        for day in snapshot.days {
            guard validDay(day.id), day.version > 0 else { throw NutritionError.invalidData }
            for summary in day.summaries {
                let totals = [summary.totals.energy, summary.totals.protein, summary.totals.carbohydrates, summary.totals.fat, summary.totals.saturatedFat, summary.totals.fiber, summary.totals.vitaminA, summary.totals.thiamin, summary.totals.riboflavin, summary.totals.niacin, summary.totals.pantothenicAcid, summary.totals.vitaminB6, summary.totals.biotin, summary.totals.vitaminB12, summary.totals.vitaminC, summary.totals.vitaminD, summary.totals.vitaminE, summary.totals.vitaminK, summary.totals.folate, summary.totals.calcium, summary.totals.chloride, summary.totals.iron, summary.totals.magnesium, summary.totals.phosphorus, summary.totals.potassium, summary.totals.sodium, summary.totals.zinc, summary.totals.chromium, summary.totals.copper, summary.totals.iodine, summary.totals.manganese, summary.totals.molybdenum, summary.totals.selenium]
                guard summary.version > 0, summary.closedAt.timeIntervalSince1970.isFinite,
                      summary.totals.entryCount >= 0,
                      totals.allSatisfy({ $0.known.isFinite && $0.known >= 0 && $0.knownCount >= 0 && $0.missingCount >= 0 }),
                      summary.entryVersions.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value > 0 }),
                      summary.intakeSource != .health || summary.totals == NutritionTotals() else { throw NutritionError.invalidData }
            }
        }
        for goal in snapshot.goals { guard validDay(goal.effectiveDay), goal.goals?.isValid != false else { throw NutritionError.invalidData } }
        for product in snapshot.products {
            let unit: FoodUnit = product.basis == .per100Grams ? .gram : product.basis == .per100Milliliters ? .milliliter : .serving
            try product.draft(amount: 1, unit: unit, consumedAt: product.updatedAt, mealName: "Validation").validate()
            guard product.version > 0 else { throw NutritionError.invalidData }
        }
        for recipe in snapshot.recipes {
            _ = try recipe.draft(amount: 1, unit: recipe.finalWeightGrams == nil ? .serving : .gram, consumedAt: recipe.updatedAt, mealName: "Validation")
            guard recipe.version > 0 else { throw NutritionError.invalidData }
        }
        for weight in snapshot.weights {
            guard weight.kilograms.isFinite && weight.kilograms > 0 && weight.kilograms < 1_000,
                  weight.notes.count <= 20_000,
                  weight.source != .spreadsheet ? weight.importBatchID == nil : snapshot.importBatches.contains(where: { $0.id == weight.importBatchID }) else { throw NutritionError.invalidData }
        }
        for activity in snapshot.activities {
            guard !activity.kind.isEmpty, activity.durationMinutes.map({ $0.isFinite && $0 >= 0 }) != false,
                  activity.durationMinutes != nil || activity.activeEnergy != nil,
                  activity.notes.count <= 20_000,
                  activity.source == .manual ? activity.importBatchID == nil : snapshot.importBatches.contains(where: { $0.id == activity.importBatchID }),
                  activity.activeEnergy.map({ $0.isFinite && $0 >= 0 }) != false else { throw NutritionError.invalidData }
        }
        for summary in snapshot.historicalSummaries { guard validDay(summary.dayID), summary.nutrients.isValid, snapshot.importBatches.contains(where: { $0.id == summary.importBatchID }) else { throw NutritionError.invalidData } }
        for (key, value) in snapshot.weightConflictSelections { guard !key.isEmpty, key.count <= 500, !value.isEmpty, value.count <= 500 else { throw NutritionError.invalidData } }
        for (day, value) in snapshot.activitySourceSelections { guard validDay(day), ["manual", "spreadsheet", "health"].contains(value) else { throw NutritionError.invalidData } }
        for resolution in snapshot.intakeResolutions { guard validDay(resolution.dayID) else { throw NutritionError.invalidData } }
        for message in snapshot.messages {
            guard validDay(message.dayID), message.text.count <= 100_000,
                  message.attachmentIDs.allSatisfy({ id in snapshot.attachments.contains(where: { $0.id == id }) }) else { throw NutritionError.invalidData }
        }
        for item in snapshot.outbox { guard snapshot.messages.contains(where: { $0.id == item.messageID }), item.attempts >= 0 else { throw NutritionError.invalidData } }
        for attachment in snapshot.attachments {
            guard attachment.byteCount > 0, attachment.byteCount <= 20_000_000,
                  !attachment.relativePath.hasPrefix("/"), !attachment.relativePath.split(separator: "/").contains(".."),
                  !attachment.relativePath.isEmpty, ["image/jpeg", "image/png"].contains(attachment.mimeType) else { throw NutritionError.invalidData }
        }
    }
}

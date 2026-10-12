import Foundation

enum FoodUnit: String, Codable, CaseIterable, Identifiable { case gram, milliliter, serving; var id: String { rawValue } }
enum FoodPreparation: String, Codable, CaseIterable, Identifiable { case unspecified, raw, cooked; var id: String { rawValue } }
enum FoodSource: String, Codable, CaseIterable, Identifiable { case manual, label, catalog, estimate, recipe; var id: String { rawValue } }
enum NutritionBasis: String, Codable, CaseIterable, Identifiable { case per100Grams, per100Milliliters, perServing; var id: String { rawValue } }

struct NutrientValues: Codable, Equatable {
    var energy: Double? = nil
    var protein: Double? = nil
    var carbohydrates: Double? = nil
    var fat: Double? = nil
    var saturatedFat: Double? = nil
    var fiber: Double? = nil
    var isValid: Bool { [energy, protein, carbohydrates, fat, saturatedFat, fiber].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1_000_000 } }
    func scaled(by factor: Double) -> Self { Self(energy: energy.map { $0 * factor }, protein: protein.map { $0 * factor }, carbohydrates: carbohydrates.map { $0 * factor }, fat: fat.map { $0 * factor }, saturatedFat: saturatedFat.map { $0 * factor }, fiber: fiber.map { $0 * factor }) }
}

struct PortionConversion: Codable, Equatable {
    var gramsPerServing: Double? = nil
    var millilitersPerServing: Double? = nil
    var gramsPerMilliliter: Double? = nil
    var isValid: Bool { [gramsPerServing, millilitersPerServing, gramsPerMilliliter].compactMap { $0 }.allSatisfy { $0.isFinite && $0 > 0 && $0 <= 1_000_000 } }
}

struct FoodEntryDraft: Codable, Equatable {
    var name: String
    var mealName: String = "Meal"
    var consumedAt: Date = Date()
    var amount: Double
    var unit: FoodUnit = .gram
    var preparation: FoodPreparation = .unspecified
    var nutrition: NutrientValues = NutrientValues()
    var basis: NutritionBasis = .per100Grams
    var conversion: PortionConversion? = nil
    var source: FoodSource = .manual
    var notes: String = ""
    var productID: UUID? = nil
    var productVersion: Int? = nil
    var recipeID: UUID? = nil
    var recipeVersion: Int? = nil

    func nutritionFactor() throws -> Double {
        guard amount.isFinite && amount > 0 && amount <= 1_000_000,
              nutrition.isValid, conversion?.isValid != false else { throw NutritionError.invalidData }
        let c = conversion ?? PortionConversion()
        let converted: Double?
        switch (unit, basis) {
        case (.gram, .per100Grams), (.milliliter, .per100Milliliters): converted = amount / 100
        case (.serving, .perServing): converted = amount
        case (.serving, .per100Grams): converted = c.gramsPerServing.map { amount * $0 / 100 }
        case (.serving, .per100Milliliters): converted = c.millilitersPerServing.map { amount * $0 / 100 }
        case (.gram, .perServing): converted = c.gramsPerServing.map { amount / $0 }
        case (.milliliter, .perServing): converted = c.millilitersPerServing.map { amount / $0 }
        case (.milliliter, .per100Grams): converted = c.gramsPerMilliliter.map { amount * $0 / 100 }
        case (.gram, .per100Milliliters): converted = c.gramsPerMilliliter.map { amount / $0 / 100 }
        }
        guard let converted, converted.isFinite && converted > 0 else { throw NutritionError.conversionRequired }
        return converted
    }
    func values() throws -> NutrientValues { nutrition.scaled(by: try nutritionFactor()) }
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 500,
              !mealName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              mealName.count <= 500, notes.count <= 20_000, consumedAt.timeIntervalSince1970.isFinite else { throw NutritionError.invalidData }
        let values = try values()
        guard values.isValid else { throw NutritionError.invalidData }
    }
}

struct NutrientTotal: Codable, Equatable {
    var known: Double = 0
    var knownCount: Int = 0
    var missingCount: Int = 0
    var value: Double? { knownCount > 0 ? known : nil }
    var isComplete: Bool { missingCount == 0 && knownCount > 0 }
    mutating func include(_ value: Double?) { if let value { known += value; knownCount += 1 } else { missingCount += 1 } }
}
struct NutritionTotals: Codable, Equatable {
    var energy = NutrientTotal()
    var protein = NutrientTotal()
    var carbohydrates = NutrientTotal()
    var fat = NutrientTotal()
    var saturatedFat = NutrientTotal()
    var fiber = NutrientTotal()
    var entryCount = 0
    init() {}
    private enum CodingKeys: String, CodingKey { case energy, protein, carbohydrates, fat, saturatedFat, fiber, entryCount }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        energy = try values.decode(NutrientTotal.self, forKey: .energy)
        protein = try values.decode(NutrientTotal.self, forKey: .protein)
        carbohydrates = try values.decode(NutrientTotal.self, forKey: .carbohydrates)
        fat = try values.decode(NutrientTotal.self, forKey: .fat)
        saturatedFat = try values.decode(NutrientTotal.self, forKey: .saturatedFat)
        fiber = try values.decodeIfPresent(NutrientTotal.self, forKey: .fiber) ?? NutrientTotal()
        entryCount = try values.decode(Int.self, forKey: .entryCount)
    }
    var isComplete: Bool { energy.isComplete && protein.isComplete && carbohydrates.isComplete && fat.isComplete }
    mutating func include(_ values: NutrientValues) {
        energy.include(values.energy); protein.include(values.protein); carbohydrates.include(values.carbohydrates)
        fat.include(values.fat); saturatedFat.include(values.saturatedFat); fiber.include(values.fiber); entryCount += 1
    }
    // Missing recipe ingredients must keep that nutrient unknown in the recipe snapshot.
    var completeValues: NutrientValues { NutrientValues(energy: energy.isComplete ? energy.value : nil, protein: protein.isComplete ? protein.value : nil, carbohydrates: carbohydrates.isComplete ? carbohydrates.value : nil, fat: fat.isComplete ? fat.value : nil, saturatedFat: saturatedFat.isComplete ? saturatedFat.value : nil, fiber: fiber.isComplete ? fiber.value : nil) }
}

struct FoodEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var version: Int
    var dayID: String
    var draft: FoodEntryDraft
    var deleted = false
    var createdAt: Date
    var updatedAt: Date
    var values: NutrientValues { (try? draft.values()) ?? NutrientValues() }
}
enum DayCompleteness: String, Codable, CaseIterable { case complete, incomplete }
struct ClosedDaySummary: Codable, Equatable, Identifiable {
    var id: UUID
    var version: Int
    var closedAt: Date
    var completeness: DayCompleteness
    var totals: NutritionTotals
    var entryVersions: [String: Int]
    var goalVersionID: UUID?
    var intakeSource: IntakeSelection? = nil
}
struct NutritionDayLog: Codable, Equatable, Identifiable {
    var id: String
    var version = 1
    var isClosed = false
    var summaries: [ClosedDaySummary] = []
}
struct NutritionProfile: Codable, Equatable {
    var timeZoneIdentifier = "America/Montevideo"
    var preferences = ""
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt; return c }
    func dayID(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
struct NutritionGoalVersion: Codable, Equatable, Identifiable {
    var id: UUID
    var effectiveDay: String
    var effectiveDate: Date
    var goals: NutritionGoals?
    var createdAt: Date
}
struct FoodProduct: Codable, Equatable, Identifiable {
    var id: UUID
    var version: Int
    var name: String
    var brand: String = ""
    var nutrition: NutrientValues
    var basis: NutritionBasis
    var conversion: PortionConversion? = nil
    var source: FoodSource = .label
    var updatedAt: Date
    func draft(amount: Double, unit: FoodUnit, consumedAt: Date, mealName: String) -> FoodEntryDraft {
        FoodEntryDraft(name: brand.isEmpty ? name : "\(name) (\(brand))", mealName: mealName, consumedAt: consumedAt, amount: amount, unit: unit, nutrition: nutrition, basis: basis, conversion: conversion, source: source, productID: id, productVersion: version)
    }
}
struct FoodRecipe: Codable, Equatable, Identifiable {
    var id: UUID
    var version: Int
    var name: String
    var ingredients: [FoodEntryDraft]
    var finalWeightGrams: Double?
    var servings: Double?
    var updatedAt: Date
    func draft(amount: Double, unit: FoodUnit, consumedAt: Date, mealName: String) throws -> FoodEntryDraft {
        guard !ingredients.isEmpty, finalWeightGrams != nil || servings != nil,
              [finalWeightGrams, servings].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 }) else { throw NutritionError.invalidData }
        var total = NutritionTotals()
        for ingredient in ingredients { try ingredient.validate(); total.include(try ingredient.values()) }
        let basis: NutritionBasis = finalWeightGrams != nil ? .per100Grams : .perServing
        let divisor = finalWeightGrams.map { $0 / 100 } ?? servings!
        let conversion = PortionConversion(gramsPerServing: finalWeightGrams.flatMap { weight in servings.map { weight / $0 } })
        let result = FoodEntryDraft(name: name, mealName: mealName, consumedAt: consumedAt, amount: amount, unit: unit, nutrition: total.completeValues.scaled(by: 1 / divisor), basis: basis, conversion: conversion, source: .recipe, recipeID: id, recipeVersion: version)
        try result.validate(); return result
    }
}
enum TrackingSource: String, Codable { case manual, spreadsheet, appleHealth }
struct ManualWeightEntry: Codable, Equatable, Identifiable { var id: UUID; var recordedAt: Date; var kilograms: Double; var source: TrackingSource = .manual; var notes = ""; var importBatchID: UUID? = nil; var sourceSampleID: UUID? = nil }
struct ManualActivityEntry: Codable, Equatable, Identifiable { var id: UUID; var recordedAt: Date; var kind: String; var durationMinutes: Double?; var activeEnergy: Double? = nil; var source: TrackingSource = .manual; var notes = ""; var importBatchID: UUID? = nil }
struct HistoricalNutritionSummary: Codable, Equatable, Identifiable { var id: UUID; var dayID: String; var nutrients: NutrientValues; var isClosed: Bool; var notes: String; var importBatchID: UUID; var sourceRow: String }
struct NutritionImportBatch: Codable, Equatable, Identifiable {
    var id: UUID; var fingerprint: String; var importedAt: Date; var fileName: String; var createdDayIDs: [String] = []
    var previousResolutions: [IntakeResolution] = []
    var installedResolutions: [IntakeResolution] = []
    private enum CodingKeys: String, CodingKey { case id, fingerprint, importedAt, fileName, createdDayIDs, previousResolutions, installedResolutions }
    init(id: UUID, fingerprint: String, importedAt: Date, fileName: String, createdDayIDs: [String] = [], previousResolutions: [IntakeResolution] = [], installedResolutions: [IntakeResolution] = []) {
        self.id = id; self.fingerprint = fingerprint; self.importedAt = importedAt; self.fileName = fileName
        self.createdDayIDs = createdDayIDs; self.previousResolutions = previousResolutions; self.installedResolutions = installedResolutions
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); fingerprint = try c.decode(String.self, forKey: .fingerprint)
        importedAt = try c.decode(Date.self, forKey: .importedAt); fileName = try c.decode(String.self, forKey: .fileName)
        createdDayIDs = try c.decodeIfPresent([String].self, forKey: .createdDayIDs) ?? []
        previousResolutions = try c.decodeIfPresent([IntakeResolution].self, forKey: .previousResolutions) ?? []
        installedResolutions = try c.decodeIfPresent([IntakeResolution].self, forKey: .installedResolutions) ?? []
    }
}
enum IntakeSelection: String, Codable { case manual, historical, health }
struct IntakeResolution: Codable, Equatable {
    var dayID: String
    var selection: IntakeSelection
    var revisionID: UUID = UUID()
    var createdByBatchID: UUID? = nil
    private enum CodingKeys: String, CodingKey { case dayID, selection, revisionID, createdByBatchID }
    init(dayID: String, selection: IntakeSelection, revisionID: UUID = UUID(), createdByBatchID: UUID? = nil) {
        self.dayID = dayID; self.selection = selection; self.revisionID = revisionID; self.createdByBatchID = createdByBatchID
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dayID = try c.decode(String.self, forKey: .dayID); selection = try c.decode(IntakeSelection.self, forKey: .selection)
        revisionID = try c.decodeIfPresent(UUID.self, forKey: .revisionID) ?? UUID(); createdByBatchID = try c.decodeIfPresent(UUID.self, forKey: .createdByBatchID)
    }
}
enum PersistentChatRole: String, Codable { case user, assistant, system }
enum ChatDeliveryState: String, Codable { case queued, sending, delivered, failed, cancelled }
struct PersistentChatMessage: Codable, Equatable, Identifiable {
    var id: UUID
    var role: PersistentChatRole
    var text: String
    var createdAt: Date
    var dayID: String
    var state: ChatDeliveryState
    var operationID: UUID? = nil
    var attachmentIDs: [UUID] = []
    var remoteOwnerID: String? = nil
    // Optional for existing backups. A deleted input cannot be recreated with the same request ID.
    var attachmentRemoved: Bool? = nil
    var requiresSavedResponse: Bool? = nil

}
struct ChatOutboxItem: Codable, Equatable, Identifiable { var id: UUID; var messageID: UUID; var attempts: Int = 0; var state: ChatDeliveryState = .queued }
struct NutritionAttachment: Codable, Equatable, Identifiable { var id: UUID; var relativePath: String; var mimeType: String; var byteCount: Int; var createdAt: Date; var remoteOwnerID: String? = nil; var remoteAttachmentID: String? = nil }
enum NutritionChangeKind: String, Codable { case addEntry, updateEntry, deleteEntry, closeDay, reopenDay, undo }
struct NutritionChangeEvent: Codable, Equatable, Identifiable {
    var id: UUID
    var operationID: UUID
    var kind: NutritionChangeKind
    var createdAt: Date
    var entryID: UUID?
    var beforeEntry: FoodEntry?
    var afterEntry: FoodEntry?
    var beforeDay: NutritionDayLog?
    var afterDay: NutritionDayLog?
    var undoneBy: UUID? = nil
    var dayEntryVersions: [String: Int]? = nil
}
struct NutritionOperationReceipt: Codable, Equatable { var id: UUID; var resultID: UUID?; var fingerprint: String? = nil }
struct NutritionSnapshot: Codable, Equatable {
    var schemaVersion = 1
    var profile = NutritionProfile()
    var entries: [FoodEntry] = []
    var days: [NutritionDayLog] = []
    var goals: [NutritionGoalVersion] = []
    var products: [FoodProduct] = []
    var recipes: [FoodRecipe] = []
    var weights: [ManualWeightEntry] = []
    var activities: [ManualActivityEntry] = []
    var historicalSummaries: [HistoricalNutritionSummary] = []
    var importBatches: [NutritionImportBatch] = []
    var intakeResolutions: [IntakeResolution] = []
    var weightConflictSelections: [String: String] = [:]
    var activitySourceSelections: [String: String] = [:]
    var changes: [NutritionChangeEvent] = []
    var operations: [NutritionOperationReceipt] = []
    var chatDraft = ""
    var messages: [PersistentChatMessage] = []
    var outbox: [ChatOutboxItem] = []
    var attachments: [NutritionAttachment] = []
}
enum NutritionError: Error, Equatable { case invalidData, conversionRequired, closedDay, notFound, conflict, unsupportedSchema, storageUnavailable, attachmentMissing }

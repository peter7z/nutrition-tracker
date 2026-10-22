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
    var vitaminA: Double? = nil
    var thiamin: Double? = nil
    var riboflavin: Double? = nil
    var niacin: Double? = nil
    var pantothenicAcid: Double? = nil
    var vitaminB6: Double? = nil
    var biotin: Double? = nil
    var vitaminB12: Double? = nil
    var vitaminC: Double? = nil
    var vitaminD: Double? = nil
    var vitaminE: Double? = nil
    var vitaminK: Double? = nil
    var folate: Double? = nil
    var calcium: Double? = nil
    var chloride: Double? = nil
    var iron: Double? = nil
    var magnesium: Double? = nil
    var phosphorus: Double? = nil
    var potassium: Double? = nil
    var sodium: Double? = nil
    var zinc: Double? = nil
    var chromium: Double? = nil
    var copper: Double? = nil
    var iodine: Double? = nil
    var manganese: Double? = nil
    var molybdenum: Double? = nil
    var selenium: Double? = nil
    var isValid: Bool { allValues.compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1_000_000 } }
    var allValues: [Double?] { [energy, protein, carbohydrates, fat, saturatedFat, fiber, vitaminA, thiamin, riboflavin, niacin, pantothenicAcid, vitaminB6, biotin, vitaminB12, vitaminC, vitaminD, vitaminE, vitaminK, folate, calcium, chloride, iron, magnesium, phosphorus, potassium, sodium, zinc, chromium, copper, iodine, manganese, molybdenum, selenium] }
    func scaled(by factor: Double) -> Self {
        Self(energy: energy.map { $0 * factor }, protein: protein.map { $0 * factor }, carbohydrates: carbohydrates.map { $0 * factor }, fat: fat.map { $0 * factor }, saturatedFat: saturatedFat.map { $0 * factor }, fiber: fiber.map { $0 * factor }, vitaminA: vitaminA.map { $0 * factor }, thiamin: thiamin.map { $0 * factor }, riboflavin: riboflavin.map { $0 * factor }, niacin: niacin.map { $0 * factor }, pantothenicAcid: pantothenicAcid.map { $0 * factor }, vitaminB6: vitaminB6.map { $0 * factor }, biotin: biotin.map { $0 * factor }, vitaminB12: vitaminB12.map { $0 * factor }, vitaminC: vitaminC.map { $0 * factor }, vitaminD: vitaminD.map { $0 * factor }, vitaminE: vitaminE.map { $0 * factor }, vitaminK: vitaminK.map { $0 * factor }, folate: folate.map { $0 * factor }, calcium: calcium.map { $0 * factor }, chloride: chloride.map { $0 * factor }, iron: iron.map { $0 * factor }, magnesium: magnesium.map { $0 * factor }, phosphorus: phosphorus.map { $0 * factor }, potassium: potassium.map { $0 * factor }, sodium: sodium.map { $0 * factor }, zinc: zinc.map { $0 * factor }, chromium: chromium.map { $0 * factor }, copper: copper.map { $0 * factor }, iodine: iodine.map { $0 * factor }, manganese: manganese.map { $0 * factor }, molybdenum: molybdenum.map { $0 * factor }, selenium: selenium.map { $0 * factor })
    }
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
    var vitaminA = NutrientTotal()
    var thiamin = NutrientTotal()
    var riboflavin = NutrientTotal()
    var niacin = NutrientTotal()
    var pantothenicAcid = NutrientTotal()
    var vitaminB6 = NutrientTotal()
    var biotin = NutrientTotal()
    var vitaminB12 = NutrientTotal()
    var vitaminC = NutrientTotal()
    var vitaminD = NutrientTotal()
    var vitaminE = NutrientTotal()
    var vitaminK = NutrientTotal()
    var folate = NutrientTotal()
    var calcium = NutrientTotal()
    var chloride = NutrientTotal()
    var iron = NutrientTotal()
    var magnesium = NutrientTotal()
    var phosphorus = NutrientTotal()
    var potassium = NutrientTotal()
    var sodium = NutrientTotal()
    var zinc = NutrientTotal()
    var chromium = NutrientTotal()
    var copper = NutrientTotal()
    var iodine = NutrientTotal()
    var manganese = NutrientTotal()
    var molybdenum = NutrientTotal()
    var selenium = NutrientTotal()
    var entryCount = 0
    init() {}
    private enum CodingKeys: String, CodingKey { case energy, protein, carbohydrates, fat, saturatedFat, fiber, vitaminA, thiamin, riboflavin, niacin, pantothenicAcid, vitaminB6, biotin, vitaminB12, vitaminC, vitaminD, vitaminE, vitaminK, folate, calcium, chloride, iron, magnesium, phosphorus, potassium, sodium, zinc, chromium, copper, iodine, manganese, molybdenum, selenium, entryCount }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        energy = try values.decode(NutrientTotal.self, forKey: .energy)
        protein = try values.decode(NutrientTotal.self, forKey: .protein)
        carbohydrates = try values.decode(NutrientTotal.self, forKey: .carbohydrates)
        fat = try values.decode(NutrientTotal.self, forKey: .fat)
        saturatedFat = try values.decode(NutrientTotal.self, forKey: .saturatedFat)
        fiber = try values.decodeIfPresent(NutrientTotal.self, forKey: .fiber) ?? NutrientTotal()
        vitaminA = try values.decodeIfPresent(NutrientTotal.self, forKey: .vitaminA) ?? NutrientTotal()
        thiamin = try values.decodeIfPresent(NutrientTotal.self, forKey: .thiamin) ?? NutrientTotal()
        riboflavin = try values.decodeIfPresent(NutrientTotal.self, forKey: .riboflavin) ?? NutrientTotal()
        niacin = try values.decodeIfPresent(NutrientTotal.self, forKey: .niacin) ?? NutrientTotal()
        pantothenicAcid = try values.decodeIfPresent(NutrientTotal.self, forKey: .pantothenicAcid) ?? NutrientTotal()
        vitaminB6 = try values.decodeIfPresent(NutrientTotal.self, forKey: .vitaminB6) ?? NutrientTotal()
        biotin = try values.decodeIfPresent(NutrientTotal.self, forKey: .biotin) ?? NutrientTotal()
        vitaminB12 = try values.decodeIfPresent(NutrientTotal.self, forKey: .vitaminB12) ?? NutrientTotal()
        vitaminC = try values.decodeIfPresent(NutrientTotal.self, forKey: .vitaminC) ?? NutrientTotal()
        vitaminD = try values.decodeIfPresent(NutrientTotal.self, forKey: .vitaminD) ?? NutrientTotal()
        vitaminE = try values.decodeIfPresent(NutrientTotal.self, forKey: .vitaminE) ?? NutrientTotal()
        vitaminK = try values.decodeIfPresent(NutrientTotal.self, forKey: .vitaminK) ?? NutrientTotal()
        folate = try values.decodeIfPresent(NutrientTotal.self, forKey: .folate) ?? NutrientTotal()
        calcium = try values.decodeIfPresent(NutrientTotal.self, forKey: .calcium) ?? NutrientTotal()
        chloride = try values.decodeIfPresent(NutrientTotal.self, forKey: .chloride) ?? NutrientTotal()
        iron = try values.decodeIfPresent(NutrientTotal.self, forKey: .iron) ?? NutrientTotal()
        magnesium = try values.decodeIfPresent(NutrientTotal.self, forKey: .magnesium) ?? NutrientTotal()
        phosphorus = try values.decodeIfPresent(NutrientTotal.self, forKey: .phosphorus) ?? NutrientTotal()
        potassium = try values.decodeIfPresent(NutrientTotal.self, forKey: .potassium) ?? NutrientTotal()
        sodium = try values.decodeIfPresent(NutrientTotal.self, forKey: .sodium) ?? NutrientTotal()
        zinc = try values.decodeIfPresent(NutrientTotal.self, forKey: .zinc) ?? NutrientTotal()
        chromium = try values.decodeIfPresent(NutrientTotal.self, forKey: .chromium) ?? NutrientTotal()
        copper = try values.decodeIfPresent(NutrientTotal.self, forKey: .copper) ?? NutrientTotal()
        iodine = try values.decodeIfPresent(NutrientTotal.self, forKey: .iodine) ?? NutrientTotal()
        manganese = try values.decodeIfPresent(NutrientTotal.self, forKey: .manganese) ?? NutrientTotal()
        molybdenum = try values.decodeIfPresent(NutrientTotal.self, forKey: .molybdenum) ?? NutrientTotal()
        selenium = try values.decodeIfPresent(NutrientTotal.self, forKey: .selenium) ?? NutrientTotal()
        entryCount = try values.decode(Int.self, forKey: .entryCount)
    }
    var isComplete: Bool { energy.isComplete && protein.isComplete && carbohydrates.isComplete && fat.isComplete }
    mutating func include(_ values: NutrientValues) {
        energy.include(values.energy); protein.include(values.protein); carbohydrates.include(values.carbohydrates)
        fat.include(values.fat); saturatedFat.include(values.saturatedFat); fiber.include(values.fiber); entryCount += 1
        vitaminA.include(values.vitaminA); thiamin.include(values.thiamin); riboflavin.include(values.riboflavin); niacin.include(values.niacin)
        pantothenicAcid.include(values.pantothenicAcid); vitaminB6.include(values.vitaminB6); biotin.include(values.biotin); vitaminB12.include(values.vitaminB12)
        vitaminC.include(values.vitaminC); vitaminD.include(values.vitaminD); vitaminE.include(values.vitaminE); vitaminK.include(values.vitaminK); folate.include(values.folate)
        calcium.include(values.calcium); chloride.include(values.chloride); iron.include(values.iron); magnesium.include(values.magnesium); phosphorus.include(values.phosphorus)
        potassium.include(values.potassium); sodium.include(values.sodium); zinc.include(values.zinc); chromium.include(values.chromium); copper.include(values.copper)
        iodine.include(values.iodine); manganese.include(values.manganese); molybdenum.include(values.molybdenum); selenium.include(values.selenium)
    }
    // Missing recipe ingredients must keep that nutrient unknown in the recipe snapshot.
    var completeValues: NutrientValues { NutrientValues(energy: energy.isComplete ? energy.value : nil, protein: protein.isComplete ? protein.value : nil, carbohydrates: carbohydrates.isComplete ? carbohydrates.value : nil, fat: fat.isComplete ? fat.value : nil, saturatedFat: saturatedFat.isComplete ? saturatedFat.value : nil, fiber: fiber.isComplete ? fiber.value : nil, vitaminA: vitaminA.isComplete ? vitaminA.value : nil, thiamin: thiamin.isComplete ? thiamin.value : nil, riboflavin: riboflavin.isComplete ? riboflavin.value : nil, niacin: niacin.isComplete ? niacin.value : nil, pantothenicAcid: pantothenicAcid.isComplete ? pantothenicAcid.value : nil, vitaminB6: vitaminB6.isComplete ? vitaminB6.value : nil, biotin: biotin.isComplete ? biotin.value : nil, vitaminB12: vitaminB12.isComplete ? vitaminB12.value : nil, vitaminC: vitaminC.isComplete ? vitaminC.value : nil, vitaminD: vitaminD.isComplete ? vitaminD.value : nil, vitaminE: vitaminE.isComplete ? vitaminE.value : nil, vitaminK: vitaminK.isComplete ? vitaminK.value : nil, folate: folate.isComplete ? folate.value : nil, calcium: calcium.isComplete ? calcium.value : nil, chloride: chloride.isComplete ? chloride.value : nil, iron: iron.isComplete ? iron.value : nil, magnesium: magnesium.isComplete ? magnesium.value : nil, phosphorus: phosphorus.isComplete ? phosphorus.value : nil, potassium: potassium.isComplete ? potassium.value : nil, sodium: sodium.isComplete ? sodium.value : nil, zinc: zinc.isComplete ? zinc.value : nil, chromium: chromium.isComplete ? chromium.value : nil, copper: copper.isComplete ? copper.value : nil, iodine: iodine.isComplete ? iodine.value : nil, manganese: manganese.isComplete ? manganese.value : nil, molybdenum: molybdenum.isComplete ? molybdenum.value : nil, selenium: selenium.isComplete ? selenium.value : nil) }
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
struct DailyNutritionSnapshot: Codable, Equatable, Identifiable {
    var id: UUID
    var version: Int
    var capturedAt: Date
    var completeness: DayCompleteness
    var totals: NutritionTotals
    var entryVersions: [String: Int]
    var goalVersionID: UUID?
    var intakeSource: IntakeSelection? = nil
    // Preserve the existing server/backup key; this timestamp never freezes a day.
    private enum CodingKeys: String, CodingKey {
        case id, version, completeness, totals, entryVersions, goalVersionID, intakeSource
        case capturedAt = "closedAt"
    }
}
struct NutritionDayLog: Codable, Equatable, Identifiable {
    var id: String
    var version: Int
    var summaries: [DailyNutritionSnapshot]
    private enum CodingKeys: String, CodingKey { case id, version, summaries }
    init(id: String, version: Int = 1, summaries: [DailyNutritionSnapshot] = []) {
        self.id = id; self.version = version; self.summaries = summaries
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        summaries = try values.decodeIfPresent([DailyNutritionSnapshot].self, forKey: .summaries) ?? []
    }
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
struct HistoricalNutritionSummary: Codable, Equatable, Identifiable {
    var id: UUID
    var dayID: String
    var nutrients: NutrientValues
    var isComplete: Bool
    var notes: String
    var importBatchID: UUID
    var sourceRow: String
    private enum CodingKeys: String, CodingKey { case id, dayID, nutrients, isComplete, notes, importBatchID, sourceRow }
    private enum LegacyCodingKeys: String, CodingKey { case isClosed }
    init(id: UUID, dayID: String, nutrients: NutrientValues, isComplete: Bool, notes: String, importBatchID: UUID, sourceRow: String) {
        self.id = id; self.dayID = dayID; self.nutrients = nutrients; self.isComplete = isComplete
        self.notes = notes; self.importBatchID = importBatchID; self.sourceRow = sourceRow
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        dayID = try values.decode(String.self, forKey: .dayID)
        nutrients = try values.decode(NutrientValues.self, forKey: .nutrients)
        isComplete = try values.decodeIfPresent(Bool.self, forKey: .isComplete) ?? legacy.decode(Bool.self, forKey: .isClosed)
        notes = try values.decode(String.self, forKey: .notes)
        importBatchID = try values.decode(UUID.self, forKey: .importBatchID)
        sourceRow = try values.decode(String.self, forKey: .sourceRow)
    }
}
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
enum NutritionChangeKind: String, Codable {
    case addEntry, updateEntry, deleteEntry, undo
    // Decode old audit events without exposing close/reopen operations in the diary.
    case legacyCloseDay = "closeDay"
    case legacyReopenDay = "reopenDay"
}
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
enum NutritionError: Error, Equatable { case invalidData, conversionRequired, notFound, conflict, unsupportedSchema, storageUnavailable, attachmentMissing }

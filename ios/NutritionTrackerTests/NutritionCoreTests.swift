import XCTest
@testable import nutrition_tracker

@MainActor final class NutritionCoreTests: XCTestCase {
    private let today = Date(timeIntervalSince1970: 1_791_475_200)
    private func draft(amount: Double = 100, nutrition: NutrientValues = NutrientValues(energy: 123, protein: 10, carbohydrates: 15, fat: 3)) -> FoodEntryDraft {
        FoodEntryDraft(name: "Confirmed label", mealName: "Lunch", consumedAt: today, amount: amount, nutrition: nutrition, source: .label)
    }
    private func store(_ repository: MemoryNutritionPersistence? = nil) -> NutritionStore { NutritionStore(persistence: repository ?? MemoryNutritionPersistence(), now: { self.today }) }

    func testPartialPortionPreservesLabelCaloriesAndMissingSaturatedFat() async throws {
        let store = store(); try store.addEntry(draft(amount: 50))
        let total = store.totals(on: today)
        XCTAssertEqual(total.energy.value, 61.5); XCTAssertEqual(total.protein.value, 5)
        XCTAssertEqual(total.saturatedFat.missingCount, 1); XCTAssertNil(total.saturatedFat.value)
        let energyCalculatedFromMacros: Double = 5 * 4 + 7.5 * 4 + 1.5 * 9
        XCTAssertNotEqual(total.energy.value, energyCalculatedFromMacros, "Never replace label energy with 4/4/9")
    }
    func testMissingNutrientsAndRealZeroAreDifferent() async throws {
        let store = store()
        XCTAssertNil(store.totals(on: today).energy.value)
        try store.addEntry(draft(nutrition: NutrientValues(energy: 0)))
        try store.addEntry(draft(nutrition: NutrientValues()))
        let total = store.totals(on: today)
        XCTAssertEqual(total.energy.value, 0); XCTAssertEqual(total.energy.knownCount, 1); XCTAssertEqual(total.energy.missingCount, 1)
        XCTAssertFalse(total.energy.isComplete)
    }
    func testUnitsRequireExplicitDensityAndServingConversion() async throws {
        var input = draft(amount: 50); input.unit = .milliliter
        XCTAssertThrowsError(try input.values()) { XCTAssertEqual($0 as? NutritionError, .conversionRequired) }
        input.conversion = PortionConversion(gramsPerMilliliter: 0.8)
        XCTAssertEqual(try input.values().energy!, 49.2, accuracy: 0.001)
        input.unit = .serving; input.amount = 0.5; input.conversion = PortionConversion(gramsPerServing: 30)
        XCTAssertEqual(try input.values().energy!, 18.45, accuracy: 0.001)
        input.basis = .perServing; input.unit = .gram; input.amount = 15
        XCTAssertEqual(try input.values().energy, 61.5)
    }
    func testMutationIsAtomicRetryIdempotentAndUndoVersioned() async throws {
        let repository = MemoryNutritionPersistence(); let store = store(repository); let operation = UUID()
        let id = try store.addEntry(draft(), operationID: operation)
        XCTAssertEqual(try store.addEntry(draft(), operationID: operation), id); XCTAssertEqual(store.snapshot.entries.count, 1)
        var edit = draft(amount: 150); edit.preparation = .cooked
        try store.updateEntry(id: id, expectedVersion: 1, draft: edit)
        XCTAssertEqual(store.totals(on: today).energy.value, 184.5)
        let event = store.snapshot.changes.last!.id
        try store.undo(eventID: event)
        XCTAssertEqual(store.snapshot.entries[0].version, 3); XCTAssertEqual(store.snapshot.entries[0].draft.preparation, .unspecified)
        XCTAssertEqual(store.totals(on: today).energy.value, 123)
        XCTAssertThrowsError(try store.updateEntry(id: id, expectedVersion: 1, draft: edit)) { XCTAssertEqual($0 as? NutritionError, .conflict) }
        repository.failSave = true
        XCTAssertThrowsError(try store.addEntry(draft()))
        XCTAssertEqual(store.snapshot.entries.count, 1); XCTAssertEqual(repository.snapshot.entries.count, 1)
    }
    func testUndoNeverOverwritesLaterCorrection() async throws {
        let store = store(); let id = try store.addEntry(draft())
        let add = store.snapshot.changes.last!.id
        try store.updateEntry(id: id, expectedVersion: 1, draft: draft(amount: 150))
        XCTAssertThrowsError(try store.undo(eventID: add)) { XCTAssertEqual($0 as? NutritionError, .conflict) }
        XCTAssertEqual(store.totals(on: today).energy.value, 184.5)
    }
    func testDeleteAndUndoKeepAuditAndDoNotDoubleCount() async throws {
        let store = store(); let id = try store.addEntry(draft()); let operation = UUID()
        try store.deleteEntry(id: id, expectedVersion: 1, operationID: operation)
        try store.deleteEntry(id: id, expectedVersion: 1, operationID: operation)
        XCTAssertTrue(store.entries(on: today).isEmpty); XCTAssertNil(store.totals(on: today).energy.value)
        try store.undo(eventID: store.snapshot.changes.last!.id)
        XCTAssertEqual(store.entries(on: today).count, 1); XCTAssertEqual(store.snapshot.entries[0].version, 3)
    }
    func testExplicitCloseReopenAndRepeatedCloseKeepsVersionedSnapshots() async throws {
        let store = store(); let id = try store.addEntry(draft())
        try store.closeDay(today, completeness: .incomplete); try store.closeDay(today)
        XCTAssertEqual(store.day(on: today)?.summaries.count, 1)
        XCTAssertEqual(store.day(on: today)?.summaries.first?.completeness, .incomplete)
        XCTAssertThrowsError(try store.updateEntry(id: id, expectedVersion: 1, draft: draft(amount: 50))) { XCTAssertEqual($0 as? NutritionError, .closedDay) }
        try store.reopenDay(today); let reopen = store.snapshot.changes.last!.id
        try store.updateEntry(id: id, expectedVersion: 1, draft: draft(amount: 50))
        XCTAssertThrowsError(try store.undo(eventID: reopen)) { XCTAssertEqual($0 as? NutritionError, .conflict) }
        try store.closeDay(today)
        XCTAssertEqual(store.day(on: today)?.summaries.map { $0.totals.energy.value }, [123, 61.5])
        XCTAssertEqual(store.day(on: today)?.summaries.map(\.version), [1, 2])
    }
    func testTimezoneMidnightDoesNotCloseAndRecordsPersist() async throws {
        let repository = MemoryNutritionPersistence(); let store = store(repository)
        let before = ISO8601DateFormatter().date(from: "2026-10-08T02:59:00Z")!
        let after = ISO8601DateFormatter().date(from: "2026-10-08T03:01:00Z")!
        var input = draft(); input.consumedAt = before; try store.addEntry(input)
        input.consumedAt = after; try store.addEntry(input)
        let reopened = self.store(repository)
        XCTAssertEqual(reopened.entries(on: before).count, 1); XCTAssertEqual(reopened.entries(on: after).count, 1)
        XCTAssertEqual(reopened.dayID(for: before), "2026-10-07"); XCTAssertEqual(reopened.dayID(for: after), "2026-10-08")
        XCTAssertFalse(reopened.snapshot.days.contains(where: \.isClosed))
    }
    func testGoalsEffectiveByDateAndPauseDoesNotRewriteHistory() async throws {
        let store = store(); let next = today.addingTimeInterval(86_400)
        let initial = NutritionGoals(energy: 2000, protein: 100, carbohydrates: 200, fat: 60)
        try store.saveGoals(initial, effectiveDate: today)
        try store.saveGoals(NutritionGoals(energy: 2200, protein: 120, carbohydrates: 210, fat: 70), effectiveDate: next)
        XCTAssertEqual(store.goals(on: today), initial); XCTAssertEqual(store.goals(on: next)?.energy, 2200)
        try store.saveGoals(nil, effectiveDate: next.addingTimeInterval(86_400))
        XCTAssertNil(store.goals(on: next.addingTimeInterval(86_400))); XCTAssertEqual(store.goals(on: today), initial)
    }
    func testProductCorrectionsOnlyAffectFutureSnapshots() async throws {
        let store = store(); var product = FoodProduct(id: UUID(), version: 1, name: "Yogurt", brand: "Known", nutrition: NutrientValues(energy: 80), basis: .per100Grams, updatedAt: today)
        try store.saveProduct(product)
        try store.addEntry(product.draft(amount: 100, unit: .gram, consumedAt: today, mealName: "Breakfast"))
        product.nutrition.energy = 100; try store.saveProduct(product, expectedVersion: 1)
        XCTAssertEqual(store.snapshot.products.first?.version, 2); XCTAssertEqual(store.entries(on: today).first?.values.energy, 80)
        try store.addEntry(store.snapshot.products[0].draft(amount: 100, unit: .gram, consumedAt: today, mealName: "Snack"))
        XCTAssertEqual(store.totals(on: today).energy.value, 180)
    }
    func testRecipeConsumedFractionExcludesLeftoversAndMissingIngredientNutrients() async throws {
        let ingredients = [draft(amount: 100, nutrition: NutrientValues(energy: 300, protein: 20)), draft(amount: 100, nutrition: NutrientValues(energy: 100))]
        let recipe = FoodRecipe(id: UUID(), version: 1, name: "Soup", ingredients: ingredients, finalWeightGrams: 800, servings: 4, updatedAt: today)
        let portion = try recipe.draft(amount: 200, unit: .gram, consumedAt: today, mealName: "Dinner")
        XCTAssertEqual(try portion.values().energy, 100); XCTAssertNil(try portion.values().protein)
        let store = store(); try store.saveRecipe(recipe); try store.addEntry(portion)
        XCTAssertEqual(store.totals(on: today).energy.value, 100)
        XCTAssertEqual(try recipe.draft(amount: 0.5, unit: .serving, consumedAt: today, mealName: "Dinner").values().energy, 50)
    }
    func testHistoricalImportIdempotentConflictExplicitAndUndoKeepsLaterRecords() async throws {
        let store = store(); try store.addEntry(draft())
        let summary = HistoricalDaySummary(date: today, nutrients: NutrientValues(energy: 2100), weight: 73, activeEnergy: 300, activityMinutes: 30, originalRow: "row 2")
        XCTAssertThrowsError(try store.importBatch(fileFingerprint: "fixture", fileName: "fixture.csv", summaries: [summary])) { XCTAssertEqual($0 as? NutritionError, .conflict) }
        XCTAssertTrue(store.snapshot.importBatches.isEmpty)
        let batch = try store.importBatch(fileFingerprint: "fixture", fileName: "fixture.csv", summaries: [summary], conflictChoices: [store.dayID(for: today): .manual])
        XCTAssertEqual(try store.importBatch(fileFingerprint: "fixture", fileName: "fixture.csv", summaries: [summary]), batch)
        XCTAssertEqual(store.totals(on: today).energy.value, 123, "Original daily summary must not be summed on top of meals")
        try store.addEntry(draft(amount: 50)); try store.addWeight(kilograms: 74, recordedAt: today)
        try store.undoImportBatch(id: batch)
        XCTAssertEqual(store.snapshot.weights.count, 1); XCTAssertEqual(store.entries(on: today).count, 2)
        XCTAssertTrue(store.snapshot.historicalSummaries.isEmpty)
    }
    func testManualWeightsActivitiesAndChatDraftPersistWithoutHealthOrFoodTotals() async throws {
        let repository = MemoryNutritionPersistence(); let store = store(repository); let op = UUID()
        try store.addWeight(kilograms: 73, recordedAt: today, operationID: op)
        try store.addWeight(kilograms: 73, recordedAt: today, operationID: op)
        try store.addWeight(kilograms: 73.5, recordedAt: today.addingTimeInterval(100))
        try store.addActivity(kind: "Run", durationMinutes: 30, activeEnergy: 300, recordedAt: today)
        try store.setChatDraft("Still typing")
        let reopened = self.store(repository)
        XCTAssertEqual(reopened.snapshot.weights.count, 2); XCTAssertEqual(reopened.snapshot.activities.first?.activeEnergy, 300)
        XCTAssertNil(reopened.totals(on: today).energy.value); XCTAssertEqual(reopened.snapshot.chatDraft, "Still typing")
        let chatOperation = UUID()
        let id = try reopened.enqueueChat(text: "Question", date: today, ownerID: "owner-a", operationID: chatOperation)
        XCTAssertEqual(try reopened.enqueueChat(text: "Question", date: today, ownerID: "owner-a", operationID: chatOperation), id)
        XCTAssertEqual(reopened.snapshot.messages.count, 1); XCTAssertEqual(reopened.snapshot.outbox.count, 1)
        try reopened.updateChatDelivery(messageID: id, state: .failed)
        XCTAssertEqual(reopened.snapshot.messages.first?.state, .failed)
        try reopened.clearRemoteChat(ownerID: "owner-a")
        XCTAssertTrue(reopened.snapshot.messages.isEmpty); XCTAssertEqual(reopened.snapshot.weights.count, 2)
    }
    func testBackupRoundTripValidationAndFailedRestorePreservesHistory() async throws {
        let store = store(); try store.addEntry(draft())
        let backup = try store.exportJSON(); let restored = self.store(); try restored.restoreJSON(backup)
        XCTAssertEqual(restored.snapshot.entries, store.snapshot.entries)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any]); object["schemaVersion"] = 99
        XCTAssertThrowsError(try restored.restoreJSON(JSONSerialization.data(withJSONObject: object))) { XCTAssertEqual($0 as? NutritionError, .unsupportedSchema) }
        XCTAssertEqual(restored.snapshot.entries.count, 1)
        try restored.deleteAllLocalTracking(); XCTAssertTrue(restored.snapshot.entries.isEmpty)
    }
    func testCorruptLocalFileDoesNotGetSilentlyOverwritten() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("tracking.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let repository = NutritionFileRepository(fileURL: file)
        try repository.save(NutritionSnapshot()); try Data("broken".utf8).write(to: file)
        let store = NutritionStore(persistence: repository)
        XCTAssertTrue(store.storageNeedsRecovery); XCTAssertThrowsError(try store.addEntry(draft()))
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
        let backup = try self.store().exportJSON()
        try store.restoreJSON(backup)
        XCTAssertFalse(store.storageNeedsRecovery); XCTAssertTrue(store.snapshot.entries.isEmpty)
    }
    func testReconciliationChoicesPersistAndInvalidSourcesAreRejected() async throws {
        let repository = MemoryNutritionPersistence(); let store = store(repository)
        try store.resolveWeightConflict(groupID: "weight-conflict", observationID: "manual-uuid")
        try store.resolveWeightConflict(groupID: "other-conflict", observationID: nil)
        try store.resolveActivitySource(on: today, source: "health")
        let reloaded = self.store(repository)
        XCTAssertEqual(reloaded.snapshot.weightConflictSelections["weight-conflict"], "manual-uuid")
        XCTAssertEqual(reloaded.snapshot.weightConflictSelections["other-conflict"], "__exclude__")
        XCTAssertEqual(reloaded.snapshot.activitySourceSelections[reloaded.dayID(for: today)], "health")
        XCTAssertThrowsError(try reloaded.resolveActivitySource(on: today, source: "sum-all"))
    }
    func testImportedClosedDayRequiresExplicitReopenAndUnknownDurationStaysMissing() async throws {
        let store = store()
        let summary = HistoricalDaySummary(date: today, nutrients: NutrientValues(energy: 2000), activeEnergy: 400)
        let id = try store.importBatch(fileFingerprint: "closed", fileName: "test.csv", summaries: [summary])
        XCTAssertTrue(store.day(on: today)?.isClosed == true)
        XCTAssertNil(store.snapshot.activities.first?.durationMinutes)
        XCTAssertThrowsError(try store.addEntry(draft())) { XCTAssertEqual($0 as? NutritionError, .closedDay) }
        try store.reopenDay(today); let reopenEvent = store.snapshot.changes.last!.id
        try store.addEntry(draft())
        XCTAssertThrowsError(try store.undo(eventID: reopenEvent)) { XCTAssertEqual($0 as? NutritionError, .conflict) }
        try store.undoImportBatch(id: id)
        XCTAssertEqual(store.entries(on: today).count, 1)
        XCTAssertTrue(store.day(on: today)?.isClosed == false)
    }
    func testHistoryTimezoneCannotBeImplicitlyMigratedAndPathTraversalBackupIsRejected() async throws {
        let store = store(); try store.addEntry(draft())
        var profile = store.snapshot.profile; profile.timeZoneIdentifier = "Asia/Tokyo"
        XCTAssertThrowsError(try store.updateProfile(profile)) { XCTAssertEqual($0 as? NutritionError, .conflict) }
        let bad = NutritionAttachment(id: UUID(), relativePath: "../health-v1.json", mimeType: "image/jpeg", byteCount: 10, createdAt: today)
        XCTAssertThrowsError(try store.saveAttachment(bad)) { XCTAssertEqual($0 as? NutritionError, .invalidData) }
        XCTAssertTrue(store.snapshot.attachments.isEmpty)
    }
    func testOperationUUIDCannotBeReusedWithChangedBodyActionOrIdentity() async throws {
        let repository = MemoryNutritionPersistence(); let store = store(repository); let op = UUID()
        let id = try store.addEntry(draft(), operationID: op)
        XCTAssertThrowsError(try store.addEntry(draft(amount: 50), operationID: op)) { XCTAssertEqual($0 as? NutritionError, .conflict) }
        XCTAssertThrowsError(try store.deleteEntry(id: id, expectedVersion: 1, operationID: op)) { XCTAssertEqual($0 as? NutritionError, .conflict) }
        let reopened = self.store(repository)
        XCTAssertEqual(try reopened.addEntry(draft(), operationID: op), id)
        XCTAssertEqual(reopened.entries(on: today).count, 1)
        let edit = UUID(); try reopened.updateEntry(id: id, expectedVersion: 1, draft: draft(amount: 50), operationID: edit)
        XCTAssertThrowsError(try reopened.updateEntry(id: UUID(), expectedVersion: 1, draft: draft(amount: 50), operationID: edit)) { XCTAssertEqual($0 as? NutritionError, .conflict) }
        XCTAssertEqual(reopened.totals(on: today).energy.value, 61.5)
    }
    func testLegacyReceiptsDecodeButCannotAcknowledgeUnverifiableRetry() async throws {
        let repository = MemoryNutritionPersistence(); let op = UUID()
        repository.snapshot.operations = [NutritionOperationReceipt(id: op, resultID: UUID())]
        let store = self.store(repository)
        XCTAssertFalse(store.storageNeedsRecovery)
        XCTAssertThrowsError(try store.addEntry(draft(), operationID: op)) { XCTAssertEqual($0 as? NutritionError, .conflict) }
        try store.addEntry(draft()); XCTAssertEqual(store.entries(on: today).count, 1)
    }
    func testImportUndoRestoresPriorChoiceButPreservesLaterDecisionEvenSameSelection() async throws {
        let store = store(); let day = store.dayID(for: today)
        try store.resolveIntake(on: today, selection: .health)
        let prior = store.snapshot.intakeResolutions[0]
        let summary = HistoricalDaySummary(date: today, nutrients: NutrientValues(energy: 2000), isClosed: false)
        let first = try store.importBatch(fileFingerprint: "first", fileName: "first.csv", summaries: [summary], conflictChoices: [day: .historical])
        try store.undoImportBatch(id: first)
        XCTAssertEqual(store.snapshot.intakeResolutions, [prior])
        let second = try store.importBatch(fileFingerprint: "second", fileName: "second.csv", summaries: [summary], conflictChoices: [day: .historical])
        try store.resolveIntake(on: today, selection: .historical)
        let later = store.snapshot.intakeResolutions[0]
        try store.undoImportBatch(id: second)
        XCTAssertEqual(store.snapshot.intakeResolutions, [later], "A later user's selection must not be overwritten by undo")
    }
    func testImportedWeightAndActivityCannotBeDeletedOutsideBatchUndo() async throws {
        let store = store()
        let summary = HistoricalDaySummary(date: today, nutrients: NutrientValues(energy: 2000), weight: 73, activeEnergy: 300, activityMinutes: 30)
        let batch = try store.importBatch(fileFingerprint: "readonly", fileName: "sheet.csv", summaries: [summary])
        XCTAssertThrowsError(try store.deleteWeight(id: store.snapshot.weights[0].id))
        XCTAssertThrowsError(try store.deleteActivity(id: store.snapshot.activities[0].id))
        XCTAssertEqual(store.snapshot.weights.count, 1); XCTAssertEqual(store.snapshot.activities.count, 1)
        try store.undoImportBatch(id: batch)
        XCTAssertTrue(store.snapshot.weights.isEmpty); XCTAssertTrue(store.snapshot.activities.isEmpty)
    }
    func testClosedGoalsStayFrozenAfterBackdatedGoalChangeAndUnspecifiedGoalsRemainNil() async throws {
        let store = store()
        let initial = NutritionGoals(energy: 2000, protein: 100, carbohydrates: 200, fat: 60)
        try store.saveGoals(initial, effectiveDate: today); try store.addEntry(draft()); try store.closeDay(today)
        let id = store.day(on: today)!.summaries.last!.goalVersionID
        try store.saveGoals(NutritionGoals(energy: 2400, protein: 130, carbohydrates: 250, fat: 80), effectiveDate: today)
        XCTAssertEqual(store.goals(on: today), initial); XCTAssertEqual(store.goalVersion(on: today)?.id, id)
        try store.reopenDay(today)
        XCTAssertEqual(store.goals(on: today)?.energy, 2400)
        let unset = self.store(); try unset.closeDay(today)
        try unset.saveGoals(initial, effectiveDate: today)
        XCTAssertNil(unset.goals(on: today), "A closed day without a saved goal ID must not guess a goal added later")
    }
    func testClosedHistoricalSourceFreezesOriginalTotalsWithoutInventingFoodEntries() async throws {
        let store = store(); let day = store.dayID(for: today)
        let original = NutrientValues(energy: 2100, protein: 120, carbohydrates: 200, fat: 80)
        let batch = try store.importBatch(fileFingerprint: "historical-close", fileName: "sheet.csv", summaries: [HistoricalDaySummary(date: today, nutrients: original, isClosed: false)], conflictChoices: [day: .historical])
        try store.closeDay(today)
        let closure = store.day(on: today)!.summaries.last!
        XCTAssertEqual(closure.intakeSource, .historical); XCTAssertEqual(closure.totals.energy.value, 2100)
        XCTAssertEqual(closure.totals.entryCount, 0); XCTAssertTrue(store.snapshot.entries.isEmpty)
        try store.undoImportBatch(id: batch)
        XCTAssertEqual(store.day(on: today)?.summaries.last?.totals.energy.value, 2100, "Deleting the source import must not rewrite an explicit frozen closure")
    }
    func testHealthSelectedClosureCarriesNoHealthValuesInTrackingSnapshot() async throws {
        let store = store(); try store.addEntry(draft())
        try store.resolveIntake(on: today, selection: .health); try store.closeDay(today)
        let closure = store.day(on: today)!.summaries.last!
        XCTAssertEqual(closure.intakeSource, .health); XCTAssertNil(closure.totals.energy.value)
        XCTAssertEqual(closure.totals.entryCount, 0)
        XCTAssertEqual(store.entries(on: today).count, 1, "Changing the selected intake source must not delete the manual record")
        var forged = store.snapshot
        forged.days[0].summaries[0].totals.include(NutrientValues(energy: 1000))
        XCTAssertThrowsError(try NutritionBackup.validate(forged), "A restored tracking snapshot must not smuggle Health values into its synced day payload")
    }
}

@MainActor private final class MemoryNutritionPersistence: NutritionPersistence {
    var snapshot = NutritionSnapshot()
    var failSave = false
    func load() throws -> NutritionSnapshot { snapshot }
    func save(_ snapshot: NutritionSnapshot) throws { if failSave { throw NutritionError.storageUnavailable }; self.snapshot = snapshot }
}

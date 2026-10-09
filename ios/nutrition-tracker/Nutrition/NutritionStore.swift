import Foundation
import Observation
import CryptoKit

struct NutritionStoreCheckpoint {
    fileprivate let storeID: UUID
    let snapshot: NutritionSnapshot
    let storageNeedsRecovery: Bool
    let errorKey: String?
    fileprivate let rawBytes: Data?
    fileprivate let hasPhysicalCheckpoint: Bool
}

@MainActor @Observable final class NutritionStore {
    private(set) var snapshot = NutritionSnapshot()
    private(set) var errorKey: String?
    private(set) var storageNeedsRecovery = false
    @ObservationIgnored private let checkpointIdentity = UUID()
    @ObservationIgnored private let persistence: any NutritionPersistence
    @ObservationIgnored private let now: () -> Date

    init(persistence: (any NutritionPersistence)? = nil, now: @escaping () -> Date = Date.init) {
        self.persistence = persistence ?? NutritionFileRepository(); self.now = now
        reload()
    }
    func reload() {
        do { snapshot = try persistence.load(); try NutritionBackup.validate(snapshot); storageNeedsRecovery = false; errorKey = nil }
        catch { storageNeedsRecovery = true; errorKey = "Could not read your nutrition history. The saved file was preserved." }
    }
    func clearError() { errorKey = nil }
    func captureCheckpoint() throws -> NutritionStoreCheckpoint {
        let physical = persistence as? any NutritionCheckpointPersistence
        guard !storageNeedsRecovery || physical != nil else { throw NutritionError.storageUnavailable }
        return NutritionStoreCheckpoint(storeID: checkpointIdentity, snapshot: snapshot,
            storageNeedsRecovery: storageNeedsRecovery, errorKey: errorKey,
            rawBytes: try physical?.captureRawCheckpoint(), hasPhysicalCheckpoint: physical != nil)
    }
    func restoreCheckpoint(_ checkpoint: NutritionStoreCheckpoint, expectedSnapshot: NutritionSnapshot) throws {
        guard checkpoint.storeID == checkpointIdentity, snapshot == expectedSnapshot else { throw NutritionError.conflict }
        if checkpoint.hasPhysicalCheckpoint {
            guard let physical = persistence as? any NutritionCheckpointPersistence else { throw NutritionError.storageUnavailable }
            try physical.restoreRawCheckpoint(checkpoint.rawBytes)
        } else {
            guard !checkpoint.storageNeedsRecovery else { throw NutritionError.storageUnavailable }
            try persistence.save(checkpoint.snapshot)
        }
        snapshot = checkpoint.snapshot; storageNeedsRecovery = checkpoint.storageNeedsRecovery; errorKey = checkpoint.errorKey
    }
    func publishPreparedSnapshot(_ candidate: NutritionSnapshot, expectedSnapshot: NutritionSnapshot) throws {
        guard snapshot == expectedSnapshot else { throw NutritionError.conflict }
        try commit(candidate)
    }
    func dayID(for date: Date) -> String { snapshot.profile.dayID(for: date) }
    func entries(on date: Date) -> [FoodEntry] { entries(dayID: dayID(for: date)) }
    func entries(dayID: String) -> [FoodEntry] { snapshot.entries.filter { !$0.deleted && $0.dayID == dayID }.sorted { $0.draft.consumedAt < $1.draft.consumedAt } }
    func totals(on date: Date) -> NutritionTotals { totals(dayID: dayID(for: date)) }
    func totals(dayID: String) -> NutritionTotals { Self.totals(snapshot, dayID: dayID) }
    func day(on date: Date) -> NutritionDayLog? { snapshot.days.first { $0.id == dayID(for: date) } }
    func goals(on date: Date) -> NutritionGoals? { goalVersion(on: date)?.goals }
    func goalVersion(on date: Date) -> NutritionGoalVersion? {
        let day = dayID(for: date)
        if let closed = snapshot.days.first(where: { $0.id == day && $0.isClosed }) {
            guard let id = closed.summaries.last?.goalVersionID else { return nil }
            return snapshot.goals.first { $0.id == id }
        }
        return snapshot.goals.filter { $0.effectiveDay <= day }.sorted { $0.effectiveDay == $1.effectiveDay ? $0.createdAt < $1.createdAt : $0.effectiveDay < $1.effectiveDay }.last
    }
    private static func totals(_ snapshot: NutritionSnapshot, dayID: String) -> NutritionTotals {
        var result = NutritionTotals()
        for entry in snapshot.entries where !entry.deleted && entry.dayID == dayID { result.include(entry.values) }
        return result
    }
    private func commit(_ candidate: NutritionSnapshot) throws {
        guard !storageNeedsRecovery else { throw NutritionError.storageUnavailable }
        do { try NutritionBackup.validate(candidate); try persistence.save(candidate); snapshot = candidate; errorKey = nil }
        catch { errorKey = "Could not save your nutrition history. Please try again."; throw error }
    }
    private func requestFingerprint<Input: Encodable>(_ action: String, input: Input, identity: [String] = []) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = Data(action.utf8); bytes.append(0); bytes.append(try encoder.encode(input)); bytes.append(0); bytes.append(try encoder.encode(identity))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func perform(operationID: UUID, fingerprint: String, _ body: (inout NutritionSnapshot) throws -> UUID?) throws -> UUID? {
        if let old = snapshot.operations.first(where: { $0.id == operationID }) {
            // Legacy receipts have no request digest, so they cannot prove an identical retry.
            guard old.fingerprint == fingerprint else { throw NutritionError.conflict }; return old.resultID
        }
        var candidate = snapshot
        let id = try body(&candidate)
        candidate.operations.append(NutritionOperationReceipt(id: operationID, resultID: id, fingerprint: fingerprint))
        try commit(candidate); return id
    }
    private func requireResult(_ result: UUID?) throws -> UUID { guard let result else { throw NutritionError.conflict }; return result }
    private func ensureOpen(_ snapshot: NutritionSnapshot, dayID: String) throws {
        if snapshot.days.contains(where: { $0.id == dayID && $0.isClosed }) { throw NutritionError.closedDay }
    }
    private func ensureDay(_ snapshot: inout NutritionSnapshot, dayID: String) {
        if !snapshot.days.contains(where: { $0.id == dayID }) { snapshot.days.append(NutritionDayLog(id: dayID)) }
    }
    @discardableResult func addEntry(_ draft: FoodEntryDraft, operationID: UUID = UUID()) throws -> UUID {
        try requireResult(perform(operationID: operationID, fingerprint: requestFingerprint("addEntry", input: draft)) { state in
            try draft.validate(); let day = state.profile.dayID(for: draft.consumedAt); try ensureOpen(state, dayID: day)
            ensureDay(&state, dayID: day)
            let entry = FoodEntry(id: UUID(), version: 1, dayID: day, draft: draft, createdAt: now(), updatedAt: now())
            state.entries.append(entry)
            state.changes.append(NutritionChangeEvent(id: UUID(), operationID: operationID, kind: .addEntry, createdAt: now(), entryID: entry.id, beforeEntry: nil, afterEntry: entry, beforeDay: nil, afterDay: nil))
            return entry.id
        })
    }
    func updateEntry(id: UUID, expectedVersion: Int, draft: FoodEntryDraft, operationID: UUID = UUID()) throws {
        _ = try perform(operationID: operationID, fingerprint: requestFingerprint("updateEntry", input: draft, identity: [id.uuidString, String(expectedVersion)])) { state in
            try draft.validate()
            guard let index = state.entries.firstIndex(where: { $0.id == id && !$0.deleted }) else { throw NutritionError.notFound }
            let before = state.entries[index]; guard before.version == expectedVersion else { throw NutritionError.conflict }
            let day = state.profile.dayID(for: draft.consumedAt)
            try ensureOpen(state, dayID: before.dayID); try ensureOpen(state, dayID: day); ensureDay(&state, dayID: day)
            state.entries[index].draft = draft; state.entries[index].dayID = day; state.entries[index].version += 1; state.entries[index].updatedAt = now()
            state.changes.append(NutritionChangeEvent(id: UUID(), operationID: operationID, kind: .updateEntry, createdAt: now(), entryID: id, beforeEntry: before, afterEntry: state.entries[index], beforeDay: nil, afterDay: nil))
            return id
        }
    }
    func deleteEntry(id: UUID, expectedVersion: Int, operationID: UUID = UUID()) throws {
        _ = try perform(operationID: operationID, fingerprint: requestFingerprint("deleteEntry", input: [id.uuidString, String(expectedVersion)])) { state in
            guard let index = state.entries.firstIndex(where: { $0.id == id && !$0.deleted }) else { throw NutritionError.notFound }
            let before = state.entries[index]; guard before.version == expectedVersion else { throw NutritionError.conflict }
            try ensureOpen(state, dayID: before.dayID)
            state.entries[index].deleted = true; state.entries[index].version += 1; state.entries[index].updatedAt = now()
            state.changes.append(NutritionChangeEvent(id: UUID(), operationID: operationID, kind: .deleteEntry, createdAt: now(), entryID: id, beforeEntry: before, afterEntry: state.entries[index], beforeDay: nil, afterDay: nil))
            return id
        }
    }
    func closeDay(_ date: Date, completeness: DayCompleteness = .complete, operationID: UUID = UUID()) throws {
        _ = try perform(operationID: operationID, fingerprint: requestFingerprint("closeDay", input: [dayID(for: date), completeness.rawValue])) { state in
            let day = state.profile.dayID(for: date); ensureDay(&state, dayID: day)
            let index = state.days.firstIndex { $0.id == day }!
            guard !state.days[index].isClosed else { return nil }
            let before = state.days[index]
            let goals = state.goals.filter { $0.effectiveDay <= day }.sorted { $0.effectiveDay == $1.effectiveDay ? $0.createdAt < $1.createdAt : $0.effectiveDay < $1.effectiveDay }.last
            let source = state.intakeResolutions.first(where: { $0.dayID == day })?.selection ?? .manual
            var totals = NutritionTotals()
            switch source {
            case .manual: totals = Self.totals(state, dayID: day)
            case .historical:
                let historical = state.historicalSummaries.filter { $0.dayID == day }
                guard historical.count == 1 else { throw NutritionError.conflict }
                totals.include(historical[0].nutrients)
                totals.entryCount = 0 // A daily spreadsheet summary is not an invented food entry.
            case .health:
                // Frozen Health values belong only to the separate Health persistence domain.
                break
            }
            let summary = ClosedDaySummary(id: UUID(), version: before.summaries.count + 1, closedAt: now(), completeness: completeness, totals: totals, entryVersions: Dictionary(uniqueKeysWithValues: state.entries.filter { $0.dayID == day }.map { ($0.id.uuidString, $0.version) }), goalVersionID: goals?.id, intakeSource: source)
            state.days[index].isClosed = true; state.days[index].version += 1; state.days[index].summaries.append(summary)
            state.changes.append(NutritionChangeEvent(id: UUID(), operationID: operationID, kind: .closeDay, createdAt: now(), entryID: nil, beforeEntry: nil, afterEntry: nil, beforeDay: before, afterDay: state.days[index]))
            return summary.id
        }
    }
    func reopenDay(_ date: Date, operationID: UUID = UUID()) throws {
        _ = try perform(operationID: operationID, fingerprint: requestFingerprint("reopenDay", input: dayID(for: date))) { state in
            let day = state.profile.dayID(for: date)
            guard let index = state.days.firstIndex(where: { $0.id == day }) else { throw NutritionError.notFound }
            guard state.days[index].isClosed else { return nil }
            let before = state.days[index]; state.days[index].isClosed = false; state.days[index].version += 1
            let versions = Dictionary(uniqueKeysWithValues: state.entries.filter { $0.dayID == day }.map { ($0.id.uuidString, $0.version) })
            state.changes.append(NutritionChangeEvent(id: UUID(), operationID: operationID, kind: .reopenDay, createdAt: now(), entryID: nil, beforeEntry: nil, afterEntry: nil, beforeDay: before, afterDay: state.days[index], dayEntryVersions: versions))
            return nil
        }
    }
    func undo(eventID: UUID, operationID: UUID = UUID()) throws {
        _ = try perform(operationID: operationID, fingerprint: requestFingerprint("undo", input: eventID)) { state in
            guard let eventIndex = state.changes.firstIndex(where: { $0.id == eventID }) else { throw NutritionError.notFound }
            let event = state.changes[eventIndex]
            guard event.undoneBy == nil, event.kind != .undo else { throw NutritionError.conflict }
            if let after = event.afterEntry {
                guard let index = state.entries.firstIndex(where: { $0.id == after.id }), state.entries[index] == after else { throw NutritionError.conflict }
                try ensureOpen(state, dayID: after.dayID)
                if var before = event.beforeEntry {
                    try ensureOpen(state, dayID: before.dayID); before.version = after.version + 1; before.updatedAt = now(); state.entries[index] = before
                } else { state.entries[index].deleted = true; state.entries[index].version += 1; state.entries[index].updatedAt = now() }
            } else if let after = event.afterDay, let before = event.beforeDay {
                guard let index = state.days.firstIndex(where: { $0.id == after.id }), state.days[index] == after else { throw NutritionError.conflict }
                // A reopen undo is safe only while no food corrections happened since reopening.
                if event.kind == .reopenDay {
                    let versions = Dictionary(uniqueKeysWithValues: state.entries.filter { $0.dayID == after.id }.map { ($0.id.uuidString, $0.version) })
                    guard let expected = event.dayEntryVersions ?? before.summaries.last?.entryVersions,
                          versions == expected else { throw NutritionError.conflict }
                }
                state.days[index].isClosed = before.isClosed; state.days[index].version += 1
                // Retain closure snapshots even when their closing action is undone.
            }
            state.changes[eventIndex].undoneBy = operationID
            state.changes.append(NutritionChangeEvent(id: UUID(), operationID: operationID, kind: .undo, createdAt: now(), entryID: event.entryID, beforeEntry: nil, afterEntry: nil, beforeDay: nil, afterDay: nil))
            return event.entryID
        }
    }
    func saveGoals(_ goals: NutritionGoals?, effectiveDate: Date, operationID: UUID = UUID(), versionID: UUID? = nil) throws {
        let effectiveID = versionID ?? operationID
        _ = try perform(operationID: operationID, fingerprint: requestFingerprint("saveGoals", input: goals,
            identity: [dayID(for: effectiveDate), effectiveID.uuidString])) { state in
            guard goals?.isValid != false else { throw NutritionError.invalidData }
            let effectiveDay = state.profile.dayID(for: effectiveDate)
            if let existing = state.goals.first(where: { $0.id == effectiveID }) {
                guard existing.effectiveDay == effectiveDay, existing.goals == goals else { throw NutritionError.conflict }
                return existing.id
            }
            let version = NutritionGoalVersion(id: effectiveID, effectiveDay: effectiveDay, effectiveDate: effectiveDate, goals: goals, createdAt: now())
            state.goals.append(version); return version.id
        }
    }
    func updateProfile(_ profile: NutritionProfile) throws {
        // Historical day identifiers were recorded in the original profile timezone.
        // Changing that zone is an explicit migration, not a preferences edit.
        guard profile.timeZoneIdentifier == snapshot.profile.timeZoneIdentifier || snapshot.days.isEmpty else { throw NutritionError.conflict }
        var state = snapshot; state.profile = profile; try commit(state)
    }
    @discardableResult func saveProduct(_ product: FoodProduct, expectedVersion: Int? = nil, operationID: UUID = UUID()) throws -> UUID {
        try requireResult(perform(operationID: operationID, fingerprint: requestFingerprint("saveProduct", input: product, identity: [expectedVersion.map(String.init) ?? "new"])) { state in
            var product = product; product.updatedAt = now()
            if let index = state.products.firstIndex(where: { $0.id == product.id }) {
                guard expectedVersion == state.products[index].version else { throw NutritionError.conflict }
                product.version = state.products[index].version + 1; state.products[index] = product
            } else { guard expectedVersion == nil else { throw NutritionError.notFound }; product.version = 1; state.products.append(product) }
            return product.id
        })
    }
    @discardableResult func saveRecipe(_ recipe: FoodRecipe, expectedVersion: Int? = nil, operationID: UUID = UUID()) throws -> UUID {
        try requireResult(perform(operationID: operationID, fingerprint: requestFingerprint("saveRecipe", input: recipe, identity: [expectedVersion.map(String.init) ?? "new"])) { state in
            var recipe = recipe; recipe.updatedAt = now()
            if let index = state.recipes.firstIndex(where: { $0.id == recipe.id }) {
                guard expectedVersion == state.recipes[index].version else { throw NutritionError.conflict }
                recipe.version = state.recipes[index].version + 1; state.recipes[index] = recipe
            } else { guard expectedVersion == nil else { throw NutritionError.notFound }; recipe.version = 1; state.recipes.append(recipe) }
            return recipe.id
        })
    }
    @discardableResult func addWeight(kilograms: Double, recordedAt: Date = Date(), notes: String = "", operationID: UUID = UUID()) throws -> UUID {
        try requireResult(perform(operationID: operationID, fingerprint: requestFingerprint("addWeight", input: kilograms, identity: [String(recordedAt.timeIntervalSince1970), notes])) { state in let value = ManualWeightEntry(id: UUID(), recordedAt: recordedAt, kilograms: kilograms, notes: notes); state.weights.append(value); return value.id })
    }
    func updateWeight(_ value: ManualWeightEntry) throws {
        var state = snapshot; guard let index = state.weights.firstIndex(where: { $0.id == value.id && $0.source == .manual }), value.source == .manual else { throw NutritionError.notFound }
        state.weights[index] = value; try commit(state)
    }
    func deleteWeight(id: UUID) throws { var state = snapshot; guard state.weights.contains(where: { $0.id == id && $0.source == .manual }) else { throw NutritionError.notFound }; state.weights.removeAll { $0.id == id }; try commit(state) }
    @discardableResult func addActivity(kind: String, durationMinutes: Double?, activeEnergy: Double? = nil, recordedAt: Date = Date(), notes: String = "", operationID: UUID = UUID()) throws -> UUID {
        try requireResult(perform(operationID: operationID, fingerprint: requestFingerprint("addActivity", input: [durationMinutes, activeEnergy], identity: [kind, String(recordedAt.timeIntervalSince1970), notes])) { state in let value = ManualActivityEntry(id: UUID(), recordedAt: recordedAt, kind: kind, durationMinutes: durationMinutes, activeEnergy: activeEnergy, notes: notes); state.activities.append(value); return value.id })
    }
    func updateActivity(_ value: ManualActivityEntry) throws { var state = snapshot; guard let index = state.activities.firstIndex(where: { $0.id == value.id && $0.source == .manual }), value.source == .manual else { throw NutritionError.notFound }; state.activities[index] = value; try commit(state) }
    func deleteActivity(id: UUID) throws { var state = snapshot; guard state.activities.contains(where: { $0.id == id && $0.source == .manual }) else { throw NutritionError.notFound }; state.activities.removeAll { $0.id == id }; try commit(state) }
    func resolveIntake(on date: Date, selection: IntakeSelection) throws {
        var state = snapshot; let day = dayID(for: date); state.intakeResolutions.removeAll { $0.dayID == day }; state.intakeResolutions.append(IntakeResolution(dayID: day, selection: selection)); try commit(state)
    }
    func resolveWeightConflict(groupID: String, observationID: String?) throws {
        guard !groupID.isEmpty, groupID.count <= 500, observationID.map({ !$0.isEmpty && $0.count <= 500 }) != false else { throw NutritionError.invalidData }
        var state = snapshot; state.weightConflictSelections[groupID] = observationID ?? "__exclude__"; try commit(state)
    }
    func resolveActivitySource(on date: Date, source: String) throws {
        guard ["manual", "spreadsheet", "health"].contains(source) else { throw NutritionError.invalidData }
        var state = snapshot; state.activitySourceSelections[dayID(for: date)] = source; try commit(state)
    }
    @discardableResult func importBatch(fileFingerprint: String, fileName: String, summaries: [HistoricalDaySummary], conflictChoices: [String: IntakeSelection] = [:]) throws -> UUID {
        if let old = snapshot.importBatches.first(where: { $0.fingerprint == fileFingerprint }) { return old.id }
        guard !fileFingerprint.isEmpty, !summaries.isEmpty else { throw NutritionError.invalidData }
        var state = snapshot; var batch = NutritionImportBatch(id: UUID(), fingerprint: fileFingerprint, importedAt: now(), fileName: fileName)
        var days = Set<String>()
        for value in summaries {
            let day = state.profile.dayID(for: value.date)
            guard days.insert(day).inserted, !state.historicalSummaries.contains(where: { $0.dayID == day }) else { throw NutritionError.conflict }
            if state.entries.contains(where: { !$0.deleted && $0.dayID == day }) && conflictChoices[day] == nil { throw NutritionError.conflict }
            if !state.days.contains(where: { $0.id == day }) {
                state.days.append(NutritionDayLog(id: day, isClosed: value.isClosed)); batch.createdDayIDs.append(day)
            }
            state.historicalSummaries.append(HistoricalNutritionSummary(id: UUID(), dayID: day, nutrients: value.nutrients, isClosed: value.isClosed, notes: value.notes, importBatchID: batch.id, sourceRow: value.originalRow))
            if let kilograms = value.weight { state.weights.append(ManualWeightEntry(id: UUID(), recordedAt: value.date, kilograms: kilograms, source: .spreadsheet, notes: value.notes, importBatchID: batch.id)) }
            if value.activityMinutes != nil || value.activeEnergy != nil { state.activities.append(ManualActivityEntry(id: UUID(), recordedAt: value.date, kind: "Imported activity", durationMinutes: value.activityMinutes, activeEnergy: value.activeEnergy, source: .spreadsheet, notes: value.notes, importBatchID: batch.id)) }
            if let selection = conflictChoices[day] {
                if let previous = state.intakeResolutions.first(where: { $0.dayID == day }) { batch.previousResolutions.append(previous) }
                let installed = IntakeResolution(dayID: day, selection: selection, createdByBatchID: batch.id)
                batch.installedResolutions.append(installed); state.intakeResolutions.removeAll { $0.dayID == day }; state.intakeResolutions.append(installed)
            }
        }
        state.importBatches.append(batch)
        try commit(state); return batch.id
    }
    func undoImportBatch(id: UUID) throws {
        var state = snapshot; guard let batch = state.importBatches.first(where: { $0.id == id }) else { throw NutritionError.notFound }
        state.historicalSummaries.removeAll { $0.importBatchID == id }; state.weights.removeAll { $0.importBatchID == id }; state.activities.removeAll { $0.importBatchID == id }; state.importBatches.removeAll { $0.id == id }
        for installed in batch.installedResolutions {
            // Preserve subsequent user decisions, even when they happen to pick the same source.
            guard state.intakeResolutions.contains(installed) else { continue }
            state.intakeResolutions.removeAll { $0.dayID == installed.dayID }
            if let previous = batch.previousResolutions.first(where: { $0.dayID == installed.dayID }) { state.intakeResolutions.append(previous) }
        }
        let entryDayIDs = Set(state.entries.map(\.dayID))
        state.days.removeAll { batch.createdDayIDs.contains($0.id) && $0.version == 1 && !entryDayIDs.contains($0.id) }
        try commit(state)
    }
    func setChatDraft(_ draft: String) throws { var state = snapshot; state.chatDraft = draft; try commit(state) }
    @discardableResult func enqueueChat(text: String, date: Date, attachmentIDs: [UUID] = [], ownerID: String? = nil, operationID: UUID = UUID()) throws -> UUID {
        try requireResult(perform(operationID: operationID, fingerprint: requestFingerprint("enqueueChat", input: text, identity: [dayID(for: date), ownerID ?? "local"] + attachmentIDs.map(\.uuidString))) { state in
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 50_000,
                  attachmentIDs.allSatisfy({ id in state.attachments.contains(where: { $0.id == id }) }) else { throw NutritionError.invalidData }
            let message = PersistentChatMessage(id: UUID(), role: .user, text: text, createdAt: now(), dayID: state.profile.dayID(for: date), state: .queued, operationID: operationID, attachmentIDs: attachmentIDs, remoteOwnerID: ownerID)
            state.messages.append(message); state.outbox.append(ChatOutboxItem(id: operationID, messageID: message.id)); state.chatDraft = ""; return message.id
        })
    }
    func updateChatDelivery(messageID: UUID, state delivery: ChatDeliveryState) throws {
        var state = snapshot; guard let i = state.messages.firstIndex(where: { $0.id == messageID }) else { throw NutritionError.notFound }
        state.messages[i].state = delivery
        if let j = state.outbox.firstIndex(where: { $0.messageID == messageID }) { state.outbox[j].state = delivery; if delivery == .sending { state.outbox[j].attempts += 1 } }
        try commit(state)
    }
    func appendAssistantMessage(text: String, date: Date, replyTo: UUID, ownerID: String? = nil) throws {
        var state = snapshot
        guard let user = state.messages.first(where: { $0.id == replyTo && $0.role == .user }) else { throw NutritionError.notFound }
        guard user.remoteOwnerID == ownerID else { throw NutritionError.conflict }
        let requestID = user.operationID ?? user.id
        if let existing = state.messages.first(where: { $0.role == .assistant && $0.operationID == requestID }) {
            guard existing.remoteOwnerID == ownerID else { throw NutritionError.conflict }
            return
        }
        if let legacy = state.messages.firstIndex(where: { $0.role == .assistant && $0.operationID == replyTo }) {
            guard state.messages[legacy].remoteOwnerID == ownerID else { throw NutritionError.conflict }
            state.messages[legacy].operationID = requestID; try commit(state); return
        }
        state.messages.append(PersistentChatMessage(id: UUID(), role: .assistant, text: text, createdAt: now(), dayID: state.profile.dayID(for: date), state: .delivered, operationID: requestID, remoteOwnerID: ownerID)); try commit(state)
    }
    func saveAttachment(_ value: NutritionAttachment) throws { var state = snapshot; guard !state.attachments.contains(where: { $0.id == value.id }) else { return }; state.attachments.append(value); try commit(state) }
    func updateAttachmentRemoteID(id: UUID, remoteID: String) throws {
        guard UUID(uuidString: remoteID) != nil else { throw NutritionError.invalidData }
        var state = snapshot; guard let index = state.attachments.firstIndex(where: { $0.id == id }) else { throw NutritionError.notFound }
        state.attachments[index].remoteAttachmentID = remoteID; try commit(state)
    }
    func removeAttachment(id: UUID) throws {
        var state = snapshot
        state.attachments.removeAll { $0.id == id }
        for index in state.messages.indices where state.messages[index].attachmentIDs.contains(id) {
            state.messages[index].attachmentIDs.removeAll { $0 == id }
            state.messages[index].attachmentRemoved = true
            if state.messages[index].state != .delivered {
                state.messages[index].state = .cancelled
                let messageID = state.messages[index].id
                for outboxIndex in state.outbox.indices where state.outbox[outboxIndex].messageID == messageID {
                    state.outbox[outboxIndex].state = .cancelled
                }
            }
        }
        try commit(state)
    }
    func clearRemoteChat(ownerID: String) throws {
        var state = snapshot; let ids = Set(state.messages.filter { $0.remoteOwnerID == ownerID }.map(\.id)); state.messages.removeAll { $0.remoteOwnerID == ownerID }; state.outbox.removeAll { ids.contains($0.messageID) }; state.attachments.removeAll { $0.remoteOwnerID == ownerID }; state.chatDraft = ""; try commit(state)
    }
    func exportJSON() throws -> Data { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(snapshot) }
    /// Explicit backup recovery preserves typed dates and can replace an unreadable local file.
    func restorePreparedSnapshot(_ candidate: NutritionSnapshot, expectedSnapshot: NutritionSnapshot) throws {
        guard snapshot == expectedSnapshot else { throw NutritionError.conflict }
        try NutritionBackup.validate(candidate)
        try persistence.save(candidate); snapshot = candidate; storageNeedsRecovery = false; errorKey = nil
    }
    func restoreJSON(_ data: Data) throws {
        let candidate = try NutritionBackup.decode(data, datesISO8601: true)
        // Restore is the explicit recovery action, including when the previous local file is unreadable.
        try persistence.save(candidate); snapshot = candidate; storageNeedsRecovery = false; errorKey = nil
    }
    func deleteAllLocalTracking() throws { try commit(NutritionSnapshot()) }
}

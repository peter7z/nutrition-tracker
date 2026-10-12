import Foundation
import Observation
import CoreFoundation

@MainActor @Observable final class HealthSyncModel {
    private(set) var snapshot = HealthSnapshot()
    private(set) var stagedImport: StagedHealthImport?
    private(set) var isWorking = false
    private(set) var errorKey: String?
    private(set) var storageNeedsRecovery = false
    private(set) var readingMetric: HealthMetric?
    private(set) var readCount = 0
    private let client: any HealthDataClient
    private let persistence: any HealthPersistence
    private let now: () -> Date
    private var generation = 0

    var isAvailable: Bool { client.isAvailable }
    func weightUploadChanges(anchor: Data?) async throws -> HealthDelta {
        guard snapshot.isConnected, snapshot.configuration?.metrics.contains(.weight) == true,
              !storageNeedsRecovery, client.isAvailable else { throw HealthOperationError.unavailable }
        return try await client.changes(for: .weight, start: nil, anchor: anchor)
    }

    init(client: (any HealthDataClient)? = nil, persistence: (any HealthPersistence)? = nil, now: @escaping () -> Date = Date.init) {
        self.client = client ?? HealthKitClient()
        self.persistence = persistence ?? HealthFileRepository()
        self.now = now
        reload()
    }

    func reload() {
        guard !isWorking else { return }
        do {
            let loaded = try persistence.load()
            try validateRestoredSnapshot(loaded)
            snapshot = loaded
            storageNeedsRecovery = false
            errorKey = nil
        } catch {
            storageNeedsRecovery = true
            errorKey = "Local data could not be read. The existing file has not been changed."
        }
    }

    func prepareImport(configuration: HealthImportConfiguration) async {
        guard !isWorking, !storageNeedsRecovery else { return }
        generation += 1
        let operation = generation
        isWorking = true
        errorKey = nil
        stagedImport = nil
        defer { finish(operation) }
        do {
            guard client.isAvailable else { throw HealthOperationError.unavailable }
            guard !configuration.metrics.isEmpty, configuration.startDate.map({ $0 <= now() }) ?? true,
                  TimeZone(identifier: configuration.timeZoneIdentifier) != nil else { throw HealthOperationError.invalidConfiguration }
            try await client.requestReadAccess(to: configuration.metrics)
            guard operation == generation else { return }
            var candidate = HealthSnapshot()
            candidate.configuration = configuration
            candidate.goals = snapshot.goals
            candidate.closedNutritionDays = snapshot.closedNutritionDays
            candidate.pendingChatContexts = snapshot.pendingChatContexts
            candidate = try await collect(into: candidate, operation: operation)
            guard operation == generation else { return }
            stagedImport = StagedHealthImport(snapshot: candidate, preparedAt: now())
        } catch is CancellationError {
            // Cancelling the preview never writes data or advances persisted anchors.
        } catch { if operation == generation { errorKey = errorMessage(for: error) } }
    }

    func confirmImport() {
        guard !isWorking, !storageNeedsRecovery, var candidate = stagedImport?.snapshot else { return }
        do {
            candidate.isConnected = true
            candidate.closedNutritionDays = snapshot.closedNutritionDays
            candidate.pendingChatContexts = snapshot.pendingChatContexts
            try persistence.save(candidate)
            snapshot = candidate
            stagedImport = nil
            errorKey = nil
        } catch { errorKey = "Could not save the imported data. Your previous data is unchanged." }
    }

    func discardImport() {
        generation += 1
        stagedImport = nil
        isWorking = false
        readingMetric = nil
    }

    func refreshIfConnected() async {
        guard snapshot.isConnected, !isWorking, !storageNeedsRecovery else { return }
        generation += 1
        let operation = generation
        isWorking = true
        errorKey = nil
        defer { finish(operation) }
        do {
            guard client.isAvailable else { throw HealthOperationError.unavailable }
            let candidate = try await collect(into: snapshot, operation: operation)
            guard operation == generation, snapshot.isConnected else { return }
            try persistence.save(candidate)
            snapshot = candidate
        } catch is CancellationError {
        } catch { if operation == generation { errorKey = errorMessage(for: error) } }
    }

    func disconnect(removeLocalCopy: Bool) {
        generation += 1
        var candidate = snapshot
        candidate.isConnected = false
        if removeLocalCopy {
            candidate = HealthSnapshot()
            candidate.goals = snapshot.goals
        }
        do {
            try persistence.save(candidate)
            snapshot = candidate
            stagedImport = nil
            isWorking = false
            readingMetric = nil
            errorKey = nil
            storageNeedsRecovery = false
        } catch { errorKey = "Could not update the local data. Please try again." }
    }



    func validateRestoredSnapshot(_ value: HealthSnapshot) throws {
        guard value.schemaVersion == 1, value.goals?.isValid != false,
              Set(value.samples.map(\.id)).count == value.samples.count,
              value.samples.count <= 2_000_000, value.dailyValues.count <= 1_000_000,
              value.anchors.keys.allSatisfy({ HealthMetric(rawValue: $0) != nil }),
              value.anchors.values.allSatisfy({ $0.count <= 1_000_000 }) else { throw HealthOperationError.invalidData }
        if let config = value.configuration {
            guard TimeZone(identifier: config.timeZoneIdentifier) != nil, !config.metrics.isEmpty,
                  config.startDate?.timeIntervalSince1970.isFinite != false else { throw HealthOperationError.invalidData }
        } else if value.isConnected || !value.samples.isEmpty || !value.dailyValues.isEmpty { throw HealthOperationError.invalidData }
        for sample in value.samples {
            guard sample.value.isFinite, sample.value >= 0, sample.metric != .weight || sample.value > 0,
                  sample.startDate.timeIntervalSince1970.isFinite, sample.endDate.timeIntervalSince1970.isFinite,
                  sample.startDate <= sample.endDate, value.configuration?.metrics.contains(sample.metric) == true,
                  sample.sourceName.count <= 1000, sample.sourceBundleIdentifier.count <= 1000 else { throw HealthOperationError.invalidData }
        }
        for day in value.dailyValues {
            guard day.metric.isCumulative, day.value.isFinite, day.value >= 0, day.date.timeIntervalSince1970.isFinite,
                  value.configuration?.metrics.contains(day.metric) == true else { throw HealthOperationError.invalidData }
        }
        let closures = value.closedNutritionDays ?? []
        guard closures.count <= 100_000, Set(closures.map(\.id)).count == closures.count else { throw HealthOperationError.invalidData }
        for closure in closures {
            let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = .gmt
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard closure.accountScope == "local" || UUID(uuidString: closure.accountScope) != nil,
                  formatter.date(from: closure.dayID).map({ formatter.string(from: $0) == closure.dayID }) == true,
                  closure.closedAt.timeIntervalSince1970.isFinite, closure.goals?.isValid != false,
                  closure.values.count <= 5, Set(closure.values.map(\.metric)).count == closure.values.count else { throw HealthOperationError.invalidData }
            for day in closure.values {
                guard day.metric.isNutrition, day.value.isFinite, day.value >= 0, day.date.timeIntervalSince1970.isFinite,
                      day.sourceNames.count <= 100, day.sourceNames.allSatisfy({ $0.count <= 1000 }) else { throw HealthOperationError.invalidData }
            }
        }
        let contexts = value.pendingChatContexts ?? [:]
        guard contexts.count <= 1000 else { throw HealthOperationError.invalidData }
        for (key, data) in contexts {
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "local" || UUID(uuidString: String(parts[0])) != nil,
                  UUID(uuidString: String(parts[1])) != nil else { throw HealthOperationError.invalidData }
            try validatePendingContext(data)
        }
    }

    private func validatePendingContext(_ data: Data) throws {
        guard data.count <= 10_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["consent", "purpose", "day", "metrics"]),
              let consent = object["consent"] as? NSNumber, CFGetTypeID(consent) == CFBooleanGetTypeID(), consent.boolValue,
              let purpose = object["purpose"] as? String, ["chat", "weekly_review"].contains(purpose),
              let day = object["day"] as? String,
              let metrics = object["metrics"] as? [String: Any],
              Set(metrics.keys).isSubset(of: Set(["weight_kg", "active_kcal", "steps", "exercise_minutes", "dietary_kcal", "protein_g", "carbohydrates_g", "fat_g"])) else { throw HealthOperationError.invalidData }
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = .gmt
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard formatter.date(from: day).map({ formatter.string(from: $0) == day }) == true else { throw HealthOperationError.invalidData }
        for value in metrics.values {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0 else { throw HealthOperationError.invalidData }
        }
    }



    private func collect(into initial: HealthSnapshot, operation: Int) async throws -> HealthSnapshot {
        guard let configuration = initial.configuration else { throw HealthOperationError.invalidConfiguration }
        var candidate = initial
        var indexed = Dictionary(candidate.samples.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let syncDate = now()
        readCount = 0
        for metric in HealthMetric.allCases where configuration.metrics.contains(metric) {
            readingMetric = metric
            var hasMore = true
            while hasMore {
                try Task.checkCancellation()
                guard operation == generation else { throw CancellationError() }
                let anchor = candidate.anchors[metric.rawValue]
                let delta = try await client.changes(for: metric, start: configuration.startDate, anchor: anchor)
                guard operation == generation else { throw CancellationError() }
                if delta.hasMore && delta.anchor == anchor { throw HealthOperationError.stalledCursor }
                for id in delta.deletedIDs { indexed.removeValue(forKey: id) }
                for sample in delta.samples {
                    guard sample.metric == metric, sample.value.isFinite, sample.value >= 0,
                          sample.startDate <= sample.endDate, metric != .weight || sample.value > 0 else { throw HealthOperationError.invalidData }
                    indexed[sample.id] = sample
                }
                candidate.anchors[metric.rawValue] = delta.anchor
                hasMore = delta.hasMore
                readCount += delta.samples.count
            }
            if metric.isCumulative {
                // Recompute merged totals so deletions and changes to sources/permissions are reflected.
                let earliest = configuration.startDate ?? indexed.values.filter { $0.metric == metric }.map(\.startDate).min() ?? syncDate
                let values = try await client.dailyStatistics(for: metric, start: earliest, end: syncDate, calendar: configuration.calendar)
                guard operation == generation else { throw CancellationError() }
                candidate.dailyValues.removeAll { $0.metric == metric }
                candidate.dailyValues.append(contentsOf: values)
            }
        }
        candidate.samples = indexed.values.sorted { $0.startDate < $1.startDate }
        candidate.lastSyncDate = syncDate
        return candidate
    }

    private func finish(_ operation: Int) {
        if generation == operation { isWorking = false; readingMetric = nil }
    }

    private func errorMessage(for error: Error) -> String {
        if let error = error as? HealthOperationError {
            switch error {
            case .unavailable: return "Apple Health is not available on this device."
            case .invalidConfiguration: return "Choose at least one data type and a valid date range."
            default: break
            }
        }
        return "Could not sync Apple Health. Your saved data is unchanged. Check access in Health and try again."
    }
}

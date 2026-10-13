import Foundation
import Observation

@MainActor @Observable final class NutritionStore {
    private(set) var snapshot = NutritionSnapshot()
    private(set) var errorKey: String?
    private(set) var storageNeedsRecovery = false
    private(set) var ownerID: String?
    private(set) var isRefreshing = false
    private var refreshID: UUID?
    @ObservationIgnored private let persistence: any NutritionPersistence

    init(persistence: (any NutritionPersistence)? = nil) {
        self.persistence = persistence ?? NutritionFileRepository()
        reload()
    }
    func reload() {
        do { snapshot = try persistence.load(); try NutritionBackup.validate(snapshot); storageNeedsRecovery = false; errorKey = nil }
        catch { storageNeedsRecovery = true; errorKey = "Could not read your nutrition history. The saved file was preserved." }
    }
    func selectAccount(_ owner: String?) {
        guard ownerID != owner else { return }
        ownerID = owner; refreshID = nil; isRefreshing = false
        snapshot = NutritionSnapshot(); errorKey = nil; storageNeedsRecovery = false
        guard let owner, let id = UUID(uuidString: owner) else { return }
        let url = BackendDiary.cacheURL(owner: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { snapshot = try NutritionBackup.decode(Data(contentsOf: url), datesISO8601: false) }
        catch { errorKey = "Could not read your nutrition history. The saved file was preserved." }
    }
    func refresh(account: AccountSession) async {
        selectAccount(account.session?.user_id)
        guard let owner = ownerID, let id = UUID(uuidString: owner), !isRefreshing else { return }
        let attempt = UUID(); refreshID = attempt; isRefreshing = true
        defer { if refreshID == attempt { isRefreshing = false; refreshID = nil } }
        do {
            let data = try await account.fetchDiary()
            try Task.checkCancellation()
            let incoming = try BackendDiary.decode(data)
            guard account.session?.user_id == owner, ownerID == owner, refreshID == attempt else { return }
            let url = BackendDiary.cacheURL(owner: id)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var folder = url.deletingLastPathComponent()
            var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
            try folder.setResourceValues(attributes)
            try JSONEncoder().encode(incoming).write(to: url, options: [.atomic, .completeFileProtection])
            snapshot = incoming; errorKey = nil; storageNeedsRecovery = false
        } catch is CancellationError { }
        catch {
            guard ownerID == owner, refreshID == attempt else { return }
            if account.session == nil { selectAccount(nil) }
            else { errorKey = "Could not refresh your diary. Showing the last downloaded history." }
        }
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
}

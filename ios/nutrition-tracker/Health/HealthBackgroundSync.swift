import Foundation
import HealthKit
import UIKit
import OSLog
import BackgroundTasks

/// Only types with an explicitly enabled sync direction are observed.
enum BackgroundHealthType: Hashable {
    case weight, waist
    var sampleType: HKQuantityType {
        HKObjectType.quantityType(forIdentifier: self == .weight ? .bodyMass : .waistCircumference)!
    }
}

@MainActor protocol HealthObservationDriver: AnyObject {
    func observe(_ type: BackgroundHealthType, changed: @escaping (@escaping () -> Void) -> Void)
    func stop(_ type: BackgroundHealthType)
}

@MainActor final class HealthKitObservationDriver: HealthObservationDriver {
    private let store = HKHealthStore()
    private let logger = Logger(subsystem: "com.pedrozunino.bocado", category: "HealthBackgroundSync")
    private var queries: [BackgroundHealthType: HKObserverQuery] = [:]

    func observe(_ type: BackgroundHealthType, changed: @escaping (@escaping () -> Void) -> Void) {
        guard HKHealthStore.isHealthDataAvailable(), queries[type] == nil else { return }
        let query = HKObserverQuery(sampleType: type.sampleType, predicate: nil) { _, completion, error in
            guard error == nil else { completion(); return }
            Task { @MainActor in changed(completion) }
        }
        queries[type] = query
        store.execute(query)
        let logger = logger
        store.enableBackgroundDelivery(for: type.sampleType, frequency: .immediate) { success, error in
            if !success {
                logger.error("Health background delivery registration failed (code: \((error as NSError?)?.code ?? 0))")
            }
        }
    }

    func stop(_ type: BackgroundHealthType) {
        if let query = queries.removeValue(forKey: type) { store.stop(query) }
        store.disableBackgroundDelivery(for: type.sampleType) { _, _ in }
    }
}

/// Serializes observer deliveries. Each delivery is acknowledged after its own pass,
/// including on cancellation. Changes arriving during an upload get another pass.
@MainActor final class HealthBackgroundSync {
    private let driver: any HealthObservationDriver
    private let synchronize: (Set<BackgroundHealthType>) async -> Void
    private var observed: Set<BackgroundHealthType> = []
    private var pending: [(BackgroundHealthType, () -> Void)] = []
    private var task: Task<Void, Never>?

    init(driver: any HealthObservationDriver, synchronize: @escaping (Set<BackgroundHealthType>) async -> Void) {
        self.driver = driver
        self.synchronize = synchronize
    }

    func configure(_ types: Set<BackgroundHealthType>) {
        for type in observed.subtracting(types) { driver.stop(type) }
        let added = types.subtracting(observed)
        observed = types
        for type in added {
            driver.observe(type) { [weak self] completion in
                guard let self else { completion(); return }
                self.receive(type, completion: completion)
            }
        }
    }

    func receive(_ type: BackgroundHealthType, completion: @escaping () -> Void) {
        guard observed.contains(type) else { completion(); return }
        pending.append((type, completion))
        guard task == nil else { return }
        task = Task { await drain() }
    }

    private func drain() async {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Health sync") { [weak self] in
            Task { @MainActor in self?.task?.cancel() }
        }
        defer {
            let remaining = pending; pending.removeAll()
            remaining.forEach { $0.1() }
            task = nil
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        while !pending.isEmpty && !Task.isCancelled {
            let batch = pending; pending.removeAll()
            let types = Set(batch.map(\.0)).intersection(observed)
            if !types.isEmpty { await synchronize(types) }
            batch.forEach { $0.1() }
        }
    }
}

/// Constructed before SwiftUI's views, so a HealthKit background launch has the
/// same account and persisted anchors as a foreground launch.
@MainActor final class HealthBackgroundRuntime {
    static let shared = HealthBackgroundRuntime()
    static let waistRefreshIdentifier = "com.pedrozunino.bocado.waist-refresh"
    let account = AccountSession()
    let health = HealthSyncModel()
    let weights = HealthWeightUpload()
    let measurements = HealthBodyMeasurementUpload()
    lazy var observer = HealthBackgroundSync(driver: HealthKitObservationDriver()) { [weak self] types in
        _ = await self?.synchronize(types)
    }

    func configure() {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        let owner = account.session?.user_id
        weights.selectAccount(owner)
        measurements.selectAccount(owner)
        var types: Set<BackgroundHealthType> = []
        if owner != nil {
            if weights.isEnabled && health.snapshot.isConnected && health.snapshot.configuration?.metrics.contains(.weight) == true {
                types.insert(.weight)
            }
        }
        observer.configure(types)
        scheduleWaistRefresh()
    }

    private func synchronize(_ types: Set<BackgroundHealthType>) async -> Bool {
        guard UIApplication.shared.isProtectedDataAvailable else { return false }
        configure()
        // A foreground upload can already be in flight when HealthKit calls us.
        // Wait for it instead of silently acknowledging a skipped upload.
        do {
            while weights.isWorking || measurements.isWorking {
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            if types.contains(.weight) { await weights.sync(account: account, health: health) }
            try Task.checkCancellation()
            // A weight wake-up is also an opportunity to fetch newly recorded
            // Bocado waist measurements, without observing our own Health writes.
            await measurements.sync(account: account)
            return !Task.isCancelled && weights.errorKey == nil && measurements.errorKey == nil
        } catch { return false }
    }

    func registerWaistRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.waistRefreshIdentifier, using: .main) { task in
            Task { @MainActor in
                guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
                let work = Task { @MainActor in
                    let success = await self.synchronize([.weight, .waist])
                    self.scheduleWaistRefresh()
                    refresh.setTaskCompleted(success: success)
                }
                refresh.expirationHandler = { work.cancel() }
            }
        }
    }

    private func scheduleWaistRefresh() {
        guard account.session != nil, measurements.isEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.waistRefreshIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.waistRefreshIdentifier)
        // An earliest date, never an exact interval or delivery guarantee.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch {
            Logger(subsystem: "com.pedrozunino.bocado", category: "HealthBackgroundSync")
                .error("Waist refresh scheduling failed (code: \((error as NSError).code))")
        }
    }

    func retryAfterUnlock() {
        // Reload if a background launch happened while protected files were locked.
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        if account.session == nil { account.restoreSessionIfNeeded() }
        health.reload()
        weights.selectAccount(account.session?.user_id, reload: true)
        measurements.selectAccount(account.session?.user_id, reload: true)
        configure()
        observer.receive(.weight, completion: {})
        Task { _ = await synchronize([.waist]) }
    }
}

@MainActor final class HealthBackgroundAppDelegate: NSObject, UIApplicationDelegate {
    private var isTesting: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing") }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !isTesting {
            let runtime = HealthBackgroundRuntime.shared
            runtime.registerWaistRefresh()
            if application.isProtectedDataAvailable { runtime.configure() }
            else { runtime.observer.configure([.weight]) }
        }
        return true
    }
    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        if !isTesting { HealthBackgroundRuntime.shared.retryAfterUnlock() }
    }
}

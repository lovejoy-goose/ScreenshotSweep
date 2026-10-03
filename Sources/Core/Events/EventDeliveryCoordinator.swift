import Combine
import Foundation

/// Waits between retries. Injectable so tests never really sleep.
protocol DeliverySleeper: Sendable {
    func sleep(seconds: Double) async throws
}

struct TaskSleeper: DeliverySleeper {
    func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }
}

/// Exponential backoff with jitter, capped, within the current app lifecycle only.
struct RetryPolicy: Equatable, Sendable {
    var baseDelay: Double = 2
    var maxDelay: Double = 60
    /// ±fraction of the delay, driven by `random` in 0..<1 (0.5 → no jitter).
    var jitterFraction: Double = 0.2
    /// Network attempts per flush before waiting for the next trigger.
    var maxAttemptsPerFlush = 5

    static let `default` = RetryPolicy()

    /// Delay before retry number `attempt` (1-based).
    func delay(forAttempt attempt: Int, random: Double) -> Double {
        let exponential = min(maxDelay, baseDelay * pow(2, Double(max(attempt, 1) - 1)))
        let jittered = exponential * (1 + jitterFraction * (2 * random - 1))
        return min(maxDelay, max(0, jittered))
    }
}

/// Last successful sync time, kept locally. Not a secret.
protocol SyncStateStoring: AnyObject {
    var lastSuccessfulSync: Date? { get set }
}

final class UserDefaultsSyncStateStore: SyncStateStoring {
    private let defaults: UserDefaults
    private let key = "connector.lastSuccessfulSyncAt"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastSuccessfulSync: Date? {
        get { defaults.object(forKey: key) as? Date }
        set { defaults.set(newValue, forKey: key) }
    }
}

/// Delivers queued events and capability reports. No background tasks: flushes run on
/// launch, on return to foreground, after a new event and on manual sync. Only one flush
/// runs at a time; cancelling it never removes events.
@MainActor
final class EventDeliveryCoordinator: ObservableObject {
    enum Failure: Equatable {
        case offline
        case rateLimited
        case serverError
        case rejected
        case invalidResponse
        case storage
    }

    enum SyncStatus: Equatable {
        case idle
        case syncing
        case waitingToRetry
        /// Katana answered 401: no more network attempts until the user pairs again.
        case requiresRepair
        case failed(Failure)
    }

    enum ConnectionCheckResult: Equatable {
        case ok(serverTime: Date, accountLabel: String?)
        case notPaired
        case requiresRepair
        case failed(Failure)
    }

    enum QueueIssue: Equatable {
        /// The queue file was unreadable; it was kept for diagnostics and the queue restarted.
        case corruptedStoreQuarantined
    }

    @Published private(set) var status: SyncStatus = .idle
    /// Events of the current connection.
    @Published private(set) var pendingCount = 0
    /// Events recorded for another connection or migrated without one. Never sent automatically.
    @Published private(set) var otherScopePendingCount = 0
    @Published private(set) var rejectedCount = 0
    @Published private(set) var lastSuccessfulSync: Date?
    @Published private(set) var lastCheck: ConnectionCheckResult?
    @Published private(set) var isCheckingConnection = false
    @Published private(set) var queueIssue: QueueIssue?
    @Published private(set) var isFlushing = false
    /// Events acknowledged (accepted/duplicate) or rejected during this app run. Internal only.
    @Published private(set) var deliveredEventIDs: Set<UUID> = []
    @Published private(set) var rejectedEventIDs: Set<UUID> = []

    /// Called once per 401 so pairing can flag the credentials.
    var onUnauthorized: (@MainActor () -> Void)?

    private let api: any ConnectorAPI
    private let queue: EventQueue
    private let registry: CapabilityRegistry
    private let syncState: any SyncStateStoring
    private let retryPolicy: RetryPolicy
    private let sleeper: any DeliverySleeper
    private let random: () -> Double
    private let now: () -> Date

    private var flushTask: Task<Void, Never>?
    private var flushRequestedAgain = false
    private var didReportCapabilities = false
    private var capabilityReportTask: Task<Void, Never>?

    init(api: any ConnectorAPI,
         queue: EventQueue,
         registry: CapabilityRegistry,
         syncState: any SyncStateStoring,
         retryPolicy: RetryPolicy = .default,
         sleeper: any DeliverySleeper = TaskSleeper(),
         random: @escaping () -> Double = { Double.random(in: 0..<1) },
         now: @escaping () -> Date = { Date() }) {
        self.api = api
        self.queue = queue
        self.registry = registry
        self.syncState = syncState
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
        self.random = random
        self.now = now
        lastSuccessfulSync = syncState.lastSuccessfulSync
    }

    // MARK: Lifecycle triggers

    /// Opens the queue and loads counters. Reports a quarantined queue file once.
    func prepare() async {
        do {
            try await queue.open()
        } catch {
            handleQueueError(error)
        }
        await refreshCounts()
    }

    /// App launch or return to foreground: one automatic capability report per launch, then flush.
    func appBecameActive() {
        guard status != .requiresRepair else { return }
        if !didReportCapabilities && capabilityReportTask == nil {
            capabilityReportTask = Task { [weak self] in
                await self?.reportCapabilities()
                self?.capabilityReportTask = nil
            }
        }
        requestFlush()
    }

    /// A new connection was confirmed: forget a previous 401 and deliver what is queued.
    func pairingDidConnect() {
        if status == .requiresRepair { status = .idle }
        lastCheck = nil
        didReportCapabilities = false
        Task { await refreshCounts() }
        appBecameActive()
    }

    /// Persists the event for the current connection first, then tries to deliver it.
    /// Throws `ConnectorAPIError.notPaired` when there is no connection to attach it to.
    func enqueue(_ event: ConnectorEvent) async throws {
        guard let scope = api.currentScope() else { throw ConnectorAPIError.notPaired }
        do {
            try await queue.enqueue(event, scope: scope)
        } catch {
            handleQueueError(error)
            throw error
        }
        await refreshCounts()
        requestFlush()
    }

    /// Manual «Синхронизировать»: capability report, then events.
    func synchronize() async {
        guard status != .requiresRepair else { return }
        await reportCapabilities()
        requestFlush()
        await waitForFlush()
    }

    // MARK: Connection check

    func checkConnection() async {
        guard !isCheckingConnection else { return }
        isCheckingConnection = true
        defer { isCheckingConnection = false }
        do {
            let response = try await api.checkConnection()
            lastCheck = .ok(serverTime: response.serverTime, accountLabel: response.accountLabel)
            if status == .requiresRepair { status = .idle }
        } catch let error as ConnectorAPIError {
            switch error {
            case .unauthorized:
                lastCheck = .requiresRepair
                enterRequiresRepair()
            case .notPaired, .credentialsUnavailable:
                lastCheck = .notPaired
            default:
                lastCheck = .failed(Self.failure(for: error))
            }
        } catch {
            lastCheck = .failed(.invalidResponse)
        }
    }

    // MARK: Capability report

    @discardableResult
    func reportCapabilities() async -> Bool {
        do {
            try await api.reportCapabilities(registry.snapshots())
            didReportCapabilities = true
            markSynced()
            return true
        } catch ConnectorAPIError.unauthorized {
            enterRequiresRepair()
        } catch {
            // Not paired or temporarily unavailable: retried on the next trigger.
        }
        return false
    }

    // MARK: Flush

    /// Starts a flush unless one is running; a running flush re-checks the queue once more.
    func requestFlush() {
        if flushTask != nil {
            flushRequestedAgain = true
            return
        }
        isFlushing = true
        flushTask = Task { [weak self] in
            await self?.runFlushes()
        }
    }

    func waitForFlush() async {
        await flushTask?.value
    }

    /// Stops the current flush. Events stay queued.
    func cancelFlush() {
        flushTask?.cancel()
    }

    private func runFlushes() async {
        repeat {
            flushRequestedAgain = false
            await flushOnce()
        } while flushRequestedAgain && !Task.isCancelled && status != .requiresRepair
        flushTask = nil
        isFlushing = false
    }

    private func flushOnce() async {
        // After a 401 nothing is sent until the user pairs again.
        guard status != .requiresRepair else { return }
        // Only events of the current connection are ever sent.
        guard let scope = api.currentScope() else {
            status = .idle
            return
        }
        var attempt = 0
        while !Task.isCancelled {
            let batch: [ConnectorEvent]
            do {
                batch = try await queue.nextBatch(scope: scope)
            } catch {
                handleQueueError(error)
                status = .failed(.storage)
                return
            }
            guard !batch.isEmpty else {
                if status != .requiresRepair { status = .idle }
                return
            }

            status = .syncing
            do {
                let results = try await api.sendEventBatch(batch, scope: scope)
                let removed = try await queue.apply(results, at: now())
                recordOutcomes(results)
                markSynced()
                await refreshCounts()
                attempt = 0
                // Katana answered but acknowledged none of the events: try again on the next trigger.
                if removed == 0 {
                    status = .idle
                    return
                }
            } catch let error as ConnectorAPIError {
                switch error {
                case .unauthorized:
                    enterRequiresRepair()
                    return
                case .notPaired, .credentialsUnavailable, .scopeMismatch:
                    status = .idle
                    return
                case .transport, .rateLimited, .serverError:
                    attempt += 1
                    guard attempt < retryPolicy.maxAttemptsPerFlush else {
                        status = .failed(Self.failure(for: error))
                        return
                    }
                    status = .waitingToRetry
                    do {
                        try await sleeper.sleep(seconds: retryPolicy.delay(forAttempt: attempt, random: random()))
                    } catch {
                        status = .idle
                        return
                    }
                case .rejected, .invalidResponse, .insecureHost:
                    status = .failed(Self.failure(for: error))
                    return
                }
            } catch let error as EventQueueError {
                handleQueueError(error)
                status = .failed(.storage)
                return
            } catch {
                status = Task.isCancelled ? .idle : .failed(.invalidResponse)
                return
            }
        }
        if status != .requiresRepair { status = .idle }
    }

    // MARK: Helpers

    private func enterRequiresRepair() {
        guard status != .requiresRepair else { return }
        status = .requiresRepair
        onUnauthorized?()
    }

    private func markSynced() {
        let date = now()
        lastSuccessfulSync = date
        syncState.lastSuccessfulSync = date
    }

    private func recordOutcomes(_ results: [UUID: EventDeliveryResult]) {
        for (id, result) in results {
            if result.status == .rejected {
                rejectedEventIDs.insert(id)
            } else {
                deliveredEventIDs.insert(id)
            }
        }
    }

    private func refreshCounts() async {
        let scope = api.currentScope()
        if let scope, let count = try? await queue.pendingCount(scope: scope) {
            pendingCount = count
        } else if scope == nil {
            pendingCount = 0
        }
        if let other = try? await queue.otherPendingCount(excluding: scope) { otherScopePendingCount = other }
        if let records = try? await queue.rejectedRecords() { rejectedCount = records.count }
    }

    private func handleQueueError(_ error: Error) {
        if case .corruptedStore? = error as? EventQueueError {
            queueIssue = .corruptedStoreQuarantined
        }
    }

    private static func failure(for error: ConnectorAPIError) -> Failure {
        switch error {
        case .transport, .notPaired, .credentialsUnavailable: return .offline
        case .rateLimited: return .rateLimited
        case .serverError: return .serverError
        case .rejected, .unauthorized, .insecureHost: return .rejected
        case .invalidResponse, .scopeMismatch: return .invalidResponse
        }
    }
}

extension EventDeliveryCoordinator: CleanupEventSink {
    func enqueueCleanupEvent(_ event: ConnectorEvent) async -> CleanupEnqueueOutcome {
        do {
            try await enqueue(event)
            return .saved
        } catch ConnectorAPIError.notPaired {
            return .notPaired
        } catch {
            return .failed
        }
    }
}

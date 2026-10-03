import Foundation

struct EventQueueLimits: Equatable, Sendable {
    /// Events per `events/batch` request.
    var maxBatchSize = 20
    /// Pending events of all scopes (including legacy); further enqueues fail instead of
    /// dropping older events.
    var maxEvents = 500
    /// Encoded size of a single event.
    var maxEventBytes = 16 * 1024
    /// Rejected-event records kept (oldest dropped first).
    var maxRejectedRecords = 100

    static let `default` = EventQueueLimits()
}

/// Persistent, connection-scoped FIFO of events awaiting delivery. Serialized by the
/// actor; every change is written to disk before it becomes visible.
actor EventQueue {
    enum EnqueueResult: Equatable, Sendable {
        case enqueued
        case alreadyQueued
    }

    let limits: EventQueueLimits
    private let store: EventQueueStore
    private var file: EventQueueFile?

    init(store: EventQueueStore, limits: EventQueueLimits = .default) {
        self.store = store
        self.limits = limits
    }

    /// Loads (and if needed migrates) the file. Throws `corruptedStore` once if it had to be quarantined.
    func open() throws {
        _ = try loaded()
    }

    /// Adds an event for `scope`. An `event_id` already present in any scope (or legacy) is a no-op.
    @discardableResult
    func enqueue(_ event: ConnectorEvent, scope: ConnectionScope) throws -> EnqueueResult {
        var current = try loaded()
        if Self.contains(event.eventID, in: current) { return .alreadyQueued }
        guard event.hasValidType else { throw EventQueueError.invalidEvent }
        guard let encoded = try? ConnectorJSON.makeEncoder().encode(event) else { throw EventQueueError.invalidEvent }
        guard encoded.count <= limits.maxEventBytes else { throw EventQueueError.eventTooLarge }
        guard current.events.count + current.legacyEvents.count < limits.maxEvents else { throw EventQueueError.queueFull }
        current.events.append(QueuedEvent(scope: scope, event: event))
        try persist(current)
        return .enqueued
    }

    /// Oldest events of `scope` first, at most `maxBatchSize`. Other scopes and legacy events are never returned.
    func nextBatch(scope: ConnectionScope, limit: Int? = nil) throws -> [ConnectorEvent] {
        let size = max(min(limit ?? limits.maxBatchSize, limits.maxBatchSize), 0)
        return Array(try loaded().events.lazy.filter { $0.scope == scope }.map(\.event).prefix(size))
    }

    func pendingEvents(scope: ConnectionScope) throws -> [ConnectorEvent] {
        try loaded().events.filter { $0.scope == scope }.map(\.event)
    }

    func pendingEntries() throws -> [QueuedEvent] {
        try loaded().events
    }

    func legacyEvents() throws -> [ConnectorEvent] {
        try loaded().legacyEvents
    }

    /// All pending events, any scope, including legacy.
    func pendingCount() throws -> Int {
        let current = try loaded()
        return current.events.count + current.legacyEvents.count
    }

    func pendingCount(scope: ConnectionScope) throws -> Int {
        try loaded().events.filter { $0.scope == scope }.count
    }

    /// Events waiting for another connection, plus legacy events. With no current scope, all of them.
    func otherPendingCount(excluding scope: ConnectionScope?) throws -> Int {
        let current = try loaded()
        return current.events.filter { $0.scope != scope }.count + current.legacyEvents.count
    }

    func contains(eventID: UUID) throws -> Bool {
        Self.contains(eventID, in: try loaded())
    }

    func rejectedRecords() throws -> [RejectedEventRecord] {
        try loaded().rejected
    }

    /// Removes accepted and duplicate events; rejected events leave the active queue and
    /// keep only metadata. Events without a result stay. Legacy events are never touched.
    /// Returns how many were removed.
    @discardableResult
    func apply(_ results: [UUID: EventDeliveryResult], at date: Date) throws -> Int {
        var current = try loaded()
        var removed = 0
        var remaining: [QueuedEvent] = []
        for entry in current.events {
            guard let result = results[entry.event.eventID] else {
                remaining.append(entry)
                continue
            }
            removed += 1
            if result.status == .rejected {
                current.rejected.append(RejectedEventRecord(eventID: entry.event.eventID, type: entry.event.type,
                                                            code: result.code.map { String($0.prefix(RejectedEventRecord.maxCodeLength)) },
                                                            rejectedAt: date))
            }
        }
        guard removed > 0 else { return 0 }
        current.events = remaining
        if current.rejected.count > limits.maxRejectedRecords {
            current.rejected.removeFirst(current.rejected.count - limits.maxRejectedRecords)
        }
        try persist(current)
        return removed
    }

    private static func contains(_ eventID: UUID, in file: EventQueueFile) -> Bool {
        file.events.contains { $0.event.eventID == eventID } || file.legacyEvents.contains { $0.eventID == eventID }
    }

    private func loaded() throws -> EventQueueFile {
        if let file { return file }
        do {
            let loadedFile = try store.load()
            file = loadedFile
            return loadedFile
        } catch let error as EventQueueError {
            if case .corruptedStore = error {
                // The original file is preserved under a quarantine name; continue empty.
                file = EventQueueFile()
            }
            throw error
        }
    }

    private func persist(_ newFile: EventQueueFile) throws {
        try store.save(newFile)
        file = newFile
    }
}

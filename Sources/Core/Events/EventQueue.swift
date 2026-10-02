import Foundation

struct EventQueueLimits: Equatable, Sendable {
    /// Events per `events/batch` request.
    var maxBatchSize = 20
    /// Pending events; further enqueues fail instead of dropping older events.
    var maxEvents = 500
    /// Encoded size of a single event.
    var maxEventBytes = 16 * 1024
    /// Rejected-event records kept (oldest dropped first).
    var maxRejectedRecords = 100

    static let `default` = EventQueueLimits()
}

/// Persistent FIFO of events awaiting delivery. Serialized by the actor; every change
/// is written to disk before it becomes visible.
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

    /// Loads the file. Throws `corruptedStore` once if it had to be quarantined.
    func open() throws {
        _ = try loaded()
    }

    @discardableResult
    func enqueue(_ event: ConnectorEvent) throws -> EnqueueResult {
        var current = try loaded()
        if current.events.contains(where: { $0.eventID == event.eventID }) { return .alreadyQueued }
        guard event.hasValidType else { throw EventQueueError.invalidEvent }
        guard let encoded = try? ConnectorJSON.makeEncoder().encode(event) else { throw EventQueueError.invalidEvent }
        guard encoded.count <= limits.maxEventBytes else { throw EventQueueError.eventTooLarge }
        guard current.events.count < limits.maxEvents else { throw EventQueueError.queueFull }
        current.events.append(event)
        try persist(current)
        return .enqueued
    }

    /// Oldest events first, at most `maxBatchSize`.
    func nextBatch(limit: Int? = nil) throws -> [ConnectorEvent] {
        let size = min(limit ?? limits.maxBatchSize, limits.maxBatchSize)
        return Array(try loaded().events.prefix(max(size, 0)))
    }

    func pendingEvents() throws -> [ConnectorEvent] {
        try loaded().events
    }

    func pendingCount() throws -> Int {
        try loaded().events.count
    }

    func rejectedRecords() throws -> [RejectedEventRecord] {
        try loaded().rejected
    }

    /// Removes accepted and duplicate events; rejected events leave the active queue and
    /// keep only metadata. Events without a result stay. Returns how many were removed.
    @discardableResult
    func apply(_ results: [UUID: EventDeliveryResult], at date: Date) throws -> Int {
        var current = try loaded()
        var removed = 0
        var remaining: [ConnectorEvent] = []
        for event in current.events {
            guard let result = results[event.eventID] else {
                remaining.append(event)
                continue
            }
            removed += 1
            if result.status == .rejected {
                current.rejected.append(RejectedEventRecord(eventID: event.eventID, type: event.type,
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

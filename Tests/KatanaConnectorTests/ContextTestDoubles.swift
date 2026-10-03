import XCTest

// MARK: - Shared v0.2 doubles (no hardware, no real permission prompts, no network)

/// Settable clock for coordinators that take `now`.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Fixtures.pairedAt) { current = start }

    var date: Date {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    func now() -> Date { date }
}

/// Records events instead of queueing them; outcome is scriptable.
@MainActor
final class RecordingEventSink: ConnectorEventSink {
    var outcome: EventEnqueueOutcome = .saved
    private(set) var events: [ConnectorEvent] = []
    private(set) var attempts: [ConnectorEvent] = []
    private(set) var unauthorizedReports = 0
    var states: [UUID: EventLocalDeliveryState] = [:]

    func enqueueEvent(_ event: ConnectorEvent) async -> EventEnqueueOutcome {
        attempts.append(event)
        if outcome == .saved, !events.contains(where: { $0.eventID == event.eventID }) { events.append(event) }
        return outcome
    }

    func localDeliveryState(of eventID: UUID) async -> EventLocalDeliveryState {
        states[eventID] ?? .pending
    }

    func reportUnauthorized() {
        unauthorizedReports += 1
    }
}

enum ContextFixtures {
    static func temporaryDirectory(_ name: String = "Context") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    static func json(_ event: ConnectorEvent) throws -> [String: Any] {
        let data = try ConnectorJSON.makeEncoder().encode(event)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func payload(_ event: ConnectorEvent) throws -> [String: Any] {
        try XCTUnwrap(json(event)["payload"] as? [String: Any])
    }

    static func text(_ event: ConnectorEvent) throws -> String {
        String(decoding: try ConnectorJSON.makeEncoder().encode(event), as: UTF8.self)
    }

    /// Real queue + delivery coordinator over a mocked API, for offline/relaunch/scope tests.
    @MainActor
    static func delivery(queueDirectory: URL, api: MockConnectorAPI, attempts: Int = 1) -> (EventQueue, EventDeliveryCoordinator) {
        let queue = EventQueue(store: EventQueueStore(directoryURL: queueDirectory))
        let delivery = EventDeliveryCoordinator(api: api, queue: queue, registry: CapabilityRegistry(),
                                                syncState: InMemorySyncStateStore(),
                                                retryPolicy: RetryPolicy(baseDelay: 1, maxDelay: 1, jitterFraction: 0,
                                                                         maxAttemptsPerFlush: attempts),
                                                sleeper: RecordingSleeper(), random: { 0.5 }, now: { Fixtures.pairedAt })
        return (queue, delivery)
    }
}

// MARK: - Activity

final class MockActivitySystem: ActivitySystem, @unchecked Sendable {
    private let lock = NSLock()
    let log = CallLog()
    var available = true
    var status: MotionPermission = .authorized
    /// Status after the prompt.
    var statusAfterRequest: MotionPermission = .authorized
    var reading = MotionActivityReading(walking: true, confidence: .high)
    var readingError: CapabilityProbeError?
    var hangsOnReading = false
    private var handler: (@Sendable (MotionActivityReading) -> Void)?

    func isActivityAvailable() async -> Bool { log.hit("available"); return available }

    func permission() async -> MotionPermission {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    func requestAuthorization() async -> MotionPermission {
        log.hit("request")
        lock.lock(); defer { lock.unlock() }
        status = statusAfterRequest
        return status
    }

    func currentReading() async throws -> MotionActivityReading {
        log.hit("reading")
        if hangsOnReading { try await Task.sleep(nanoseconds: 60_000_000_000) }
        if let readingError { throw readingError }
        return reading
    }

    func startUpdates(_ handler: @escaping @Sendable (MotionActivityReading) -> Void) async {
        log.hit("start")
        log.setActive("updates", true)
        lock.lock(); self.handler = handler; lock.unlock()
    }

    func stopUpdates() async {
        log.hit("stop")
        log.setActive("updates", false)
        lock.lock(); handler = nil; lock.unlock()
    }

    /// Delivers a reading as Core Motion would (only while updates run).
    func emit(_ reading: MotionActivityReading) {
        lock.lock(); let current = handler; lock.unlock()
        current?(reading)
    }

    var isUpdating: Bool { log.isActive("updates") }
}

/// Returns at once, so the timeout side of a race wins against a hanging system call.
struct ImmediateSleeper: DeliverySleeper {
    func sleep(seconds: Double) async throws {}
}

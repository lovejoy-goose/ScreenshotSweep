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

// MARK: - Location Check-in

final class MockCheckInLocationSystem: CheckInLocationSystem, @unchecked Sendable {
    private let lock = NSLock()
    let log = CallLog()
    var servicesOn = true
    var status: LocationPermission = .authorizedWhenInUse
    var statusAfterRequest: LocationPermission = .authorizedWhenInUse
    /// Fixed test coordinates (central Moscow); never real user data.
    var fix = LocationFix(latitude: 55.755814, longitude: 37.617635, horizontalAccuracy: 42)
    var fixError: CapabilityProbeError?
    var hangsOnFix = false

    func servicesEnabled() async -> Bool { log.hit("services"); return servicesOn }

    func permission() async -> LocationPermission {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    func requestWhenInUseAuthorization() async -> LocationPermission {
        log.hit("requestWhenInUse")
        lock.lock(); defer { lock.unlock() }
        status = statusAfterRequest
        return status
    }

    func currentFix() async throws -> LocationFix {
        log.hit("fix")
        if hangsOnFix { try await Task.sleep(nanoseconds: 60_000_000_000) }
        if let fixError { throw fixError }
        return fix
    }
}

// MARK: - Reminders

final class MockReminderDraftFetcher: ReminderDraftFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _requested: [UUID] = []
    var result: Result<ReminderDraft, ReminderDraftError>

    init(result: Result<ReminderDraft, ReminderDraftError>) {
        self.result = result
    }

    var requested: [UUID] { lock.lock(); defer { lock.unlock() }; return _requested }

    func fetchReminderDraft(id: UUID) async throws -> ReminderDraft {
        lock.lock(); _requested.append(id); lock.unlock()
        return try result.get()
    }
}

final class MockReminderNotifications: ReminderNotificationSystem, @unchecked Sendable {
    private let lock = NSLock()
    let log = CallLog()
    var status: NotificationPermission = .authorized
    var statusAfterRequest: NotificationPermission = .authorized
    var scheduleError: Error?
    private var _pending: [String: ReminderNotificationRequest] = [:]
    /// Notifications of other parts of the app (must never be touched).
    private var _foreign: Set<String> = ["app.katana.connector.capability-lab.test.0001", "other.app.notification"]

    var pending: [String: ReminderNotificationRequest] { lock.lock(); defer { lock.unlock() }; return _pending }
    var foreign: Set<String> { lock.lock(); defer { lock.unlock() }; return _foreign }

    func permission() async -> NotificationPermission {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    func requestAuthorization() async -> NotificationPermission {
        log.hit("request")
        lock.lock(); defer { lock.unlock() }
        status = statusAfterRequest
        return status
    }

    func schedule(_ request: ReminderNotificationRequest) async throws {
        log.hit("schedule")
        if let scheduleError { throw scheduleError }
        lock.lock(); _pending[request.identifier] = request; lock.unlock()
    }

    func removePending(identifier: String) async {
        log.hit("remove")
        lock.lock(); _pending[identifier] = nil; _foreign.remove(identifier); lock.unlock()
    }
}

enum ReminderFixtures {
    static let draftID = UUID(uuidString: "6F1C2D3E-4B5A-4C6D-8E7F-90A1B2C3D4E5")!
    static let title = "Позвонить в сервис"
    static let body = "Уточнить время записи"

    static func draft(fireIn: TimeInterval = 3600, expiresIn: TimeInterval = 600) -> ReminderDraft {
        ReminderDraft(draftID: draftID, title: title, body: body,
                      fireAt: Fixtures.pairedAt.addingTimeInterval(fireIn),
                      expiresAt: Fixtures.pairedAt.addingTimeInterval(expiresIn))
    }

    static func responseJSON(id: String = "6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5", title: String = ReminderFixtures.title,
                             body: String? = ReminderFixtures.body, fireAt: String = "2026-09-21T15:13:20Z",
                             expiresAt: String = "2026-09-21T14:23:20Z") -> String {
        let encodedTitle = String(decoding: try! JSONEncoder().encode(title), as: UTF8.self)
        let encodedBody = body.map { String(decoding: try! JSONEncoder().encode($0), as: UTF8.self) } ?? "null"
        return #"{"draft_id":"\#(id)","title":\#(encodedTitle),"body":\#(encodedBody),"fire_at":"\#(fireAt)","expires_at":"\#(expiresAt)"}"#
    }
}

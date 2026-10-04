import CoreMotion

/// Activity Journal adapter. Each `CMMotionActivity` is reduced here to six flags and a
/// confidence; its timestamp and the activity history are never read, stored, logged or sent.
final class SystemActivityAccess: ActivitySystem, @unchecked Sendable {
    private let manager = CMMotionActivityManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.katana.connector.activity-journal"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    func isActivityAvailable() async -> Bool {
        CMMotionActivityManager.isActivityAvailable()
    }

    func permission() async -> MotionPermission {
        Self.map(CMMotionActivityManager.authorizationStatus())
    }

    /// iOS shows the Motion & Fitness prompt on the first activity request; a one-minute
    /// query is that user-initiated request. Its result is ignored.
    func requestAuthorization() async -> MotionPermission {
        let wait = ProbeOneShot()
        let end = Date()
        manager.queryActivityStarting(from: end.addingTimeInterval(-60), to: end, to: queue) { _, _ in
            wait.resolve(.success(()))
        }
        try? await wait.wait()
        return Self.map(CMMotionActivityManager.authorizationStatus())
    }

    func currentReading() async throws -> MotionActivityReading {
        let wait = ProbeOneShot()
        let box = ReadingBox()
        let manager = manager
        defer { manager.stopActivityUpdates() }
        manager.startActivityUpdates(to: queue) { activity in
            manager.stopActivityUpdates()
            if let activity { box.value = Self.reading(from: activity) }
            wait.resolve(.success(()))
        }
        try await wait.wait()
        guard let reading = box.value else { throw CapabilityProbeError.systemError }
        return reading
    }

    func startUpdates(_ handler: @escaping @Sendable (MotionActivityReading) -> Void) async {
        manager.startActivityUpdates(to: queue) { activity in
            guard let activity else { return }
            handler(Self.reading(from: activity))
        }
    }

    func stopUpdates() async {
        manager.stopActivityUpdates()
    }

    private static func reading(from activity: CMMotionActivity) -> MotionActivityReading {
        let confidence: ActivityConfidence
        switch activity.confidence {
        case .high: confidence = .high
        case .medium: confidence = .medium
        default: confidence = .low
        }
        return MotionActivityReading(stationary: activity.stationary, walking: activity.walking, running: activity.running,
                                     cycling: activity.cycling, automotive: activity.automotive, unknown: activity.unknown,
                                     confidence: confidence)
    }

    private static func map(_ status: CMAuthorizationStatus) -> MotionPermission {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }
}

/// Hands one reading from the Core Motion queue to the waiting task.
private final class ReadingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MotionActivityReading?

    var value: MotionActivityReading? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

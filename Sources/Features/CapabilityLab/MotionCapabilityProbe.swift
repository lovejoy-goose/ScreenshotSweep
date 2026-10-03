import CoreMotion

/// Motion & Fitness adapter. Activity results (type, confidence, timestamps) are never
/// read, stored, shown, logged or sent — only the arrival of a callback counts.
final class SystemMotionAccess: MotionSystem, @unchecked Sendable {
    private let manager = CMMotionActivityManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.katana.connector.capability-lab.motion"
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
    /// history query is that user-initiated request. Its result is ignored.
    func requestAuthorization() async -> MotionPermission {
        let wait = ProbeOneShot()
        let end = Date()
        manager.queryActivityStarting(from: end.addingTimeInterval(-60), to: end, to: queue) { _, _ in
            wait.resolve(.success(()))
        }
        try? await wait.wait()
        return Self.map(CMMotionActivityManager.authorizationStatus())
    }

    func receiveOneSample() async throws {
        let wait = ProbeOneShot()
        let manager = manager
        defer { manager.stopActivityUpdates() }
        manager.startActivityUpdates(to: queue) { _ in
            manager.stopActivityUpdates()
            wait.resolve(.success(()))
        }
        try await wait.wait()
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

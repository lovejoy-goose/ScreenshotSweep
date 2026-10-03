import Combine
import Foundation

/// Runs Capability Lab probes. Each probe starts only from its own button, requests only its
/// own permission, runs at most once at a time, is bounded by a timeout and updates only its
/// own snapshot. Results are saved locally first; then `onSnapshotsChanged` lets the app send
/// a capability report. Probes never create events.
@MainActor
final class CapabilityLabCoordinator: ObservableObject {
    /// The four manual probes, in display order.
    static let labCapabilities: [CapabilityID] = [.camera, .currentLocation, .motion, .localNotifications]

    /// Bumped on every snapshot change so views re-read `snapshot(for:)`.
    @Published private(set) var revision = 0
    @Published private(set) var running: Set<CapabilityID> = []
    @Published private(set) var storageFailed = false

    /// Called after a probe result was saved (e.g. to send a capability report).
    var onSnapshotsChanged: (@MainActor () -> Void)?

    let registry: CapabilityRegistry
    private let store: CapabilitySnapshotStore
    private let probes: [CapabilityID: any CapabilityProbe]
    private let sleeper: any DeliverySleeper
    private let now: () -> Date
    private var tasks: [CapabilityID: Task<Void, Never>] = [:]

    init(store: CapabilitySnapshotStore,
         probes: [any CapabilityProbe],
         sleeper: any DeliverySleeper = TaskSleeper(),
         now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.registry = CapabilityRegistry(provider: store)
        self.probes = Dictionary(probes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.sleeper = sleeper
        self.now = now
    }

    func snapshot(for id: CapabilityID) -> CapabilitySnapshot {
        registry.snapshot(for: id)
    }

    func isRunning(_ id: CapabilityID) -> Bool {
        running.contains(id)
    }

    // MARK: Status refresh (launch / foreground)

    /// Reads availability and authorization of the lab capabilities without any prompt.
    /// Never runs a probe and keeps `probe_state`, `checked_at` and `detail` as they were.
    func refreshAuthorizations() async {
        for id in Self.labCapabilities {
            guard let probe = probes[id], !running.contains(id) else { continue }
            let availability = await probe.availability()
            let authorization = await probe.authorization()
            var snapshot = store.snapshot(for: id)
            guard snapshot.availability != availability || snapshot.authorization != authorization else { continue }
            snapshot.availability = availability
            snapshot.authorization = authorization
            persist(snapshot, notify: false)
        }
    }

    // MARK: Running probes

    /// Starts the probe unless it is already running (a second tap does nothing).
    func start(_ id: CapabilityID) {
        guard tasks[id] == nil, let probe = probes[id] else { return }
        running.insert(id)
        tasks[id] = Task { [weak self] in
            await self?.perform(probe)
            self?.tasks[id] = nil
            self?.running.remove(id)
        }
    }

    func cancel(_ id: CapabilityID) {
        tasks[id]?.cancel()
    }

    func waitForProbe(_ id: CapabilityID) async {
        await tasks[id]?.value
    }

    private func perform(_ probe: any CapabilityProbe) async {
        let availability = await probe.availability()
        var authorization = await probe.authorization()

        guard availability == .available else {
            record(probe.id, availability: availability, authorization: authorization, state: .failed, detail: .unavailable)
            return
        }
        if authorization == .notRequested {
            authorization = await probe.requestAuthorization()
        }

        switch authorization {
        case .denied:
            record(probe.id, availability: availability, authorization: authorization, state: .failed, detail: .permissionDenied)
        case .restricted:
            record(probe.id, availability: availability, authorization: authorization, state: .failed, detail: .permissionRestricted)
        case .unknown, .notRequested:
            record(probe.id, availability: availability, authorization: authorization, state: .failed, detail: .systemError)
        case .granted, .limited, .notRequired:
            let (state, detail) = await runCheck(probe)
            // A denial reported by the system during the check is reflected in authorization too.
            let finalAuthorization: CapabilityAuthorization = detail == .permissionDenied ? .denied : authorization
            record(probe.id, availability: availability, authorization: finalAuthorization, state: state, detail: detail)
        }
    }

    /// Races the check against its timeout. Cancelling either side stops the other.
    private func runCheck(_ probe: any CapabilityProbe) async -> (CapabilityProbeState, CapabilityProbeDetail) {
        let sleeper = self.sleeper
        do {
            let detail = try await withThrowingTaskGroup(of: CapabilityProbeDetail?.self) { group -> CapabilityProbeDetail? in
                group.addTask { try await probe.check() }
                group.addTask {
                    try await sleeper.sleep(seconds: probe.timeout)
                    return nil
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            guard let detail else { return (.failed, .timedOut) }
            return (.passed, detail)
        } catch let error as CapabilityProbeError {
            switch error {
            case .unavailable: return (.failed, .unavailable)
            case .permissionDenied: return (.failed, .permissionDenied)
            case .systemError: return (.failed, .systemError)
            }
        } catch {
            return (.failed, Task.isCancelled || error is CancellationError ? .cancelled : .systemError)
        }
    }

    private func record(_ id: CapabilityID, availability: CapabilityAvailability, authorization: CapabilityAuthorization,
                        state: CapabilityProbeState, detail: CapabilityProbeDetail) {
        let snapshot = CapabilitySnapshot(id: id, availability: availability, authorization: authorization,
                                          probeState: state, checkedAt: now(), detail: detail.rawValue)
        persist(snapshot, notify: true)
    }

    private func persist(_ snapshot: CapabilitySnapshot, notify: Bool) {
        do {
            try store.save(snapshot)
            storageFailed = false
        } catch {
            storageFailed = true
            return
        }
        revision += 1
        if notify { onSnapshotsChanged?() }
    }
}

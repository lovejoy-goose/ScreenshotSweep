import Combine
import Foundation

/// Local geofences (D-049). Created only by the user (or a confirmed action draft): one When In
/// Use fix → preview → confirmation → Always requested only then → system region. Crossings are
/// saved before they are queued and never carry coordinates. No background location updates.
@MainActor
final class GeofenceCoordinator: ObservableObject, ActionDraftHandler {
    enum Failure: Equatable, Sendable {
        case servicesDisabled
        case permissionDenied
        case permissionRestricted
        /// «Всегда» was not granted: nothing is registered (no promise of a background trigger).
        case alwaysRequired
        case monitoringUnavailable
        case limitReached
        case invalidName
        case timedOut
        case systemError
        case storage
    }

    enum Phase: Equatable, Sendable {
        case idle
        case locating
        /// Preview shown; waits for name, radius and the confirmed «Зарегистрировать».
        case preview
        case registering
        case created(UUID)
        case failed(Failure)
    }

    /// Unconfirmed geofence: lives only in memory.
    struct Draft: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        let accuracyBucket: HorizontalAccuracyBucket
    }

    enum StorageIssue: Equatable, Sendable {
        case quarantined
        case writeFailed
    }

    static let fixTimeout: TimeInterval = 20

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var draft: Draft?
    @Published var draftName = "Место"
    @Published var draftRadius = 200
    @Published private(set) var geofences: [GeofenceRecord] = []
    @Published private(set) var systemStates: [UUID: GeofenceSystemState] = [:]
    @Published private(set) var recordFailures: [UUID: Failure] = [:]
    @Published private(set) var storageIssue: StorageIssue?

    weak var sink: (any ConnectorEventSink)?
    /// Foreground or background, for `delivery_context`.
    var isAppActive = true

    private let store: VersionedJSONFileStore<GeofencesFile>
    private let system: any GeofenceSystem
    private let sleeper: any DeliverySleeper
    private let now: () -> Date
    private var pendingTransitions: [GeofencePendingTransition] = []
    private var lastTransitions: [GeofenceLastTransition] = []
    private var pendingRemovals: [GeofencePendingRemoval] = []
    private var isRetryingEvents = false
    private var handlerInstalled = false
    private var saveRequestedAgain = false

    init(store: VersionedJSONFileStore<GeofencesFile>,
         system: any GeofenceSystem,
         sink: (any ConnectorEventSink)? = nil,
         sleeper: any DeliverySleeper = TaskSleeper(),
         now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.system = system
        self.sink = sink
        self.sleeper = sleeper
        self.now = now
        do {
            let file = try store.load()
            geofences = file.geofences
            pendingTransitions = file.pendingTransitions
            lastTransitions = file.lastTransitions
            pendingRemovals = file.pendingRemovals
        } catch VersionedFileStoreError.quarantined(_) {
            storageIssue = .quarantined
        } catch {
            storageIssue = .writeFailed
        }
    }

    // MARK: Launch / foreground

    /// Installs the crossing handler (must happen at launch, also for a background relaunch by
    /// iOS) and reconciles with the system. Requests nothing.
    func start() async {
        if !handlerInstalled {
            handlerInstalled = true
            await system.setTransitionHandler { [weak self] identifier, transition in
                Task { @MainActor in await self?.handleTransition(regionIdentifier: identifier, transition: transition) }
            }
        }
        await reconcile()
    }

    /// Makes the system match the enabled geofences: foreign regions with our prefix are
    /// removed (no hidden geofences), missing ones are registered again (only with Always).
    func reconcile() async {
        let registered = await system.registeredRegionIdentifiers()
        let enabledIDs = Set(geofences.filter(\.enabled).map(\.regionIdentifier))
        for identifier in registered where identifier.hasPrefix(GeofenceRules.regionIdentifierPrefix + ".")
            && !enabledIDs.contains(identifier) {
            await system.unregisterRegion(identifier: identifier)
        }
        let always = await system.permission() == .authorizedAlways
        var changed = false
        for record in geofences {
            guard record.enabled else {
                systemStates[record.geofenceID] = .disabled
                continue
            }
            if registered.contains(record.regionIdentifier) {
                systemStates[record.geofenceID] = .active
            } else if !always {
                systemStates[record.geofenceID] = .noAlwaysPermission
            } else if (try? await system.registerRegion(identifier: record.regionIdentifier, latitude: record.latitude,
                                                        longitude: record.longitude,
                                                        radiusMeters: Double(record.radiusMeters))) != nil {
                update(record.geofenceID) { $0.reregistered = true }
                systemStates[record.geofenceID] = .active
                changed = true
            } else {
                systemStates[record.geofenceID] = .notRegistered
            }
        }
        if changed { persist() }
    }

    // MARK: Create

    /// «Определить текущее место» (When In Use, only now). Creates nothing.
    func locate() async {
        guard phase != .locating, phase != .registering else { return }
        draft = nil
        phase = .locating
        guard await system.servicesEnabled() else { return fail(.servicesDisabled) }
        var permission = await system.permission()
        if permission == .notDetermined {
            permission = await system.requestWhenInUseAuthorization()
        }
        switch permission {
        case .authorizedWhenInUse, .authorizedAlways: break
        case .denied: return fail(.permissionDenied)
        case .restricted: return fail(.permissionRestricted)
        case .notDetermined, .unknown: return fail(.systemError)
        }
        let system = self.system
        let sleeper = self.sleeper
        let timeout = Self.fixTimeout
        do {
            let fix = try await withThrowingTaskGroup(of: LocationFix?.self) { group -> LocationFix? in
                group.addTask { try await system.currentFix() }
                group.addTask {
                    try await sleeper.sleep(seconds: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            guard let fix, fix.latitude.isFinite, fix.longitude.isFinite else { return fail(.timedOut) }
            let digits = GeofenceRules.coordinateFractionDigits
            draft = Draft(latitude: CoordinateRounding.round(fix.latitude, fractionDigits: digits),
                          longitude: CoordinateRounding.round(fix.longitude, fractionDigits: digits),
                          accuracyBucket: HorizontalAccuracyBucket(accuracyMeters: fix.horizontalAccuracy))
            phase = .preview
        } catch CapabilityProbeError.permissionDenied {
            fail(.permissionDenied)
        } catch {
            fail(.systemError)
        }
    }

    func cancelDraft() {
        guard phase != .registering else { return }
        draft = nil
        phase = .idle
    }

    /// «Зарегистрировать геозону», after the user confirmed. Always is requested only here.
    func registerDraft() async {
        guard let draft, phase == .preview || isRetryableFailure else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = await register(name: name, latitude: draft.latitude, longitude: draft.longitude,
                                   radiusMeters: draftRadius, origin: .user) {
            self.draft = nil
            phase = .created(id)
        }
    }

    /// A confirmed `geofence_create` draft (D-047): same checks, same Always request.
    func performActionDraft(_ actionDraft: ActionDraft) async -> ActionDraftHandlerResult {
        guard case .geofenceCreate(let payload) = actionDraft.payload, phase != .registering else { return .notPerformed }
        guard let id = await register(name: payload.nameSuggestion, latitude: payload.latitude, longitude: payload.longitude,
                                      radiusMeters: payload.radiusMeters, origin: .actionDraft) else { return .notPerformed }
        phase = .created(id)
        return .completed(resultRef: id)
    }

    private var isRetryableFailure: Bool {
        if case .failed(let failure) = phase {
            let retryable: [Failure] = [.alwaysRequired, .monitoringUnavailable, .systemError, .storage, .invalidName, .limitReached]
            return retryable.contains(failure)
        }
        return false
    }

    private func register(name: String, latitude: Double, longitude: Double, radiusMeters: Int,
                          origin: GeofenceOrigin) async -> UUID? {
        phase = .registering
        guard SafeText.isValidLine(name, maxScalars: GeofenceRules.maxNameScalars) else { return failNil(.invalidName) }
        guard GeofenceRules.allowedRadii.contains(radiusMeters) else { return failNil(.systemError) }
        guard geofences.count < GeofenceRules.maxGeofences,
              geofences.filter(\.enabled).count < GeofenceRules.maxGeofences else { return failNil(.limitReached) }
        guard await system.isMonitoringAvailable() else { return failNil(.monitoringUnavailable) }
        guard await ensureAlways() else { return failNil(.alwaysRequired) }

        let digits = GeofenceRules.coordinateFractionDigits
        let record = GeofenceRecord(geofenceID: UUID(), name: name,
                                    latitude: CoordinateRounding.round(latitude, fractionDigits: digits),
                                    longitude: CoordinateRounding.round(longitude, fractionDigits: digits),
                                    radiusMeters: radiusMeters, createdAt: WholeSeconds.floor(now()), origin: origin,
                                    enabled: true, reregistered: false, createdEventID: UUID(), createdEventSaved: false)
        guard (try? record.makeCreatedEvent()) != nil else { return failNil(.systemError) }
        do {
            try await system.registerRegion(identifier: record.regionIdentifier, latitude: record.latitude,
                                            longitude: record.longitude, radiusMeters: Double(record.radiusMeters))
        } catch {
            return failNil(.systemError)
        }
        geofences.insert(record, at: 0)
        guard persist() else {
            geofences.removeAll { $0.geofenceID == record.geofenceID }
            await system.unregisterRegion(identifier: record.regionIdentifier)
            return failNil(.storage)
        }
        systemStates[record.geofenceID] = .active
        await saveEvents()
        return record.geofenceID
    }

    /// Asks for «Всегда» only if it is not granted yet. Returns whether it is granted now.
    private func ensureAlways() async -> Bool {
        var permission = await system.permission()
        guard permission != .authorizedAlways else { return true }
        guard permission != .denied, permission != .restricted else { return false }
        permission = await system.requestAlwaysPermission()
        return permission == .authorizedAlways
    }

    // MARK: Manage

    /// Turning off removes the system region (no event). Turning on needs Always and a free slot.
    func setEnabled(_ enabled: Bool, geofenceID: UUID) async {
        guard let record = geofences.first(where: { $0.geofenceID == geofenceID }), record.enabled != enabled else { return }
        recordFailures[geofenceID] = nil
        if enabled {
            guard geofences.filter(\.enabled).count < GeofenceRules.maxGeofences else {
                recordFailures[geofenceID] = .limitReached
                return
            }
            guard await ensureAlways() else {
                recordFailures[geofenceID] = .alwaysRequired
                return
            }
            do {
                try await system.registerRegion(identifier: record.regionIdentifier, latitude: record.latitude,
                                                longitude: record.longitude, radiusMeters: Double(record.radiusMeters))
            } catch {
                recordFailures[geofenceID] = .systemError
                return
            }
            systemStates[geofenceID] = .active
        } else {
            await system.unregisterRegion(identifier: record.regionIdentifier)
            systemStates[geofenceID] = .disabled
        }
        update(geofenceID) { $0.enabled = enabled }
        persist()
    }

    /// Removal (after the user confirmed): region removed, coordinates erased, `geofence.removed`.
    func remove(geofenceID: UUID) async {
        guard let record = geofences.first(where: { $0.geofenceID == geofenceID }) else { return }
        await system.unregisterRegion(identifier: record.regionIdentifier)
        geofences.removeAll { $0.geofenceID == geofenceID }
        lastTransitions.removeAll { $0.geofenceID == geofenceID }
        systemStates[geofenceID] = nil
        recordFailures[geofenceID] = nil
        // Created but never queued: Katana never heard of it, so there is nothing to remove there.
        if record.createdEventSaved {
            pendingRemovals.append(GeofencePendingRemoval(geofenceID: geofenceID, eventID: UUID(),
                                                          removedAt: WholeSeconds.floor(now())))
        }
        persist()
        await saveEvents()
    }

    // MARK: Transitions

    /// A crossing reported by iOS. Saved before it is queued; duplicates within the window and
    /// crossings of unknown or disabled geofences are dropped. No coordinates are involved.
    func handleTransition(regionIdentifier: String, transition: GeofenceTransition) async {
        guard let geofenceID = GeofenceRules.geofenceID(fromRegionIdentifier: regionIdentifier),
              let record = geofences.first(where: { $0.geofenceID == geofenceID }), record.enabled else { return }
        let date = WholeSeconds.floor(now())
        if let last = lastTransitions.first(where: { $0.geofenceID == geofenceID }), last.transition == transition,
           date.timeIntervalSince(last.at) < GeofenceLastTransition.duplicateWindow {
            return
        }
        lastTransitions.removeAll { $0.geofenceID == geofenceID }
        lastTransitions.append(GeofenceLastTransition(geofenceID: geofenceID, transition: transition, at: date))
        pendingTransitions.append(GeofencePendingTransition(transitionID: UUID(), geofenceID: geofenceID, eventID: UUID(),
                                                            transition: transition, occurredAt: date,
                                                            deliveryContext: isAppActive ? .foreground : .background,
                                                            interrupted: record.reregistered))
        update(geofenceID) { $0.reregistered = false }
        persist()
        await saveEvents()
    }

    // MARK: Events

    /// Created → transitions → removals, each with its original event ID, at most once in the queue.
    func saveEvents() async {
        guard sink != nil else { return }
        // A crossing may arrive while events are being saved: run once more afterwards.
        guard !isRetryingEvents else {
            saveRequestedAgain = true
            return
        }
        isRetryingEvents = true
        defer { isRetryingEvents = false }
        repeat {
            saveRequestedAgain = false
            await saveEventsOnce()
        } while saveRequestedAgain
    }

    private func saveEventsOnce() async {
        guard let sink else { return }
        for record in geofences where !record.createdEventSaved {
            guard let event = try? record.makeCreatedEvent(), await sink.enqueueEvent(event) == .saved else { continue }
            update(record.geofenceID) { $0.createdEventSaved = true }
            persist()
        }
        for transition in pendingTransitions {
            // A transition is queued only after its geofence's creation was.
            guard geofences.first(where: { $0.geofenceID == transition.geofenceID })?.createdEventSaved ?? true,
                  let event = try? transition.makeEvent(), await sink.enqueueEvent(event) == .saved else { continue }
            pendingTransitions.removeAll { $0.transitionID == transition.transitionID }
            persist()
        }
        for removal in pendingRemovals {
            guard let event = try? removal.makeEvent(), await sink.enqueueEvent(event) == .saved else { continue }
            pendingRemovals.removeAll { $0.geofenceID == removal.geofenceID }
            persist()
        }
    }

    var pendingEventCount: Int {
        geofences.filter { !$0.createdEventSaved }.count + pendingTransitions.count + pendingRemovals.count
    }

    // MARK: Helpers

    private func fail(_ failure: Failure) {
        phase = .failed(failure)
    }

    private func failNil(_ failure: Failure) -> UUID? {
        phase = .failed(failure)
        return nil
    }

    private func update(_ geofenceID: UUID, _ change: (inout GeofenceRecord) -> Void) {
        guard let index = geofences.firstIndex(where: { $0.geofenceID == geofenceID }) else { return }
        change(&geofences[index])
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try store.save(GeofencesFile(geofences: geofences, pendingTransitions: pendingTransitions,
                                         lastTransitions: lastTransitions, pendingRemovals: pendingRemovals))
            if storageIssue == .writeFailed { storageIssue = nil }
            return true
        } catch {
            storageIssue = .writeFailed
            return false
        }
    }
}

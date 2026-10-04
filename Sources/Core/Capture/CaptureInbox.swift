import Foundation

/// Where captures wait for review. Without an App Group (this build, D-046) the inbox lives in
/// the app's own container; the Share Extension can use it only once a group is configured.
enum CaptureInboxLocation {
    /// `nil` = no App Group entitlement in this build.
    static let appGroupIdentifier: String? = nil
    static let directoryName = "CaptureInbox"
}

enum CaptureOrigin: String, Codable, Sendable {
    case inApp = "in_app"
    case shareExtension = "share_extension"
}

/// One inbox entry (`<capture_id>.json`, format v1). Never contains the content itself; the
/// normalized name is shown in the preview only and dropped once the capture is finished.
struct CaptureManifest: Codable, Equatable, Identifiable, Sendable {
    static let currentVersion = 1
    /// Unconfirmed entries expire after a day.
    static let pendingLifetime: TimeInterval = 24 * 60 * 60

    enum State: String, Codable, Sendable {
        /// Waiting for «Отправить в Katana» or «Отменить».
        case pendingReview = "pending_review"
        /// Confirmed; upload not done yet (offline, retry).
        case confirmed
        /// Uploaded; `share.capture.created` may still wait to be queued.
        case uploaded
    }

    var version = CaptureManifest.currentVersion
    let captureID: UUID
    let kind: CaptureKind
    let contentType: CaptureContentType
    let sizeBytes: Int
    let sha256: String
    let normalizedName: String?
    let createdAt: Date
    let expiresAt: Date
    let origin: CaptureOrigin
    let draftID: UUID?
    var state: State
    var objectRef: String?
    var createdEventID: UUID?
    var uploadedAt: Date?

    var id: UUID { captureID }

    enum CodingKeys: String, CodingKey {
        case version, kind, origin, state, sha256
        case captureID = "capture_id"
        case contentType = "content_type"
        case sizeBytes = "size_bytes"
        case normalizedName = "normalized_name"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case draftID = "draft_id"
        case objectRef = "object_ref"
        case createdEventID = "created_event_id"
        case uploadedAt = "uploaded_at"
    }
}

/// The inbox directory: `<capture_id>.json` + `<capture_id>.payload`, `quarantine/`.
/// Atomic writes, file protection until first unlock, excluded from backup. File names come
/// only from capture IDs — never from user-supplied names.
struct CaptureInboxStore: Sendable {
    static let maxEntries = 10
    static let maxTotalBytes = 50 * 1024 * 1024
    static let quarantineDirectoryName = "quarantine"

    let directoryURL: URL

    static func applicationSupport() -> CaptureInboxStore {
        CaptureInboxStore(directoryURL: VersionedJSONFileStore<CaptureHistoryFile>.applicationSupportDirectory(CaptureInboxLocation.directoryName))
    }

    /// The shared App Group inbox, when the build has the group entitlement (not in v0.3).
    static func appGroup(fileManager: FileManager = .default) -> CaptureInboxStore? {
        guard let identifier = CaptureInboxLocation.appGroupIdentifier,
              let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier) else { return nil }
        return CaptureInboxStore(directoryURL: container.appendingPathComponent(CaptureInboxLocation.directoryName, isDirectory: true))
    }

    var quarantineURL: URL { directoryURL.appendingPathComponent(Self.quarantineDirectoryName, isDirectory: true) }

    func manifestURL(_ id: UUID) -> URL { directoryURL.appendingPathComponent("\(id.uuidString.lowercased()).json") }
    func payloadURL(_ id: UUID) -> URL { directoryURL.appendingPathComponent("\(id.uuidString.lowercased()).payload") }

    struct LoadResult: Equatable, Sendable {
        var entries: [CaptureManifest] = []
        var quarantined = 0
        var expired = 0
    }

    /// Adds a validated capture as `pending_review`, within the inbox limits.
    func add(_ capture: ValidatedCapture, origin: CaptureOrigin, draftID: UUID?, now: Date) throws -> CaptureManifest {
        let existing = (try? load(now: now).entries) ?? []
        guard existing.count < Self.maxEntries,
              existing.reduce(0, { $0 + $1.sizeBytes }) + capture.sizeBytes <= Self.maxTotalBytes else {
            throw CaptureRejection.inboxFull
        }
        let created = WholeSeconds.floor(now)
        let manifest = CaptureManifest(captureID: UUID(), kind: capture.kind, contentType: capture.contentType,
                                       sizeBytes: capture.sizeBytes, sha256: capture.sha256,
                                       normalizedName: capture.normalizedName, createdAt: created,
                                       expiresAt: created.addingTimeInterval(CaptureManifest.pendingLifetime),
                                       origin: origin, draftID: draftID, state: .pendingReview)
        do {
            try prepareDirectory()
            try write(capture.data, to: payloadURL(manifest.captureID))
            try save(manifest)
        } catch {
            try? FileManager.default.removeItem(at: payloadURL(manifest.captureID))
            throw CaptureRejection.storage
        }
        return manifest
    }

    func save(_ manifest: CaptureManifest) throws {
        try prepareDirectory()
        try write(try ConnectorJSON.makeEncoder().encode(manifest), to: manifestURL(manifest.captureID))
    }

    /// Valid entries, oldest first. Broken or unknown-version manifests (and their payloads) go to
    /// `quarantine/`; payloads without a manifest and expired unconfirmed entries are deleted.
    func load(now: Date) throws -> LoadResult {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else { return LoadResult() }
        var result = LoadResult()
        var manifestIDs: Set<String> = []
        for name in names where name.hasSuffix(".json") {
            let stem = String(name.dropLast(5))
            guard let id = UUID(uuidString: stem), stem == id.uuidString.lowercased() else { continue }
            let url = manifestURL(id)
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? ConnectorJSON.makeDecoder().decode(CaptureManifest.self, from: data),
                  manifest.version == CaptureManifest.currentVersion, manifest.captureID == id,
                  fileManager.fileExists(atPath: payloadURL(id).path) || manifest.state == .uploaded else {
                quarantine(id)
                result.quarantined += 1
                continue
            }
            if manifest.state == .pendingReview, now >= manifest.expiresAt {
                remove(id)
                result.expired += 1
                continue
            }
            manifestIDs.insert(stem)
            result.entries.append(manifest)
        }
        for name in names where name.hasSuffix(".payload") && !manifestIDs.contains(String(name.dropLast(8))) {
            try? fileManager.removeItem(at: directoryURL.appendingPathComponent(name))
        }
        result.entries.sort { $0.createdAt < $1.createdAt }
        return result
    }

    func payload(_ id: UUID) throws -> Data {
        do {
            return try Data(contentsOf: payloadURL(id))
        } catch {
            throw CaptureRejection.storage
        }
    }

    /// Removes the content as soon as it is no longer needed.
    func removePayload(_ id: UUID) {
        try? FileManager.default.removeItem(at: payloadURL(id))
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: payloadURL(id))
        try? FileManager.default.removeItem(at: manifestURL(id))
    }

    /// Moves a broken entry aside (never silently deleted).
    func quarantine(_ id: UUID) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: quarantineURL, withIntermediateDirectories: true,
                                         attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        for source in [manifestURL(id), payloadURL(id)] where fileManager.fileExists(atPath: source.path) {
            let target = quarantineURL.appendingPathComponent("\(stamp)-\(source.lastPathComponent)")
            try? fileManager.moveItem(at: source, to: target)
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
}

/// A finished capture as kept in history: kind, size class, outcome. No content, no name.
struct CaptureHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case sent
        case cancelled
        /// Katana refused the upload; nothing was sent as an event.
        case failed
    }

    let captureID: UUID
    let kind: CaptureKind
    let sizeBucket: CaptureSizeBucket
    let finishedAt: Date
    let outcome: Outcome
    let eventID: UUID?
    var eventSaved: Bool

    var id: UUID { captureID }

    enum CodingKeys: String, CodingKey {
        case kind, outcome
        case captureID = "capture_id"
        case sizeBucket = "size_bucket"
        case finishedAt = "finished_at"
        case eventID = "event_id"
        case eventSaved = "event_saved"
    }
}

/// `CaptureInbox/history.json`, format v1.
struct CaptureHistoryFile: VersionedFileFormat {
    static let currentVersion = 1
    static let fileName = "history.json"
    static let maxEntries = 50
    static var empty: CaptureHistoryFile { CaptureHistoryFile() }

    var version = CaptureHistoryFile.currentVersion
    var history: [CaptureHistoryEntry] = []
}

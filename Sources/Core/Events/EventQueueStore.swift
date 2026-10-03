import Foundation

/// Metadata kept for an event Katana rejected for good. No payload.
struct RejectedEventRecord: Codable, Equatable, Sendable {
    let eventID: UUID
    let type: String
    let code: String?
    let rejectedAt: Date

    static let maxCodeLength = 64

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case type
        case code
        case rejectedAt = "rejected_at"
    }
}

/// A queued event together with the connection it may be delivered to.
struct QueuedEvent: Codable, Equatable, Sendable {
    let scope: ConnectionScope
    let event: ConnectorEvent
}

/// On-disk content of the queue file (format v2). Never contains tokens.
struct EventQueueFile: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version = EventQueueFile.currentVersion
    var events: [QueuedEvent] = []
    /// Events migrated from format v1, which had no connection scope. They are kept
    /// locally and never assigned to any connection automatically.
    var legacyEvents: [ConnectorEvent] = []
    var rejected: [RejectedEventRecord] = []

    enum CodingKeys: String, CodingKey {
        case version
        case events
        case legacyEvents = "legacy_events"
        case rejected
    }
}

/// Format v1 (KC-005): events without scope.
private struct EventQueueFileV1: Decodable {
    let version: Int
    let events: [ConnectorEvent]
    let rejected: [RejectedEventRecord]
}

private struct VersionProbe: Decodable {
    let version: Int
}

enum EventQueueError: Error, Equatable, Sendable {
    /// The queue file could not be decoded. It was moved aside (not deleted) under
    /// `quarantinedFileName`, and the queue continues empty.
    case corruptedStore(quarantinedFileName: String)
    case storageFailure
    case queueFull
    case eventTooLarge
    case invalidEvent
}

/// One JSON file in Application Support, written atomically (temporary file + rename),
/// protected until first unlock and excluded from iCloud backup.
struct EventQueueStore: Sendable {
    static let fileName = "event-queue.json"
    static let v1BackupFileName = "event-queue.v1-backup.json"

    let directoryURL: URL

    var fileURL: URL { directoryURL.appendingPathComponent(Self.fileName) }

    static func applicationSupport() -> EventQueueStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return EventQueueStore(directoryURL: base.appendingPathComponent("KatanaConnector", isDirectory: true)
            .appendingPathComponent("EventQueue", isDirectory: true))
    }

    /// Missing file → empty queue. v1 → migrated (original bytes kept as a backup).
    /// Undecodable or unknown version → quarantined, never silently deleted.
    func load() throws -> EventQueueFile {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return EventQueueFile()
        } catch {
            throw EventQueueError.storageFailure
        }

        let decoder = ConnectorJSON.makeDecoder()
        let version = (try? decoder.decode(VersionProbe.self, from: data))?.version ?? -1
        switch version {
        case EventQueueFile.currentVersion:
            if let file = try? decoder.decode(EventQueueFile.self, from: data) { return file }
        case 1:
            if let legacy = try? decoder.decode(EventQueueFileV1.self, from: data) {
                return try migrate(legacy, originalData: data)
            }
        default:
            break
        }
        let quarantinedName = try quarantine()
        throw EventQueueError.corruptedStore(quarantinedFileName: quarantinedName)
    }

    func save(_ file: EventQueueFile) throws {
        do {
            try prepareDirectory()
            let data = try ConnectorJSON.makeEncoder().encode(file)
            try write(data, to: fileURL)
        } catch {
            throw EventQueueError.storageFailure
        }
    }

    /// v1 events had no scope: they go to `legacyEvents`, never to a connection.
    private func migrate(_ legacy: EventQueueFileV1, originalData: Data) throws -> EventQueueFile {
        let migrated = EventQueueFile(events: [], legacyEvents: legacy.events, rejected: legacy.rejected)
        do {
            try prepareDirectory()
            let backupURL = directoryURL.appendingPathComponent(Self.v1BackupFileName)
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try write(originalData, to: backupURL)
            }
        } catch {
            throw EventQueueError.storageFailure
        }
        try save(migrated)
        return migrated
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func quarantine() throws -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let name = "event-queue.corrupt-\(stamp)-\(UUID().uuidString.prefix(8).lowercased()).json"
        do {
            try FileManager.default.moveItem(at: fileURL, to: directoryURL.appendingPathComponent(name))
        } catch {
            throw EventQueueError.storageFailure
        }
        return name
    }
}

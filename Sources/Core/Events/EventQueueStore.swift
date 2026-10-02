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

/// On-disk content of the queue file. Never contains tokens.
struct EventQueueFile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = EventQueueFile.currentVersion
    var events: [ConnectorEvent] = []
    var rejected: [RejectedEventRecord] = []
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

    let directoryURL: URL

    var fileURL: URL { directoryURL.appendingPathComponent(Self.fileName) }

    static func applicationSupport() -> EventQueueStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return EventQueueStore(directoryURL: base.appendingPathComponent("KatanaConnector", isDirectory: true)
            .appendingPathComponent("EventQueue", isDirectory: true))
    }

    /// Missing file → empty queue. Undecodable file → quarantined, never silently deleted.
    func load() throws -> EventQueueFile {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return EventQueueFile()
        } catch {
            throw EventQueueError.storageFailure
        }
        if let file = try? ConnectorJSON.makeDecoder().decode(EventQueueFile.self, from: data),
           file.version == EventQueueFile.currentVersion {
            return file
        }
        let quarantinedName = try quarantine()
        throw EventQueueError.corruptedStore(quarantinedFileName: quarantinedName)
    }

    func save(_ file: EventQueueFile) throws {
        do {
            try prepareDirectory()
            let data = try ConnectorJSON.makeEncoder().encode(file)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            throw EventQueueError.storageFailure
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

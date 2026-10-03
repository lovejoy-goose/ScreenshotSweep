import Foundation

/// Persisted capability snapshots. Contains only snapshots and the format version —
/// no tokens, no user data. Never creates new capability IDs: unknown IDs fail decoding.
struct CapabilitySnapshotFile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = CapabilitySnapshotFile.currentVersion
    var snapshots: [CapabilitySnapshot] = []
}

/// Source of truth for capability state, used as the registry's provider. Stored snapshots
/// override the declared defaults. File in Application Support, written atomically;
/// an unreadable file or unknown version is moved aside and ignored, never a crash.
final class CapabilitySnapshotStore: CapabilitySnapshotProviding, @unchecked Sendable {
    static let fileName = "capability-snapshots.json"

    enum LoadIssue: Equatable, Sendable {
        case quarantined
    }

    let directoryURL: URL
    private let base: any CapabilitySnapshotProviding
    private let lock = NSLock()
    private var stored: [CapabilityID: CapabilitySnapshot] = [:]
    private var issue: LoadIssue?

    var fileURL: URL { directoryURL.appendingPathComponent(Self.fileName) }

    init(directoryURL: URL, base: any CapabilitySnapshotProviding = StaticCapabilitySnapshotProvider()) {
        self.directoryURL = directoryURL
        self.base = base
        load()
    }

    static func applicationSupport() -> CapabilitySnapshotStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return CapabilitySnapshotStore(directoryURL: root.appendingPathComponent("KatanaConnector", isDirectory: true)
            .appendingPathComponent("Capabilities", isDirectory: true))
    }

    var loadIssue: LoadIssue? {
        lock.lock(); defer { lock.unlock() }
        return issue
    }

    func snapshot(for id: CapabilityID) -> CapabilitySnapshot {
        lock.lock(); defer { lock.unlock() }
        return stored[id] ?? base.snapshot(for: id)
    }

    func storedSnapshots() -> [CapabilitySnapshot] {
        lock.lock(); defer { lock.unlock() }
        return CapabilityRegistry.catalog.compactMap { stored[$0.id] }
    }

    /// Writes to disk first; memory changes only after a successful write.
    func save(_ snapshot: CapabilitySnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        var next = stored
        next[snapshot.id] = snapshot
        let file = CapabilitySnapshotFile(snapshots: CapabilityRegistry.catalog.compactMap { next[$0.id] })
        try write(file)
        stored = next
    }

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return // Missing (first launch) or unreadable: defaults are used.
        }
        if let file = try? ConnectorJSON.makeDecoder().decode(CapabilitySnapshotFile.self, from: data),
           file.version == CapabilitySnapshotFile.currentVersion {
            stored = Dictionary(file.snapshots.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let name = "capability-snapshots.corrupt-\(stamp)-\(UUID().uuidString.prefix(8).lowercased()).json"
        try? FileManager.default.moveItem(at: fileURL, to: directoryURL.appendingPathComponent(name))
        issue = .quarantined
    }

    private func write(_ file: CapabilitySnapshotFile) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let data = try ConnectorJSON.makeEncoder().encode(file)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

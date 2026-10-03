import Foundation

/// A persisted file format with an explicit version (D-043).
protocol VersionedFileFormat: Codable, Equatable, Sendable {
    static var currentVersion: Int { get }
    /// Content of a missing file (first launch).
    static var empty: Self { get }
    var version: Int { get }
}

enum VersionedFileStoreError: Error, Equatable, Sendable {
    /// The file was undecodable or had an unknown version. It was moved aside (not deleted)
    /// under `quarantinedFileName`; the caller continues with an empty state.
    case quarantined(quarantinedFileName: String)
    case storageFailure
}

private struct FileVersionProbe: Decodable {
    let version: Int
}

/// One JSON file in Application Support, shared by the v0.2 feature stores:
/// written atomically (temporary file + rename), protected until first unlock and excluded
/// from iCloud backup. A broken file or an unknown (e.g. future) version is quarantined,
/// never silently deleted and never a crash. Older versions are read only through explicit
/// `migrations` (version → decoder of that version into the current format).
struct VersionedJSONFileStore<Format: VersionedFileFormat>: Sendable {
    typealias Migration = @Sendable (Data) throws -> Format

    let directoryURL: URL
    let fileName: String
    let migrations: [Int: Migration]

    init(directoryURL: URL, fileName: String, migrations: [Int: Migration] = [:]) {
        self.directoryURL = directoryURL
        self.fileName = fileName
        self.migrations = migrations
    }

    var fileURL: URL { directoryURL.appendingPathComponent(fileName) }

    /// `Application Support/KatanaConnector/<component>`.
    static func applicationSupportDirectory(_ component: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KatanaConnector", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
    }

    /// Missing file → `Format.empty`. Older known version → migrated and saved.
    /// Undecodable or unknown version → quarantined, throws `quarantined`.
    func load() throws -> Format {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return Format.empty
        } catch {
            throw VersionedFileStoreError.storageFailure
        }

        let decoder = ConnectorJSON.makeDecoder()
        let version = (try? decoder.decode(FileVersionProbe.self, from: data))?.version ?? -1
        if version == Format.currentVersion, let file = try? decoder.decode(Format.self, from: data),
           file.version == Format.currentVersion {
            return file
        }
        if version != Format.currentVersion, let migrate = migrations[version], let migrated = try? migrate(data) {
            try save(migrated)
            return migrated
        }
        throw VersionedFileStoreError.quarantined(quarantinedFileName: try quarantine())
    }

    func save(_ file: Format) throws {
        do {
            try prepareDirectory()
            let data = try ConnectorJSON.makeEncoder().encode(file)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            throw VersionedFileStoreError.storageFailure
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
        let stem = (fileName as NSString).deletingPathExtension
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let name = "\(stem).corrupt-\(stamp)-\(UUID().uuidString.prefix(8).lowercased()).json"
        do {
            try FileManager.default.moveItem(at: fileURL, to: directoryURL.appendingPathComponent(name))
        } catch {
            throw VersionedFileStoreError.storageFailure
        }
        return name
    }
}

/// Seconds since 1970 truncated to whole seconds: v0.2 records and events carry
/// second-precision times, so what is stored equals what is sent.
enum WholeSeconds {
    static func floor(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

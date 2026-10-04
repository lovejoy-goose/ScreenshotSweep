import CryptoKit
import Foundation

/// Size class sent instead of the size (D-050). Raw values are wire values.
enum CaptureSizeBucket: String, Codable, CaseIterable, Sendable {
    case under10kb = "under_10kb"
    case under100kb = "under_100kb"
    case under1mb = "under_1mb"
    case under10mb = "under_10mb"

    /// `nil` above 10 MiB (such captures are rejected anyway).
    init?(bytes: Int) {
        switch bytes {
        case ..<0: return nil
        case ..<(10 * 1024): self = .under10kb
        case ..<(100 * 1024): self = .under100kb
        case ..<(1024 * 1024): self = .under1mb
        case ...CaptureLimits.maxImageBytes: self = .under10mb
        default: return nil
        }
    }
}

enum CaptureLimits {
    static let maxTextScalars = 10_000
    static let maxURLBytes = 2048
    static let maxImageBytes = 10 * 1024 * 1024
    static let maxPDFBytes = 10 * 1024 * 1024
    static let maxFileBytes = 5 * 1024 * 1024
    static let maxNameCharacters = 100

    static func maxBytes(_ kind: CaptureKind) -> Int {
        switch kind {
        case .text: return maxTextScalars * 4
        case .url: return maxURLBytes
        case .image: return maxImageBytes
        case .pdf: return maxPDFBytes
        case .file: return maxFileBytes
        }
    }
}

/// Content types sent in `PUT /captures` (allowlist). Raw values are HTTP `Content-Type` values.
enum CaptureContentType: String, Codable, CaseIterable, Sendable {
    case plainText = "text/plain; charset=utf-8"
    case uriList = "text/uri-list"
    case jpeg = "image/jpeg"
    case png = "image/png"
    case heic = "image/heic"
    case pdf = "application/pdf"
    case csv = "text/csv"
    case json = "application/json"

    /// Uniform type identifier of image types (for re-encoding).
    var imageTypeIdentifier: String? {
        switch self {
        case .jpeg: return "public.jpeg"
        case .png: return "public.png"
        case .heic: return "public.heic"
        default: return nil
        }
    }
}

enum CaptureRejection: Error, Equatable, Sendable {
    case empty
    case unsupportedType
    /// The bytes are not what the declared type or extension says.
    case typeMismatch
    case tooLarge
    case invalidText
    case invalidURL
    case invalidName
    /// Metadata could not be removed; the image is not kept.
    case sanitizationFailed
    case inboxFull
    /// The Katana draft does not ask for this kind.
    case notAcceptedByDraft
    case storage
}

/// What the user (or the Share Extension) handed over. Untrusted until validated.
struct CaptureCandidate: Sendable {
    let declaredKind: CaptureKind
    /// UTI (`public.jpeg`) or file extension (`jpg`), if known.
    let declaredType: String?
    let originalName: String?
    let data: Data
}

/// A validated, sanitized capture ready for the inbox. The name is for the preview only.
struct ValidatedCapture: Equatable, Sendable {
    let kind: CaptureKind
    let contentType: CaptureContentType
    let data: Data
    let normalizedName: String?
    var sizeBytes: Int { data.count }
    var sha256: String { CaptureHash.sha256(data) }
}

enum CaptureHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Byte signatures: the declared type is never trusted alone.
enum CaptureSignature: Equatable, Sendable {
    case jpeg, png, heic, pdf, utf8Text, unknown

    static func detect(_ data: Data) -> CaptureSignature {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if bytes.count >= 12, Array(bytes[4...7]) == [0x66, 0x74, 0x79, 0x70] {   // "ftyp"
            let brand = String(decoding: bytes[8...11], as: UTF8.self)
            if ["heic", "heix", "mif1", "msf1", "heim", "heis"].contains(brand) { return .heic }
        }
        if bytes.starts(with: Array("%PDF-".utf8)) { return .pdf }
        if !data.contains(0), String(data: data, encoding: .utf8) != nil { return .utf8Text }
        return .unknown
    }

    var contentType: CaptureContentType? {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .pdf: return .pdf
        case .utf8Text, .unknown: return nil
        }
    }
}

enum CaptureFileName {
    /// Last path component only; no separators, `..`, control characters or leading dots;
    /// at most 100 characters. `nil` if nothing safe remains. Never used as a storage path.
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lastComponent = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let scalars = lastComponent.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" }
        var name = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(CaptureLimits.maxNameCharacters))
        guard !name.isEmpty, name != "..", !name.contains("..") else { return nil }
        return name
    }

    static func pathExtension(_ name: String?) -> String? {
        guard let name, let dot = name.lastIndex(of: ".") else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        return ext.isEmpty ? nil : ext
    }
}

/// Validation shared by the app and the Share Extension (D-050). The main app runs it again on
/// every inbox entry before showing or uploading it.
enum CaptureValidator {
    private static let imageDeclarations: [String: CaptureContentType] = [
        "public.jpeg": .jpeg, "jpg": .jpeg, "jpeg": .jpeg,
        "public.png": .png, "png": .png,
        "public.heic": .heic, "heic": .heic,
    ]
    private static let fileDeclarations: [String: CaptureContentType] = [
        "public.plain-text": .plainText, "public.utf8-plain-text": .plainText, "txt": .plainText,
        "public.comma-separated-values-text": .csv, "csv": .csv,
        "public.json": .json, "json": .json,
    ]

    /// Kind implied by a declared type, for pickers that hand over files of several kinds.
    static func kind(forDeclaredType declared: String?) -> CaptureKind? {
        guard let key = declared?.lowercased() else { return nil }
        if imageDeclarations[key] != nil { return .image }
        if key == "com.adobe.pdf" || key == "pdf" { return .pdf }
        if fileDeclarations[key] != nil { return .file }
        return nil
    }

    static func validate(_ candidate: CaptureCandidate) throws -> ValidatedCapture {
        guard !candidate.data.isEmpty else { throw CaptureRejection.empty }
        guard candidate.data.count <= CaptureLimits.maxBytes(candidate.declaredKind) else { throw CaptureRejection.tooLarge }
        let declared = candidate.declaredType?.lowercased()
        let name = CaptureFileName.normalize(candidate.originalName)

        switch candidate.declaredKind {
        case .text:
            guard let text = utf8Text(candidate.data), text.unicodeScalars.count <= CaptureLimits.maxTextScalars,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureRejection.invalidText }
            return ValidatedCapture(kind: .text, contentType: .plainText, data: Data(text.utf8), normalizedName: nil)

        case .url:
            guard let text = utf8Text(candidate.data)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.utf8.count <= CaptureLimits.maxURLBytes,
                  text.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }),
                  let components = URLComponents(string: text),
                  let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil else { throw CaptureRejection.invalidURL }
            return ValidatedCapture(kind: .url, contentType: .uriList, data: Data(text.utf8), normalizedName: nil)

        case .image:
            let signature = CaptureSignature.detect(candidate.data)
            guard let actual = signature.contentType, actual.imageTypeIdentifier != nil else { throw CaptureRejection.unsupportedType }
            if let declared {
                guard let expected = imageDeclarations[declared] else { throw CaptureRejection.unsupportedType }
                guard expected == actual else { throw CaptureRejection.typeMismatch }
            }
            if let ext = CaptureFileName.pathExtension(name), let expected = imageDeclarations[ext], expected != actual {
                throw CaptureRejection.typeMismatch
            }
            let clean = try CaptureImageSanitizer.sanitize(candidate.data, contentType: actual)
            guard clean.count <= CaptureLimits.maxImageBytes else { throw CaptureRejection.tooLarge }
            return ValidatedCapture(kind: .image, contentType: actual, data: clean, normalizedName: name)

        case .pdf:
            guard CaptureSignature.detect(candidate.data) == .pdf else { throw CaptureRejection.typeMismatch }
            if let declared, declared != "com.adobe.pdf", declared != "pdf" { throw CaptureRejection.typeMismatch }
            if let ext = CaptureFileName.pathExtension(name), ext != "pdf" { throw CaptureRejection.typeMismatch }
            return ValidatedCapture(kind: .pdf, contentType: .pdf, data: candidate.data, normalizedName: name)

        case .file:
            let fromExtension = CaptureFileName.pathExtension(name).flatMap { fileDeclarations[$0] }
            let fromDeclared = declared.flatMap { fileDeclarations[$0] }
            guard let contentType = fromDeclared ?? fromExtension else { throw CaptureRejection.unsupportedType }
            if let fromDeclared, let fromExtension, fromDeclared != fromExtension { throw CaptureRejection.typeMismatch }
            guard CaptureSignature.detect(candidate.data) == .utf8Text, utf8Text(candidate.data) != nil else {
                throw CaptureRejection.typeMismatch
            }
            if contentType == .json, (try? JSONSerialization.jsonObject(with: candidate.data, options: [.fragmentsAllowed])) == nil {
                throw CaptureRejection.typeMismatch
            }
            guard name != nil || candidate.originalName == nil else { throw CaptureRejection.invalidName }
            return ValidatedCapture(kind: .file, contentType: contentType, data: candidate.data, normalizedName: name)
        }
    }

    /// Re-check of stored bytes against what the manifest claims (main app, every inbox entry).
    static func storedBytesMatch(kind: CaptureKind, contentType: CaptureContentType, data: Data) -> Bool {
        guard !data.isEmpty, data.count <= CaptureLimits.maxBytes(kind) else { return false }
        let signature = CaptureSignature.detect(data)
        switch kind {
        case .text: return contentType == .plainText && signature == .utf8Text
        case .url: return contentType == .uriList && signature == .utf8Text
        case .image: return signature.contentType == contentType && contentType.imageTypeIdentifier != nil
        case .pdf: return contentType == .pdf && signature == .pdf
        case .file: return ([.plainText, .csv, .json] as [CaptureContentType]).contains(contentType) && signature == .utf8Text
        }
    }

    private static func utf8Text(_ data: Data) -> String? {
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

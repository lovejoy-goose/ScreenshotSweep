import Foundation

/// Upload of confirmed content (`PUT /api/connector/captures/{capture_id}`, D-050).
protocol CaptureUploading: Sendable {
    func uploadCapture(id: UUID, kind: CaptureKind, contentType: CaptureContentType, sha256: String,
                       body: Data) async throws -> CaptureUploadReceipt
}

struct CaptureUploadReceipt: Equatable, Sendable {
    /// Opaque `[A-Za-z0-9_-]{1,64}`; no content, no URL.
    let objectRef: String

    static func isValidObjectRef(_ text: String) -> Bool {
        (1...64).contains(text.count)
            && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" }
    }
}

enum CaptureUploadError: Error, Equatable, Sendable {
    case notPaired
    case unauthorized
    /// 409: the same capture ID was uploaded with other content.
    case conflict
    /// 413/415/422 or other 4xx: Katana will not take it.
    case rejected
    case offline
    case rateLimited
    case serverError
    case invalidResponse

    var isRetryable: Bool {
        switch self {
        case .offline, .rateLimited, .serverError: return true
        default: return false
        }
    }

    static func classify(statusCode: Int) -> CaptureUploadError? {
        switch statusCode {
        case 200...299: return nil
        case 401: return .unauthorized
        case 408: return .offline
        case 409: return .conflict
        case 429: return .rateLimited
        case 400...499: return .rejected
        case 500...599: return .serverError
        default: return .invalidResponse
        }
    }
}

/// `PUT` response body.
struct CaptureUploadResponse: Decodable, Sendable {
    let captureID: String
    let objectRef: String
    let sizeBytes: Int
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case captureID = "capture_id"
        case objectRef = "object_ref"
        case sizeBytes = "size_bytes"
        case sha256
    }

    func validated(id: UUID, sha256 expected: String, size: Int) throws -> CaptureUploadReceipt {
        guard UUID(uuidString: captureID) == id, sha256.lowercased() == expected, sizeBytes == size,
              CaptureUploadReceipt.isValidObjectRef(objectRef) else { throw CaptureUploadError.invalidResponse }
        return CaptureUploadReceipt(objectRef: objectRef)
    }
}

enum CaptureUploadStatus: String, Codable, Sendable {
    case uploaded
    case notUploaded = "not_uploaded"
}

enum CaptureEvents {
    private struct CreatedPayload: Encodable {
        let captureID: UUID
        let kind: CaptureKind
        let sizeBucket: CaptureSizeBucket
        let createdAt: Date
        let objectRef: String

        enum CodingKeys: String, CodingKey {
            case captureID = "capture_id"
            case kind
            case sizeBucket = "size_bucket"
            case createdAt = "created_at"
            case uploadStatus = "upload_status"
            case objectRef = "object_ref"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(captureID.uuidString.lowercased(), forKey: .captureID)
            try container.encode(kind, forKey: .kind)
            try container.encode(sizeBucket, forKey: .sizeBucket)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(CaptureUploadStatus.uploaded, forKey: .uploadStatus)
            try container.encode(objectRef, forKey: .objectRef)
        }
    }

    private struct CancelledPayload: Encodable {
        let captureID: UUID
        let kind: CaptureKind
        let sizeBucket: CaptureSizeBucket
        let cancelledAt: Date

        enum CodingKeys: String, CodingKey {
            case captureID = "capture_id"
            case kind
            case sizeBucket = "size_bucket"
            case cancelledAt = "cancelled_at"
            case uploadStatus = "upload_status"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(captureID.uuidString.lowercased(), forKey: .captureID)
            try container.encode(kind, forKey: .kind)
            try container.encode(sizeBucket, forKey: .sizeBucket)
            try container.encode(cancelledAt, forKey: .cancelledAt)
            try container.encode(CaptureUploadStatus.notUploaded, forKey: .uploadStatus)
        }
    }

    /// `share.capture.created` — no text, URL, name, path or metadata; only the object reference.
    static func created(_ manifest: CaptureManifest) throws -> ConnectorEvent {
        guard manifest.state == .uploaded, let objectRef = manifest.objectRef, CaptureUploadReceipt.isValidObjectRef(objectRef),
              let eventID = manifest.createdEventID, let uploadedAt = manifest.uploadedAt,
              let bucket = CaptureSizeBucket(bytes: manifest.sizeBytes) else { throw ContextEventError.invalidPayload }
        return try ContextEventSchema.makeEvent(.captureCreated, eventID: eventID, occurredAt: uploadedAt, sessionID: manifest.captureID,
                                                payload: CreatedPayload(captureID: manifest.captureID, kind: manifest.kind,
                                                                        sizeBucket: bucket, createdAt: uploadedAt, objectRef: objectRef))
    }

    /// `share.capture.cancelled`.
    static func cancelled(_ entry: CaptureHistoryEntry) throws -> ConnectorEvent {
        guard entry.outcome == .cancelled, let eventID = entry.eventID else { throw ContextEventError.invalidPayload }
        return try ContextEventSchema.makeEvent(.captureCancelled, eventID: eventID, occurredAt: entry.finishedAt,
                                                sessionID: entry.captureID,
                                                payload: CancelledPayload(captureID: entry.captureID, kind: entry.kind,
                                                                          sizeBucket: entry.sizeBucket, cancelledAt: entry.finishedAt))
    }
}

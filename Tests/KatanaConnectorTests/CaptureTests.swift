import CoreGraphics
import ImageIO
import XCTest

final class MockCaptureUploader: CaptureUploading, @unchecked Sendable {
    struct Call: Equatable {
        let id: UUID
        let kind: CaptureKind
        let contentType: CaptureContentType
        let sha256: String
        let body: Data
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var result: Result<CaptureUploadReceipt, CaptureUploadError> = .success(CaptureUploadReceipt(objectRef: "cap_7Hq2x"))

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    func uploadCapture(id: UUID, kind: CaptureKind, contentType: CaptureContentType, sha256: String,
                       body: Data) async throws -> CaptureUploadReceipt {
        lock.lock(); _calls.append(Call(id: id, kind: kind, contentType: contentType, sha256: sha256, body: body)); lock.unlock()
        return try result.get()
    }
}

enum CaptureFixtures {
    static let secretText = "Секретная заметка 42"
    static let link = "https://example.invalid/path?q=private"

    /// A small image with GPS, EXIF and TIFF metadata, as a camera would write it.
    static func image(_ typeIdentifier: String = "public.jpeg") -> Data {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, typeIdentifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 55.7558, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 37.6173, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:04 12:00:00",
                                             kCGImagePropertyExifUserComment: "private comment"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 15"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    static let pdf = Data("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n".utf8)
}

/// V3-005: capture validation, metadata removal, inbox, preview/confirm/cancel, upload, events.
final class CaptureTests: XCTestCase {
    private var directory: URL!
    private var clock: TestClock!
    private var uploader: MockCaptureUploader!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        directory = ContextFixtures.temporaryDirectory("Capture")
        clock = TestClock()
        uploader = MockCaptureUploader()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var inbox: CaptureInboxStore { CaptureInboxStore(directoryURL: directory) }

    @MainActor
    private func makeCapture(sink: RecordingEventSink? = nil, extraInboxes: [CaptureInboxStore] = []) -> CaptureCoordinator {
        let clock = self.clock!
        return CaptureCoordinator(inboxes: [inbox] + extraInboxes,
                                  historyStore: VersionedJSONFileStore(directoryURL: directory, fileName: CaptureHistoryFile.fileName),
                                  uploader: uploader, sink: sink, now: { clock.now() })
    }

    private func validate(_ kind: CaptureKind, _ data: Data, type: String? = nil, name: String? = nil) throws -> ValidatedCapture {
        try CaptureValidator.validate(CaptureCandidate(declaredKind: kind, declaredType: type, originalName: name, data: data))
    }

    private func assertRejected(_ expected: CaptureRejection, _ kind: CaptureKind, _ data: Data, type: String? = nil,
                                name: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try validate(kind, data, type: type, name: name), file: file, line: line) {
            XCTAssertEqual($0 as? CaptureRejection, expected, file: file, line: line)
        }
    }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    // MARK: Validation per type

    func testEverySupportedType() throws {
        let text = try validate(.text, Data(CaptureFixtures.secretText.utf8))
        XCTAssertEqual(text.contentType, .plainText)
        let url = try validate(.url, Data("  \(CaptureFixtures.link)\n".utf8))
        XCTAssertEqual(url.contentType, .uriList)
        XCTAssertEqual(String(decoding: url.data, as: UTF8.self), CaptureFixtures.link)
        XCTAssertEqual(try validate(.image, CaptureFixtures.image(), type: "public.jpeg", name: "IMG_1.JPG").contentType, .jpeg)
        XCTAssertEqual(try validate(.image, CaptureFixtures.image("public.png"), type: "public.png").contentType, .png)
        XCTAssertEqual(try validate(.pdf, CaptureFixtures.pdf, type: "com.adobe.pdf", name: "a.pdf").contentType, .pdf)
        XCTAssertEqual(try validate(.file, Data("a,b\n1,2\n".utf8), name: "t.csv").contentType, .csv)
        XCTAssertEqual(try validate(.file, Data(#"{"a":1}"#.utf8), type: "public.json").contentType, .json)
        XCTAssertEqual(try validate(.file, Data("note".utf8), type: "public.plain-text", name: "n.txt").contentType, .plainText)
        XCTAssertEqual(CaptureKind.allCases.map(\.rawValue), ["text", "url", "image", "pdf", "file"])
    }

    func testUnsupportedTypesAndBadContent() {
        assertRejected(.unsupportedType, .image, Data("GIF89a......".utf8), type: "com.compuserve.gif")
        assertRejected(.unsupportedType, .file, Data("MZ".utf8), name: "setup.exe")
        assertRejected(.unsupportedType, .file, Data("x".utf8), type: "public.html")
        XCTAssertNil(CaptureValidator.kind(forDeclaredType: "public.mpeg-4"))
        XCTAssertNil(CaptureValidator.kind(forDeclaredType: "com.apple.application-bundle"))
        assertRejected(.empty, .text, Data())
        assertRejected(.invalidText, .text, Data("   \n".utf8))
        assertRejected(.invalidText, .text, Data([0x61, 0x00, 0x62]))
        for bad in ["ftp://example.invalid/a", "javascript:alert(1)", "https://user:pass@example.invalid", "https://",
                    "https://exämple.invalid", "file:///etc/passwd", "katana-connector://open?v=1&feature=pairing"] {
            assertRejected(.invalidURL, .url, Data(bad.utf8))
        }
        assertRejected(.tooLarge, .url, Data(("https://example.invalid/" + String(repeating: "a", count: 2040)).utf8))   // the byte limit is checked first
    }

    func testOversizeIsCheckedOnActualBytes() {
        assertRejected(.invalidText, .text, Data(String(repeating: "я", count: CaptureLimits.maxTextScalars + 1).utf8))
        assertRejected(.tooLarge, .text, Data(repeating: 0x61, count: CaptureLimits.maxTextScalars * 4 + 1))
        assertRejected(.tooLarge, .image, Data(repeating: 0xFF, count: CaptureLimits.maxImageBytes + 1), type: "public.jpeg")
        assertRejected(.tooLarge, .pdf, CaptureFixtures.pdf + Data(repeating: 0x20, count: CaptureLimits.maxPDFBytes))
        assertRejected(.tooLarge, .file, Data(repeating: 0x61, count: CaptureLimits.maxFileBytes + 1), name: "big.txt")
        XCTAssertEqual(CaptureSizeBucket(bytes: 10 * 1024 - 1), .under10kb)
        XCTAssertEqual(CaptureSizeBucket(bytes: 10 * 1024), .under100kb)
        XCTAssertEqual(CaptureSizeBucket(bytes: 1024 * 1024), .under10mb)
        XCTAssertNil(CaptureSizeBucket(bytes: 10 * 1024 * 1024 + 1))
        XCTAssertEqual(CaptureSizeBucket.allCases.map(\.rawValue), ["under_10kb", "under_100kb", "under_1mb", "under_10mb"])
    }

    func testTypeOrExtensionMismatchIsRejected() {
        assertRejected(.typeMismatch, .image, CaptureFixtures.image("public.png"), type: "public.jpeg")
        assertRejected(.typeMismatch, .image, CaptureFixtures.image(), type: "public.jpeg", name: "photo.png")
        assertRejected(.unsupportedType, .image, CaptureFixtures.pdf, type: "public.jpeg")
        assertRejected(.typeMismatch, .pdf, Data("not a pdf".utf8), type: "com.adobe.pdf")
        assertRejected(.typeMismatch, .pdf, CaptureFixtures.pdf, name: "report.txt")
        assertRejected(.typeMismatch, .file, Data("plain words".utf8), name: "data.json")
        assertRejected(.typeMismatch, .file, CaptureFixtures.image(), name: "notes.txt")
        assertRejected(.typeMismatch, .file, Data("a,b".utf8), type: "public.json", name: "x.csv")
    }

    func testFileNamesAreNormalizedAndNeverUsedAsPaths() throws {
        XCTAssertEqual(CaptureFileName.normalize("../../etc/passwd.txt"), "passwd.txt")
        XCTAssertEqual(CaptureFileName.normalize("..\\..\\Windows\\a.csv"), "a.csv")
        XCTAssertEqual(CaptureFileName.normalize("...hidden.txt"), "hidden.txt")
        XCTAssertEqual(CaptureFileName.normalize("a\u{0000}b\u{202E}c.txt"), "abc.txt")
        XCTAssertEqual(CaptureFileName.normalize("C:report.pdf"), "Creport.pdf")
        XCTAssertNil(CaptureFileName.normalize("/"))
        XCTAssertNil(CaptureFileName.normalize(".."))
        XCTAssertNil(CaptureFileName.normalize("a..b"))
        XCTAssertEqual(CaptureFileName.normalize(String(repeating: "x", count: 300) + ".txt")?.count, 100)

        let capture = try validate(.file, Data("ok".utf8), name: "../../../Library/Preferences/evil.txt")
        XCTAssertEqual(capture.normalizedName, "evil.txt")
        let manifest = try inbox.add(capture, origin: .inApp, draftID: nil, now: Fixtures.pairedAt)
        XCTAssertEqual(Set(files()), ["\(manifest.captureID.uuidString.lowercased()).json",
                                     "\(manifest.captureID.uuidString.lowercased()).payload"],
                       "storage names come only from the capture ID")
    }

    // MARK: Image metadata

    func testImageMetadataIsRemovedButOrientationKept() throws {
        let original = CaptureFixtures.image()
        XCTAssertTrue(CaptureImageSanitizer.containsPersonalMetadata(original), "fixture carries GPS and EXIF")
        for (type, data) in [("public.jpeg", original), ("public.png", CaptureFixtures.image("public.png"))] {
            let clean = try validate(.image, data, type: type).data
            XCTAssertFalse(CaptureImageSanitizer.containsPersonalMetadata(clean), type)
            XCTAssertFalse(CaptureImageSanitizer.metadataDictionaries(clean).contains(kCGImagePropertyGPSDictionary as String), type)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(clean as CFData, nil))
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil), "still a valid image")
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            if type == "public.jpeg" {
                XCTAssertEqual(properties?[kCGImagePropertyOrientation] as? Int, 6, "orientation kept")
            }
            XCTAssertEqual(CaptureSignature.detect(clean), CaptureSignature.detect(data), "same format")
            let text = String(decoding: clean, as: UTF8.self)
            XCTAssertFalse(text.contains("private comment"))
            XCTAssertFalse(text.contains("iPhone 15"))
        }
        XCTAssertThrowsError(try CaptureImageSanitizer.sanitize(Data([0xFF, 0xD8, 0xFF, 0x00]), contentType: .jpeg))
    }

    // MARK: Inbox: limits, TTL, quarantine

    func testInboxLimitsTTLAndQuarantine() throws {
        let capture = try validate(.text, Data("x".utf8))
        var ids: [UUID] = []
        for _ in 0..<CaptureInboxStore.maxEntries {
            ids.append(try inbox.add(capture, origin: .inApp, draftID: nil, now: Fixtures.pairedAt).captureID)
        }
        XCTAssertThrowsError(try inbox.add(capture, origin: .inApp, draftID: nil, now: Fixtures.pairedAt)) {
            XCTAssertEqual($0 as? CaptureRejection, .inboxFull)
        }
        XCTAssertEqual(CaptureInboxStore.maxTotalBytes, 50 * 1024 * 1024)

        // Broken and unknown-version manifests are moved aside with their payloads.
        var future = try XCTUnwrap(try inbox.load(now: Fixtures.pairedAt).entries.first { $0.captureID == ids[1] })
        try Data("{".utf8).write(to: inbox.manifestURL(ids[0]))
        future.version = 9
        try ConnectorJSON.makeEncoder().encode(future).write(to: inbox.manifestURL(ids[1]))
        // An orphan payload is deleted.
        try Data("orphan".utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString.lowercased()).payload"))
        let loaded = try inbox.load(now: Fixtures.pairedAt)
        XCTAssertEqual(loaded.quarantined, 2)
        XCTAssertEqual(loaded.entries.count, CaptureInboxStore.maxEntries - 2)
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: inbox.quarantineURL.path)
        XCTAssertEqual(quarantined.count, 4, "manifest and payload of both kept for diagnostics")

        // Unconfirmed entries expire after a day.
        let expired = try inbox.load(now: Fixtures.pairedAt.addingTimeInterval(CaptureManifest.pendingLifetime))
        XCTAssertEqual(expired.expired, CaptureInboxStore.maxEntries - 2)
        XCTAssertTrue(expired.entries.isEmpty)
        XCTAssertEqual(files().filter { $0.hasSuffix(".payload") }, [], "temporary files are gone")
    }

    @MainActor
    func testTamperedOrExtensionEntriesAreRevalidated() async throws {
        let shared = CaptureInboxStore(directoryURL: directory.appendingPathComponent("Group"))
        let fromExtension = try shared.add(try validate(.text, Data("from share".utf8)), origin: .shareExtension,
                                           draftID: nil, now: Fixtures.pairedAt)
        let tampered = try shared.add(try validate(.text, Data("original".utf8)), origin: .shareExtension,
                                      draftID: nil, now: Fixtures.pairedAt)
        try Data("changed!".utf8).write(to: shared.payloadURL(tampered.captureID))
        let pretendImage = try shared.add(try validate(.text, Data("text".utf8)), origin: .shareExtension,
                                          draftID: nil, now: Fixtures.pairedAt)
        var forged = pretendImage
        forged = CaptureManifest(captureID: forged.captureID, kind: .image, contentType: .jpeg, sizeBytes: forged.sizeBytes,
                                 sha256: forged.sha256, normalizedName: nil, createdAt: forged.createdAt,
                                 expiresAt: forged.expiresAt, origin: .shareExtension, draftID: nil, state: .pendingReview)
        try shared.save(forged)

        let capture = makeCapture(extraInboxes: [shared])
        XCTAssertEqual(capture.items.map(\.captureID), [fromExtension.captureID], "only the entry whose bytes match is shown")
        XCTAssertEqual(capture.storageIssue, .quarantined(2))
        XCTAssertTrue(uploader.calls.isEmpty, "nothing is uploaded by opening the app")
    }

    // MARK: Preview → confirm / cancel

    @MainActor
    func testConfirmUploadsExactBytesThenEventWithoutContent() async throws {
        let sink = RecordingEventSink()
        let capture = makeCapture(sink: sink)
        capture.importText(CaptureFixtures.secretText)
        guard case .added(let id) = capture.importState else { return XCTFail("expected added, got \(capture.importState)") }
        XCTAssertEqual(capture.items.first?.state, .pendingReview)
        XCTAssertTrue(uploader.calls.isEmpty, "nothing is sent before «Отправить в Katana»")
        XCTAssertTrue(sink.attempts.isEmpty)

        clock.advance(2.5)
        async let one: Void = capture.confirm(id)
        async let two: Void = capture.confirm(id)
        _ = await (one, two)
        XCTAssertEqual(uploader.calls.count, 1)
        let call = try XCTUnwrap(uploader.calls.first)
        XCTAssertEqual(call.id, id)
        XCTAssertEqual(call.kind, .text)
        XCTAssertEqual(call.contentType, .plainText)
        XCTAssertEqual(call.body, Data(CaptureFixtures.secretText.utf8))
        XCTAssertEqual(call.sha256, CaptureHash.sha256(Data(CaptureFixtures.secretText.utf8)))

        let event = try XCTUnwrap(sink.events.first)
        let json = try ContextFixtures.json(event)
        XCTAssertEqual(json["type"] as? String, "share.capture.created")
        XCTAssertEqual(json["session_id"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(json["occurred_at"] as? String, "2026-09-21T14:13:22Z")
        let payload = try ContextFixtures.payload(event)
        XCTAssertEqual(Set(payload.keys), ["capture_id", "kind", "size_bucket", "created_at", "upload_status", "object_ref"])
        XCTAssertEqual(payload["kind"] as? String, "text")
        XCTAssertEqual(payload["size_bucket"] as? String, "under_10kb")
        XCTAssertEqual(payload["upload_status"] as? String, "uploaded")
        XCTAssertEqual(payload["object_ref"] as? String, "cap_7Hq2x")
        XCTAssertFalse(try ContextFixtures.text(event).contains("Секрет"))

        XCTAssertTrue(capture.items.isEmpty)
        XCTAssertEqual(capture.history.first?.outcome, .sent)
        XCTAssertEqual(files(), ["history.json"], "content and manifest are deleted after sending")
    }

    @MainActor
    func testCancelDeletesFilesAndSendsCancelledWithoutContent() async throws {
        let sink = RecordingEventSink()
        let capture = makeCapture(sink: sink)
        capture.importFile(data: CaptureFixtures.pdf, declaredType: "com.adobe.pdf", originalName: "Договор аренды.pdf")
        let item = try XCTUnwrap(capture.items.first)
        XCTAssertEqual(item.normalizedName, "Договор аренды.pdf", "shown in the preview only")
        await capture.cancel(item.captureID)
        XCTAssertTrue(uploader.calls.isEmpty)
        let event = try XCTUnwrap(sink.events.first)
        XCTAssertEqual(event.type, "share.capture.cancelled")
        let payload = try ContextFixtures.payload(event)
        XCTAssertEqual(Set(payload.keys), ["capture_id", "kind", "size_bucket", "cancelled_at", "upload_status"])
        XCTAssertEqual(payload["upload_status"] as? String, "not_uploaded")
        XCTAssertEqual(payload["kind"] as? String, "pdf")
        let text = try ContextFixtures.text(event)
        for forbidden in ["Договор", ".pdf", "%PDF", "file://", "/var/"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
        XCTAssertEqual(files(), ["history.json"])
        let historyText = String(decoding: try Data(contentsOf: directory.appendingPathComponent("history.json")), as: UTF8.self)
        XCTAssertFalse(historyText.contains("Договор"), "history keeps no names")
    }

    @MainActor
    func testOfflineRetryAndRelaunchRecoveryAreExactOnce() async throws {
        let sink = RecordingEventSink()
        uploader.result = .failure(.offline)
        let first = makeCapture(sink: sink)
        first.importURL(CaptureFixtures.link)
        let id = try XCTUnwrap(first.items.first?.captureID)
        await first.confirm(id)
        XCTAssertEqual(first.itemStatus[id], .waitingForNetwork)
        XCTAssertEqual(first.items.first?.state, .confirmed)
        XCTAssertTrue(sink.attempts.isEmpty)

        // Relaunch: the confirmed entry is uploaded once; the event is queued once.
        uploader.result = .success(CaptureUploadReceipt(objectRef: "obj-1"))
        sink.outcome = .failed   // the queue is unavailable right after the upload
        let second = makeCapture(sink: sink)
        await second.resumePending()
        XCTAssertEqual(uploader.calls.count, 2)
        XCTAssertEqual(second.items.first?.state, .uploaded, "uploaded and remembered; payload already removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.payloadURL(id).path))
        let failedEventID = try XCTUnwrap(sink.attempts.last?.eventID)

        sink.outcome = .saved
        let third = makeCapture(sink: sink)
        await third.resumePending()
        await third.resumePending()
        XCTAssertEqual(uploader.calls.count, 2, "never uploaded again after success")
        XCTAssertEqual(sink.events.map(\.eventID), [failedEventID], "same event ID after relaunch")
        XCTAssertEqual(third.history.first?.outcome, .sent)
    }

    @MainActor
    func testUnauthorizedConflictAndNotAcceptedByDraft() async throws {
        let sink = RecordingEventSink()
        uploader.result = .failure(.unauthorized)
        let capture = makeCapture(sink: sink)
        capture.importText("hello")
        let id = try XCTUnwrap(capture.items.first?.captureID)
        await capture.confirm(id)
        XCTAssertEqual(capture.itemStatus[id], .requiresRepair)
        XCTAssertEqual(sink.unauthorizedReports, 1)
        XCTAssertEqual(capture.items.first?.state, .confirmed, "kept for after re-pairing")

        uploader.result = .failure(.conflict)
        await capture.resumePending()
        XCTAssertTrue(capture.items.isEmpty)
        XCTAssertEqual(capture.history.first?.outcome, .failed)
        XCTAssertTrue(sink.events.isEmpty, "a refused upload creates no event")

        let draft = ActionDraft(draftID: UUID(), serverTime: ActionDraftFixtures.serverDate,
                                expiresAt: ActionDraftFixtures.serverDate.addingTimeInterval(600),
                                payload: .sharedCapture(CaptureDraftPayload(acceptedKinds: [.image], prompt: "Фото чека")))
        let result = await capture.performActionDraft(draft)
        XCTAssertEqual(result, .continuing)
        capture.importText("not an image")
        XCTAssertEqual(capture.importState, .rejected(.notAcceptedByDraft))
    }

    @MainActor
    func testSharedCaptureDraftIsAcceptedAfterTheCaptureIsSent() async throws {
        let sink = RecordingEventSink()
        let capture = makeCapture(sink: sink)
        let draft = ActionDraft(draftID: ActionDraftFixtures.draftID, serverTime: ActionDraftFixtures.serverDate,
                                expiresAt: ActionDraftFixtures.serverDate.addingTimeInterval(600),
                                payload: .sharedCapture(CaptureDraftPayload(acceptedKinds: [.image, .pdf], prompt: "Фото чека")))
        let drafts = ActionDraftCoordinator(store: VersionedJSONFileStore(directoryURL: directory.appendingPathComponent("Drafts"),
                                                                          fileName: ActionDraftStoreFile.fileName),
                                            fetcher: MockActionDraftFetcher(result: .success(draft)), sink: sink,
                                            now: { Fixtures.pairedAt })
        drafts.register(capture, for: .sharedCapture)
        capture.actionDrafts = drafts
        await drafts.loadDraft(draft.draftID)
        await drafts.perform(draft.draftID)
        XCTAssertEqual(drafts.phase(for: draft.draftID), .continuing)
        XCTAssertTrue(sink.attempts.isEmpty, "accepting the request sends nothing yet")

        capture.importFile(data: CaptureFixtures.image(), declaredType: "public.jpeg", originalName: nil)
        let item = try XCTUnwrap(capture.items.first)
        XCTAssertEqual(item.draftID, draft.draftID)
        await capture.confirm(item.captureID)
        XCTAssertEqual(sink.events.map(\.type), ["share.capture.created", "action_draft.accepted"])
        XCTAssertEqual(try ContextFixtures.payload(XCTUnwrap(sink.events.last))["result_ref"] as? String,
                       item.captureID.uuidString.lowercased())
        XCTAssertEqual(drafts.phase(for: draft.draftID), .accepted)
        XCTAssertFalse(CaptureImageSanitizer.containsPersonalMetadata(try XCTUnwrap(uploader.calls.first?.body)),
                       "the uploaded image has no GPS or EXIF")
    }

    // MARK: Upload API (real client over the mocked network)

    private func client(_ store: InMemoryTokenStore = InMemoryTokenStore(credentials: Fixtures.credentials)) -> URLSessionConnectorAPIClient {
        URLSessionConnectorAPIClient(store: store, transport: URLSessionConnectorTransport(session: MockURLProtocol.makeSession()),
                                     appVersion: "0.3.0", systemVersion: "18.0", now: { Fixtures.pairedAt })
    }

    func testUploadIsAuthenticatedPUTWithExactHeadersAndBody() async throws {
        let id = UUID()
        let body = Data("hello".utf8)
        let sha = CaptureHash.sha256(body)
        MockURLProtocol.reply = .response(status: 201, body: Data(
            #"{"capture_id":"\#(id.uuidString.lowercased())","object_ref":"cap_1","size_bytes":5,"sha256":"\#(sha)"}"#.utf8))
        let receipt = try await client().uploadCapture(id: id, kind: .text, contentType: .plainText, sha256: sha, body: body)
        XCTAssertEqual(receipt.objectRef, "cap_1")
        let recorded = try XCTUnwrap(MockURLProtocol.recorded.first)
        XCTAssertEqual(recorded.method, "PUT")
        XCTAssertEqual(recorded.path, "/api/connector/captures/\(id.uuidString.lowercased())")
        XCTAssertEqual(recorded.authorization, "Bearer \(Fixtures.token)")
        XCTAssertEqual(recorded.body, body)
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain; charset=utf-8")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Katana-Capture-Kind"), "text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Katana-Capture-SHA256"), sha)
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.timeoutInterval, 60)
        XCTAssertEqual(sha.count, 64)
        XCTAssertEqual(CaptureContentType.allCases.map(\.rawValue), [
            "text/plain; charset=utf-8", "text/uri-list", "image/jpeg", "image/png", "image/heic", "application/pdf",
            "text/csv", "application/json",
        ])
    }

    func testUploadResponseValidationAndStatusMapping() async {
        let id = UUID()
        let body = Data("hello".utf8)
        let sha = CaptureHash.sha256(body)
        func expect(_ expected: CaptureUploadError, file: StaticString = #filePath, line: UInt = #line) async {
            do {
                _ = try await client().uploadCapture(id: id, kind: .text, contentType: .plainText, sha256: sha, body: body)
                XCTFail("expected \(expected)", file: file, line: line)
            } catch {
                XCTAssertEqual(error as? CaptureUploadError, expected, file: file, line: line)
            }
        }
        for bad in [#"{"capture_id":"\#(UUID().uuidString)","object_ref":"cap_1","size_bytes":5,"sha256":"\#(sha)"}"#,
                    #"{"capture_id":"\#(id.uuidString)","object_ref":"cap_1","size_bytes":6,"sha256":"\#(sha)"}"#,
                    #"{"capture_id":"\#(id.uuidString)","object_ref":"cap_1","size_bytes":5,"sha256":"00"}"#,
                    #"{"capture_id":"\#(id.uuidString)","object_ref":"https://x/y","size_bytes":5,"sha256":"\#(sha)"}"#,
                    "not json"] {
            MockURLProtocol.reply = .response(status: 200, body: Data(bad.utf8))
            await expect(.invalidResponse)
        }
        for (status, expected) in [(401, CaptureUploadError.unauthorized), (409, .conflict), (413, .rejected), (415, .rejected),
                                   (422, .rejected), (408, .offline), (429, .rateLimited), (503, .serverError),
                                   (302, .invalidResponse)] {
            MockURLProtocol.reply = .response(status: status, body: Data("{}".utf8))
            await expect(expected)
        }
        MockURLProtocol.reset()
        do {
            _ = try await client(InMemoryTokenStore()).uploadCapture(id: id, kind: .text, contentType: .plainText, sha256: sha, body: body)
            XCTFail("expected notPaired")
        } catch {
            XCTAssertEqual(error as? CaptureUploadError, .notPaired)
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    func testStorageIdentifiersAndAppGroupIsOff() {
        XCTAssertNil(CaptureInboxLocation.appGroupIdentifier, "no App Group in this build (D-046)")
        XCTAssertNil(CaptureInboxStore.appGroup())
        let path = CaptureInboxStore.applicationSupport().directoryURL.standardizedFileURL.path
        XCTAssertTrue(path.hasSuffix("/Application Support/KatanaConnector/CaptureInbox"), path)
        XCTAssertEqual(CaptureManifest.currentVersion, 1)
        XCTAssertEqual(CaptureHistoryFile.fileName, "history.json")
        XCTAssertEqual(CaptureHistoryFile.currentVersion, 1)
    }
}

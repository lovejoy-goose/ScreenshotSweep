import CoreNFC

/// Native Core NFC adapter (D-046, D-048). Off in builds without the NFC entitlement and
/// `NFCReaderUsageDescription` (`requires_entitlement`). When on, it hands over only a Katana
/// action link — never the tag UID or the raw NDEF message — and never locks a tag.
final class SystemNFCTagAccess: NFCTagSystem, @unchecked Sendable {
    func status() async -> CoreNFCStatus {
        // Without the usage description any Core NFC session terminates the app: check it first.
        guard CoreNFCAvailability.entitlementConfigured,
              Bundle.main.object(forInfoDictionaryKey: CoreNFCAvailability.usageDescriptionKey) != nil else {
            return .requiresEntitlement
        }
        return NFCNDEFReaderSession.readingAvailable ? .available : .unsupportedDevice
    }

    func readActionLink() async throws -> NFCReadResult {
        guard await status() == .available else { throw NFCTagError.notAvailable }
        return try await NFCSessionRunner(mode: .read).run()
    }

    func writeActionLink(_ url: URL) async throws {
        guard await status() == .available else { throw NFCTagError.notAvailable }
        _ = try await NFCSessionRunner(mode: .write(url)).run()
    }
}

/// One NFC reader session bridged to async/await. Resolves exactly once.
private final class NFCSessionRunner: NSObject, NFCNDEFReaderSessionDelegate, @unchecked Sendable {
    enum Mode {
        case read
        case write(URL)
    }

    /// Keeps runners alive while their session is active.
    private static let active = ActiveRunners()

    private let mode: Mode
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NFCReadResult, Error>?
    private var session: NFCNDEFReaderSession?

    init(mode: Mode) {
        self.mode = mode
    }

    func run() async throws -> NFCReadResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NFCReadResult, Error>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            Self.active.insert(self)
            let session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: false)
            switch mode {
            case .read: session.alertMessage = "Поднесите iPhone к NFC-метке."
            case .write: session.alertMessage = "Поднесите iPhone к метке для записи ссылки Katana."
            }
            self.session = session
            session.begin()
        }
    }

    private func finish(_ result: Result<NFCReadResult, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        pending.resume(with: result)
        Self.active.remove(self)
    }

    private func fail(_ session: NFCNDEFReaderSession, _ error: NFCTagError, message: String) {
        session.invalidate(errorMessage: message)
        finish(.failure(error))
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        let code = (error as? NFCReaderError)?.code
        finish(.failure(code == .readerSessionInvalidationErrorUserCanceled ? NFCTagError.cancelled : NFCTagError.systemError))
    }

    /// Required by the protocol; tags are handled in `didDetect tags`.
    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {}

    func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]) {
        guard let tag = tags.first else { return }
        session.connect(to: tag) { [self] error in
            guard error == nil else { return fail(session, .systemError, message: "Не удалось подключиться к метке.") }
            tag.queryNDEFStatus { [self] status, capacity, error in
                guard error == nil else { return fail(session, .systemError, message: "Не удалось прочитать метку.") }
                switch mode {
                case .read:
                    guard status != .notSupported else { return fail(session, .unsupportedTag, message: "Метка не поддерживается.") }
                    tag.readNDEF { [self] message, error in
                        if let error = error as? NFCReaderError, error.code == .ndefReaderSessionErrorZeroLengthMessage {
                            session.alertMessage = "Метка пустая."
                            session.invalidate()
                            return finish(.success(.empty))
                        }
                        guard error == nil else { return fail(session, .systemError, message: "Не удалось прочитать метку.") }
                        session.alertMessage = "Готово."
                        session.invalidate()
                        finish(.success(Self.result(from: message)))
                    }
                case .write(let url):
                    switch status {
                    case .notSupported: return fail(session, .unsupportedTag, message: "Метка не поддерживается.")
                    case .readOnly: return fail(session, .readOnly, message: "Метка защищена от записи.")
                    case .readWrite: break
                    @unknown default: return fail(session, .unsupportedTag, message: "Метка не поддерживается.")
                    }
                    guard let record = NFCNDEFPayload.wellKnownTypeURIPayload(url: url) else {
                        return fail(session, .systemError, message: "Не удалось подготовить запись.")
                    }
                    let message = NFCNDEFMessage(records: [record])
                    guard message.length <= capacity else { return fail(session, .tooSmall, message: "На метке недостаточно места.") }
                    tag.writeNDEF(message) { [self] error in
                        guard error == nil else { return fail(session, .systemError, message: "Не удалось записать метку.") }
                        session.alertMessage = "Ссылка записана."
                        session.invalidate()
                        finish(.success(.empty))
                    }
                }
            }
        }
    }

    /// Only a Katana link is handed over; any other content is reported as `notKatana` and dropped.
    private static func result(from message: NFCNDEFMessage?) -> NFCReadResult {
        guard let message, !message.records.isEmpty else { return .empty }
        for record in message.records {
            if let url = record.wellKnownTypeURIPayload(), url.scheme == ConnectorURLRouter.scheme {
                return .actionLink(url)
            }
        }
        return .notKatana
    }
}

private final class ActiveRunners: @unchecked Sendable {
    private let lock = NSLock()
    private var runners: [ObjectIdentifier: AnyObject] = [:]

    func insert(_ runner: AnyObject) {
        lock.lock(); runners[ObjectIdentifier(runner)] = runner; lock.unlock()
    }

    func remove(_ runner: AnyObject) {
        lock.lock(); runners[ObjectIdentifier(runner)] = nil; lock.unlock()
    }
}

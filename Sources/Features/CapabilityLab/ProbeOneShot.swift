import Foundation

/// Bridges a single system callback to async/await. Resolves exactly once — by the
/// callback, an error or cancellation — whichever comes first; later calls are ignored.
final class ProbeOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    func resolve(_ newResult: Result<Void, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: newResult)
    }

    var isResolved: Bool {
        lock.lock(); defer { lock.unlock() }
        return result != nil
    }
}

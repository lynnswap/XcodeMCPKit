import Foundation

final class DocumentationSearchActionPreparationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    func install(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        let result = self.result
        if result == nil {
            self.continuation = continuation
        }
        lock.unlock()
        if let result {
            continuation.resume(with: result)
        }
    }

    func complete(_ result: Result<URL, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

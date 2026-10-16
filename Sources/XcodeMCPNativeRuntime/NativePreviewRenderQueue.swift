import Foundation

@MainActor
final class NativePreviewRenderQueue {
    private struct Waiter {
        let identifier: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var workspaces: [String: [Waiter]] = [:]

    func withAccess<Output: Sendable>(to workspace: String,
                                      operation: @escaping @MainActor @Sendable () async throws -> Output) async throws -> Output {
        try Task.checkCancellation()
        if workspaces[workspace] == nil {
            workspaces[workspace] = []
        } else {
            let identifier = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { workspaces[workspace, default: []].append(Waiter(identifier: identifier, continuation: continuation)) }
                }
            } onCancel: {
                Task { @MainActor in
                    guard let index = self.workspaces[workspace]?.firstIndex(where: { $0.identifier == identifier }) else { return }
                    let waiter = self.workspaces[workspace]!.remove(at: index)
                    waiter.continuation.resume(throwing: CancellationError())
                }
            }
        }
        defer {
            if let waiter = workspaces[workspace]?.first {
                workspaces[workspace]!.removeFirst()
                waiter.continuation.resume()
            } else { workspaces[workspace] = nil }
        }
        try Task.checkCancellation()
        return try await operation()
    }
}

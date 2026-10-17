#if canImport(Darwin)
import Darwin
import Dispatch
import Foundation
import Synchronization

package enum PreviewRendererFileEvents {
    package enum Event: Sendable {
        case changed
        case invalidated
    }

    private final class Completion: Sendable {
        let group = DispatchGroup()
        let status = Mutex<Int32>(0)
    }

    @MainActor
    package static func withEvents<Output>(in directory: URL,
        operation: @MainActor (AsyncStream<Event>, AsyncStream<Event>.Continuation) async throws -> Output) async throws -> Output {
        let descriptor = unsafe Darwin.open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: directory.path])
        }
        let events = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let completion = Completion()
        completion.group.enter()
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke], queue: .global(qos: .userInitiated))
        source.setEventHandler { @Sendable [weak source] in
            guard let source else { return }
            if source.data.intersection([.delete, .rename, .revoke]).isEmpty {
                events.continuation.yield(.changed)
            } else {
                events.continuation.yield(.invalidated)
                events.continuation.finish()
                source.cancel()
            }
        }
        // A publication before kernel registration is found by the next current-file read.
        source.setRegistrationHandler { @Sendable in events.continuation.yield(.changed) }
        source.setCancelHandler { @Sendable in
            let status = Darwin.close(descriptor)
            let code = status == 0 ? 0 : errno
            completion.status.withLock { $0 = code }
            completion.group.leave()
        }
        events.continuation.onTermination = { [weak source] _ in source?.cancel() }
        source.activate()
        let result: Result<Output, any Error>
        do { result = .success(try await operation(events.stream, events.continuation)) }
        catch { result = .failure(error) }
        events.continuation.finish()
        source.cancel()
        // A checked continuation still joins cancellation when the rendering task is already cancelled.
        let closeError: Int32 = await withCheckedContinuation { continuation in
            completion.group.notify(queue: .global(qos: .userInitiated)) { @Sendable in
                continuation.resume(returning: completion.status.withLock { $0 })
            }
        }
        if closeError != 0 {
            var information: [String: Any] = [NSFilePathErrorKey: directory.path]
            if case .failure(let failure) = result {
                information[NSUnderlyingErrorKey] = failure
                information[NSLocalizedDescriptionKey] = "\(failure); closing the preview directory event descriptor failed (errno \(closeError))"
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(closeError), userInfo: information)
        }
        return try result.get()
    }
}
#endif

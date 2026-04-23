import Foundation

package actor ManagedUpstreamSlot: UpstreamSlotControlling {
    private final class StartAttempt: @unchecked Sendable {
        let task: Task<any UpstreamSession, Error>

        init(task: Task<any UpstreamSession, Error>) {
            self.task = task
        }
    }

    private final class RunningSessionBox: @unchecked Sendable {
        let session: any UpstreamSession
        var eventTask: Task<Void, Never>?

        init(session: any UpstreamSession) {
            self.session = session
        }
    }

    package nonisolated let events: AsyncStream<UpstreamEvent>
    private let continuation: AsyncStream<UpstreamEvent>.Continuation
    private let factory: any UpstreamSessionFactory
    private var pendingStart: StartAttempt?
    private var current: RunningSessionBox?
    private var isShutdown = false

    package init(
        factory: any UpstreamSessionFactory,
        startImmediately: Bool = false
    ) {
        self.factory = factory

        var streamContinuation: AsyncStream<UpstreamEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation

        if startImmediately {
            Task { [weak self] in
                await self?.start()
            }
        }
    }

    package func start() async {
        beginStartIfNeeded()
    }

    package func stop() async {
        isShutdown = true

        let running = current
        current = nil

        let pending = pendingStart
        pendingStart = nil
        pending?.task.cancel()

        continuation.finish()

        if let running {
            await running.session.stop()
        }
    }

    package func send(_ data: Data) async -> UpstreamSendResult {
        guard !isShutdown else {
            return .overloaded
        }

        if let current {
            return await current.session.send(data)
        }

        guard let pendingStart else {
            return .overloaded
        }

        do {
            let session = try await pendingStart.task.value
            guard let running = await claimStartedSessionIfNeeded(
                session: session,
                attempt: pendingStart
            ) else {
                return .overloaded
            }
            return await running.session.send(data)
        } catch {
            return .overloaded
        }
    }

    private func beginStartIfNeeded() {
        guard !isShutdown, current == nil, pendingStart == nil else {
            return
        }

        let attempt = StartAttempt(
            task: Task {
                try await factory.startSession()
            }
        )
        pendingStart = attempt

        Task { [weak self, attempt] in
            await self?.finishStartAttempt(attempt)
        }
    }

    private func finishStartAttempt(_ attempt: StartAttempt) async {
        do {
            let session = try await attempt.task.value
            _ = await claimStartedSessionIfNeeded(session: session, attempt: attempt)
        } catch {
            guard pendingStart === attempt else {
                return
            }
            pendingStart = nil
        }
    }

    private func claimStartedSessionIfNeeded(
        session: any UpstreamSession,
        attempt: StartAttempt
    ) async -> RunningSessionBox? {
        if let current {
            return current.session === session ? current : nil
        }

        guard pendingStart === attempt else {
            await session.stop()
            return nil
        }
        pendingStart = nil

        guard !isShutdown else {
            await session.stop()
            return nil
        }

        let running = RunningSessionBox(session: session)
        current = running
        running.eventTask = Task { [weak self, running] in
            for await event in session.events {
                await self?.handleSessionEvent(event, from: running)
            }
            await self?.handleSessionStreamFinished(from: running)
        }
        return running
    }

    private func handleSessionEvent(
        _ event: UpstreamEvent,
        from running: RunningSessionBox
    ) {
        guard current === running else {
            return
        }

        continuation.yield(event)

        switch event {
        case .stdoutProtocolViolation, .exit:
            current = nil
        case .message, .stderr, .stdoutBufferSize:
            break
        }
    }

    private func handleSessionStreamFinished(from running: RunningSessionBox) {
        guard current === running else {
            return
        }
        current = nil
    }
}

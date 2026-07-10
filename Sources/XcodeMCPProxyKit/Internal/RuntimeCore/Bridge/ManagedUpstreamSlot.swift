import XcodeMCPKit
import Foundation

actor ManagedUpstreamSlot: UpstreamSlotControlling {
    private final class StartAttempt: @unchecked Sendable {
        let task: Task<any UpstreamSession, Error>
        var settlementTask: Task<Void, Never>?
        var unclaimedSessionStopTask: Task<Void, Never>?

        init(task: Task<any UpstreamSession, Error>) {
            self.task = task
        }
    }

    private final class RunningSessionBox: @unchecked Sendable {
        let session: any UpstreamSession
        var eventTask: Task<Void, Never>?
        var stopTask: Task<Void, Never>?
        var streamFinished = false
        var stopFinished = false

        init(session: any UpstreamSession) {
            self.session = session
        }
    }

    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let factory: any UpstreamSessionFactory
    private var pendingStart: StartAttempt?
    private var current: RunningSessionBox?
    private var sessions: [ObjectIdentifier: RunningSessionBox] = [:]
    private var isShutdown = false
    private var stopTask: Task<Void, Never>?

    init(factory: any UpstreamSessionFactory) {
        self.factory = factory

        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {
        beginStartIfNeeded()
    }

    func stop() async {
        let stopTask = beginStopIfNeeded()
        await stopTask.value
    }

    private func beginStopIfNeeded() -> Task<Void, Never> {
        if let stopTask {
            return stopTask
        }
        isShutdown = true
        let stopTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performStop()
        }
        self.stopTask = stopTask
        return stopTask
    }

    private func performStop() async {
        current = nil

        let pending = pendingStart
        pendingStart = nil
        pending?.task.cancel()
        let pendingSettlementTask = pending?.settlementTask

        continuation.finish()

        let runningSessions = Array(sessions.values)
        let stopOperations = runningSessions.map { running in
            (running, startStopIfNeeded(running))
        }
        let eventTasks = runningSessions.compactMap(\.eventTask)
        for eventTask in eventTasks {
            eventTask.cancel()
        }
        for (running, stopTask) in stopOperations {
            await stopTask.value
            markStopFinished(running)
        }
        for eventTask in eventTasks {
            await eventTask.value
        }
        await pendingSettlementTask?.value
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        guard !isShutdown else {
            return .unavailable(.shuttingDown)
        }

        if let current {
            return await current.session.send(data)
        }

        guard let pendingStart else {
            return .unavailable(.notStarted)
        }

        do {
            let session = try await pendingStart.task.value
            guard let running = await claimStartedSessionIfNeeded(
                session: session,
                attempt: pendingStart
            ) else {
                return .unavailable(.notStarted)
            }
            return await running.session.send(data)
        } catch {
            if self.pendingStart === pendingStart {
                self.pendingStart = nil
            }
            return .unavailable(.startFailed)
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

        attempt.settlementTask = Task { [weak self, attempt] in
            await self?.finishStartAttempt(attempt)
        }
    }

    private func finishStartAttempt(_ attempt: StartAttempt) async {
        defer { attempt.settlementTask = nil }
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
            await stopUnclaimedSessionIfNeeded(session, attempt: attempt)
            return nil
        }
        pendingStart = nil

        guard !isShutdown else {
            await stopUnclaimedSessionIfNeeded(session, attempt: attempt)
            return nil
        }

        let running = RunningSessionBox(session: session)
        current = running
        sessions[ObjectIdentifier(running)] = running
        running.eventTask = Task { [weak self, running] in
            for await event in session.events {
                await self?.handleSessionEvent(event, from: running)
            }
            await self?.handleSessionStreamFinished(from: running)
        }
        return running
    }

    private func handleSessionEvent(
        _ event: Upstream.Event,
        from running: RunningSessionBox
    ) async {
        guard current === running else {
            return
        }

        if case .message(let data) = event,
            Self.isTopLevelJSONArray(data)
        {
            current = nil
            continuation.yield(
                .stdoutProtocolViolation(Self.unexpectedTopLevelArrayViolation(data))
            )
            let stopTask = startStopIfNeeded(running)
            await stopTask.value
            markStopFinished(running)
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
        if current === running {
            current = nil
        }
        running.streamFinished = true
        running.eventTask = nil
        removeSessionIfFinished(running)
    }

    private func startStopIfNeeded(_ running: RunningSessionBox) -> Task<Void, Never> {
        if let stopTask = running.stopTask {
            return stopTask
        }
        let session = running.session
        let stopTask = Task {
            await session.stop()
        }
        running.stopTask = stopTask
        return stopTask
    }

    private func markStopFinished(_ running: RunningSessionBox) {
        running.stopFinished = true
        removeSessionIfFinished(running)
    }

    private func removeSessionIfFinished(_ running: RunningSessionBox) {
        guard running.streamFinished,
            running.stopTask == nil || running.stopFinished
        else {
            return
        }
        running.stopTask = nil
        sessions.removeValue(forKey: ObjectIdentifier(running))
    }

    private func stopUnclaimedSessionIfNeeded(
        _ session: any UpstreamSession,
        attempt: StartAttempt
    ) async {
        let stopTask: Task<Void, Never>
        if let existing = attempt.unclaimedSessionStopTask {
            stopTask = existing
        } else {
            stopTask = Task {
                await session.stop()
            }
            attempt.unclaimedSessionStopTask = stopTask
        }
        await stopTask.value
    }

    private static func isTopLevelJSONArray(_ data: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return false
        }
        return value is [Any]
    }

    private static func unexpectedTopLevelArrayViolation(
        _ data: Data
    ) -> StdioFramer.ProtocolViolation {
        let previewData = data.prefix(200)
        return StdioFramer.ProtocolViolation(
            reason: .unexpectedTopLevelArray,
            bufferedByteCount: data.count,
            preview: String(decoding: previewData, as: UTF8.self),
            previewHex: previewData.map { byte in
                let digits = String(byte, radix: 16)
                return byte < 0x10 ? "0\(digits)" : digits
            }.joined(),
            leadingByteHex: "5b"
        )
    }
}

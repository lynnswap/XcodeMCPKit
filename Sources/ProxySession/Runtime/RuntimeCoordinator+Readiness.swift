import Foundation
import ProxyCore

extension RuntimeCoordinator {
    static func defaultUpstreamReadinessGate(
        config: ProxyConfig,
        clock: ClockClient
    ) -> UpstreamReadinessGate {
        guard isDefaultXcrunMCPBridgeInvocation(config: config) else {
            return .alwaysReady(uptimeNanoseconds: clock.uptimeNanoseconds)
        }

        let processRunner = ProcessRunner()
        return .xcodeMCPBridge(
            uptimeNanoseconds: clock.uptimeNanoseconds,
            sleepNanoseconds: { nanoseconds in
                try? await Task.sleep(nanoseconds: nanoseconds)
            },
            runProcess: { request in
                try await processRunner.run(request)
            }
        )
    }

    func runWhenUpstreamReady(
        reason: String,
        applyBackoff: Bool = false,
        token: UpstreamReadinessWaiterToken? = nil,
        operation: @escaping @Sendable () -> Void
    ) {
        guard upstreamReadinessGate.isEnabled else {
            operation()
            return
        }

        let generation = currentUpstreamReadinessGeneration()
        let guardedOperation: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            guard self.currentUpstreamReadinessGeneration() == generation else { return }
            operation()
        }
        Task { [upstreamReadinessCoordinator] in
            await upstreamReadinessCoordinator.runWhenReady(
                reason: reason,
                applyBackoff: applyBackoff,
                token: token,
                operation: guardedOperation
            )
        }
    }

    func cancelUpstreamReadinessWaiter(_ token: UpstreamReadinessWaiterToken) {
        guard upstreamReadinessGate.isEnabled else { return }
        Task { [upstreamReadinessCoordinator] in
            await upstreamReadinessCoordinator.cancelWaiter(token)
        }
    }

    func startAllUpstreamSlots() {
        for upstream in upstreams {
            Task {
                await upstream.start()
            }
        }
    }

    func noteUpstreamInitializationSucceeded() {
        guard upstreamReadinessGate.isEnabled else { return }
        Task { [upstreamReadinessCoordinator] in
            await upstreamReadinessCoordinator.resetBackoff()
        }
    }

    func resetUpstreamReadinessWaiters() {
        guard upstreamReadinessGate.isEnabled else { return }
        Task { [upstreamReadinessCoordinator] in
            await upstreamReadinessCoordinator.reset()
        }
    }

    func advanceUpstreamReadinessGeneration() {
        upstreamReadinessGenerationBox.withLockedValue { generation in
            generation &+= 1
        }
    }

    func currentUpstreamReadinessGeneration() -> UInt64 {
        upstreamReadinessGenerationBox.withLockedValue { $0 }
    }

    func replacePrimaryInitializeReadinessWaiter(
        with token: UpstreamReadinessWaiterToken
    ) {
        let previous = primaryInitializeReadinessTokenBox.withLockedValue { current in
            let previous = current
            current = token
            return previous
        }
        if let previous {
            cancelUpstreamReadinessWaiter(previous)
        }
    }

    func clearPrimaryInitializeReadinessWaiter(
        _ token: UpstreamReadinessWaiterToken
    ) {
        primaryInitializeReadinessTokenBox.withLockedValue { current in
            if current === token {
                current = nil
            }
        }
    }

    func cancelPrimaryInitializeReadinessWaiter() {
        let token = primaryInitializeReadinessTokenBox.withLockedValue { current in
            let token = current
            current = nil
            return token
        }
        if let token {
            cancelUpstreamReadinessWaiter(token)
        }
    }

    package static func isDefaultXcrunMCPBridgeInvocation(config: ProxyConfig) -> Bool {
        guard isXcrunCommand(config.upstreamCommand),
              let toolName = firstXcrunToolName(from: config.upstreamArgs) else {
            return false
        }
        return URL(fileURLWithPath: toolName).lastPathComponent == "mcpbridge"
    }

    private static func isXcrunCommand(_ command: String) -> Bool {
        command == "xcrun" || URL(fileURLWithPath: command).lastPathComponent == "xcrun"
    }

    private static func firstXcrunToolName(from args: [String]) -> String? {
        let flagsWithValues: Set<String> = [
            "-sdk", "--sdk",
            "-toolchain", "--toolchain",
        ]

        var index = 0
        while index < args.count {
            let argument = args[index]
            if flagsWithValues.contains(argument) {
                index += 2
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            return argument
        }

        return nil
    }
}

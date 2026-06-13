package enum ProxyCLIFlag: String, CaseIterable, Sendable {
    case helpShort = "-h"
    case help = "--help"
    case version = "--version"
    case config = "--config"
    case autoApprove = "--auto-approve"
    case listen = "--listen"
    case host = "--host"
    case port = "--port"
    case maxBodyBytes = "--max-body-bytes"
    case requestTimeout = "--request-timeout"
    case upstreamCommand = "--upstream-command"
    case upstreamArgs = "--upstream-args"
    case upstreamArg = "--upstream-arg"
    case upstreamProcesses = "--upstream-processes"
    case sessionID = "--session-id"
    case refreshCodeIssuesMode = "--refresh-code-issues-mode"
    case stdio = "--stdio"
    case url = "--url"
    case printURL = "--print-url"
    case lazyInit = "--lazy-init"
    case xcodePID = "--xcode-pid"
    case dryRun = "--dry-run"
    case forceRestart = "--force-restart"
    case prefix = "--prefix"
    case bindir = "--bindir"

    package var consumesRequiredValue: Bool {
        switch self {
        case .config, .listen, .host, .port, .maxBodyBytes, .requestTimeout,
             .upstreamCommand, .upstreamArgs, .upstreamArg, .upstreamProcesses,
             .sessionID, .refreshCodeIssuesMode, .prefix, .bindir:
            return true
        case .helpShort, .help, .version, .autoApprove, .stdio, .url, .printURL,
             .lazyInit, .xcodePID, .dryRun, .forceRestart:
            return false
        }
    }

    package var isServerOnlyForAdapter: Bool {
        switch self {
        case .config, .autoApprove, .listen, .host, .port, .maxBodyBytes,
             .upstreamCommand, .upstreamArgs, .upstreamArg, .upstreamProcesses,
             .sessionID, .refreshCodeIssuesMode:
            return true
        case .helpShort, .help, .version, .requestTimeout, .stdio, .url, .printURL,
             .lazyInit, .xcodePID, .dryRun, .forceRestart, .prefix, .bindir:
            return false
        }
    }

    package var isForwardedByServerCommand: Bool {
        switch self {
        case .config, .listen, .host, .port, .upstreamCommand, .upstreamArgs,
             .upstreamArg, .upstreamProcesses, .sessionID, .maxBodyBytes,
             .requestTimeout, .refreshCodeIssuesMode:
            return true
        case .helpShort, .help, .version, .autoApprove, .stdio, .url, .printURL,
             .lazyInit, .xcodePID, .dryRun, .forceRestart, .prefix, .bindir:
            return false
        }
    }

    package var isServerForwardedValueFlag: Bool {
        isForwardedByServerCommand && consumesRequiredValue
    }

    package static let serverOnlyFlagNames = Set(
        allCases.filter(\.isServerOnlyForAdapter).map(\.rawValue)
    )

    package static let serverOnlyValueFlagNames = Set(
        allCases.filter { $0.isServerOnlyForAdapter && $0.consumesRequiredValue }
            .map(\.rawValue)
    )

    package static let serverForwardedValueFlagNames = Set(
        allCases.filter(\.isServerForwardedValueFlag).map(\.rawValue)
    )
}

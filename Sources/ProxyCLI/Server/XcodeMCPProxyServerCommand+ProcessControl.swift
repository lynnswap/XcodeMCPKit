extension XcodeMCPProxyServerCommand {
    package static func hostMatches(requestedHost: String, actualHost: String) -> Bool {
        ExistingProxyServerClient.hostMatches(
            requestedHost: requestedHost,
            actualHost: actualHost
        )
    }

    package static func listeningPIDs(fromLsofOutput output: String, matchingHost host: String) -> [Int] {
        ExistingProxyServerClient.listeningPIDs(
            fromLsofOutput: output,
            matchingHost: host
        )
    }
}

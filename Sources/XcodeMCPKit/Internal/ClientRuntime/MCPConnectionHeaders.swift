package struct MCPConnectionHeaders: Sendable, Equatable {
    package var sessionID: String?
    package var protocolVersion: String?

    package init(sessionID: String? = nil, protocolVersion: String? = nil) {
        self.sessionID = sessionID
        self.protocolVersion = protocolVersion
    }
}


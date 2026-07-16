import NIOConcurrencyHelpers
import Testing

@testable import XcodeMCPProxyRuntime

@Suite
struct SessionRegistryTests {
    @Test func idleSessionExpiresAtGraceBoundaryAndReportsClosure() {
        let clock = NIOLockedValueBox<UInt64>(0)
        let closedSessionIDs = NIOLockedValueBox<[String]>([])
        let registry = SessionRegistry(
            configuration: makeConfig(requestTimeout: 5),
            sessionClosedSink: { sessionID in
                closedSessionIDs.withLockedValue { $0.append(sessionID) }
            },
            nowUptimeNanoseconds: { clock.withLockedValue { $0 } }
        )
        _ = registry.session(id: "idle")
        #expect(registry.sessionStateAndTouch(id: "idle") == .uninitialized)

        clock.withLockedValue { $0 = 99 }
        #expect(registry.removeInactiveSessions(inactiveForNanoseconds: 100).isEmpty)
        #expect(registry.hasSession(id: "idle"))

        clock.withLockedValue { $0 = 100 }
        #expect(registry.removeInactiveSessions(inactiveForNanoseconds: 100) == ["idle"])
        #expect(registry.hasSession(id: "idle") == false)
        #expect(closedSessionIDs.withLockedValue { $0 } == ["idle"])
    }

    @Test func clientActivityRestartsTheInactivityGracePeriod() {
        let clock = NIOLockedValueBox<UInt64>(0)
        let registry = SessionRegistry(
            configuration: makeConfig(requestTimeout: 5),
            nowUptimeNanoseconds: { clock.withLockedValue { $0 } }
        )
        _ = registry.session(id: "reconnecting")
        registry.markInitialized(
            id: "reconnecting",
            negotiatedProtocolVersion: "2025-06-18"
        )

        clock.withLockedValue { $0 = 99 }
        #expect(
            registry.sessionStateAndTouch(id: "reconnecting")
                == .initialized(protocolVersion: "2025-06-18")
        )

        clock.withLockedValue { $0 = 198 }
        #expect(registry.removeInactiveSessions(inactiveForNanoseconds: 100).isEmpty)
        clock.withLockedValue { $0 = 199 }
        #expect(
            registry.removeInactiveSessions(inactiveForNanoseconds: 100)
                == ["reconnecting"]
        )
    }

    @Test func inFlightRequestPreventsExpiryUntilCompletion() {
        let clock = NIOLockedValueBox<UInt64>(0)
        let registry = SessionRegistry(
            configuration: makeConfig(requestTimeout: 5),
            nowUptimeNanoseconds: { clock.withLockedValue { $0 } }
        )

        #expect(registry.beginClientRequest(id: "request", createIfMissing: true))
        clock.withLockedValue { $0 = 500 }
        #expect(registry.removeInactiveSessions(inactiveForNanoseconds: 100).isEmpty)

        registry.endClientRequest(id: "request")
        clock.withLockedValue { $0 = 599 }
        #expect(registry.removeInactiveSessions(inactiveForNanoseconds: 100).isEmpty)
        clock.withLockedValue { $0 = 600 }
        #expect(registry.removeInactiveSessions(inactiveForNanoseconds: 100) == ["request"])
    }

    @Test func everyOpenEventStreamMustCloseBeforeExpiry() {
        let clock = NIOLockedValueBox<UInt64>(0)
        let registry = SessionRegistry(
            configuration: makeConfig(requestTimeout: 5),
            nowUptimeNanoseconds: { clock.withLockedValue { $0 } }
        )
        _ = registry.session(id: "streams")
        #expect(registry.openEventStream(id: "streams"))
        #expect(registry.openEventStream(id: "streams"))

        clock.withLockedValue { $0 = 200 }
        #expect(registry.removeInactiveSessions(inactiveForNanoseconds: 100).isEmpty)
        registry.closeEventStream(id: "streams")

        clock.withLockedValue { $0 = 400 }
        #expect(registry.removeInactiveSessions(inactiveForNanoseconds: 100).isEmpty)
        registry.closeEventStream(id: "streams")

        clock.withLockedValue { $0 = 499 }
        #expect(registry.removeInactiveSessions(inactiveForNanoseconds: 100).isEmpty)
        clock.withLockedValue { $0 = 500 }
        #expect(registry.removeInactiveSessions(inactiveForNanoseconds: 100) == ["streams"])
    }

    @Test func outboundTargetEnumerationDoesNotExtendSessionLifetime() {
        let clock = NIOLockedValueBox<UInt64>(0)
        let registry = SessionRegistry(
            configuration: makeConfig(requestTimeout: 5),
            nowUptimeNanoseconds: { clock.withLockedValue { $0 } }
        )
        _ = registry.session(id: "outbound-only")
        #expect(registry.sessionStateAndTouch(id: "outbound-only") == .uninitialized)
        registry.markInitialized(id: "outbound-only", negotiatedProtocolVersion: nil)

        clock.withLockedValue { $0 = 99 }
        #expect(registry.initializedNotificationTargets().map(\.id) == ["outbound-only"])
        clock.withLockedValue { $0 = 100 }
        #expect(
            registry.removeInactiveSessions(inactiveForNanoseconds: 100)
                == ["outbound-only"]
        )
    }

    @Test func internalRuntimeSessionDoesNotParticipateInClientInactivityExpiry() {
        let clock = NIOLockedValueBox<UInt64>(0)
        let registry = SessionRegistry(
            configuration: makeConfig(requestTimeout: 5),
            nowUptimeNanoseconds: { clock.withLockedValue { $0 } }
        )
        _ = registry.session(id: "internal-control-plane")

        clock.withLockedValue { $0 = 1_000 }
        #expect(registry.removeInactiveSessions(inactiveForNanoseconds: 100).isEmpty)
        #expect(registry.hasSession(id: "internal-control-plane"))
    }
}

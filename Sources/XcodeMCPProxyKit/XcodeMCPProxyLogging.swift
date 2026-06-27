import Logging

package enum XcodeMCPProxyLogging {
    package static func bootstrap(environment: [String: String]) {
        ProxyLogging.bootstrap(environment: environment)
    }

    package static func make(_ label: String) -> Logger {
        ProxyLogging.make(label)
    }
}

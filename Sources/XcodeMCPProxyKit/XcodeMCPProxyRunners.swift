import Foundation

extension XcodeMCPProxyServer {
    /// Runs the `xcode-mcp-proxy-server` command-line facade.
    ///
    /// This helper parses the same arguments and environment accepted by the
    /// executable, executes the normalized launch plan, and returns a
    /// process-style exit code. Output that belongs on standard output or
    /// standard error is delivered through the supplied callbacks. Hosts that
    /// want swift-log output should configure logging before calling this
    /// method.
    ///
    /// - Parameters:
    ///   - arguments: Command-line arguments, including the executable name.
    ///   - environment: Environment variables used for launch resolution.
    ///   - stdout: Callback for standard output lines.
    ///   - stderr: Callback for standard error lines.
    /// - Returns: `0` for success, or a nonzero exit code for launch or
    ///   validation failures.
    public static func run(
        arguments: [String],
        environment: [String: String],
        stdout: @escaping @Sendable (String) -> Void,
        stderr: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        return await Launcher().run(
            arguments: arguments,
            environment: environment,
            stdout: stdout,
            stderr: stderr
        )
    }
}

extension XcodeMCPProxyStdioAdapter {
    /// Runs the `xcode-mcp-proxy` STDIO adapter command-line facade.
    ///
    /// This helper parses the same arguments and environment accepted by the
    /// executable, resolves the Streamable HTTP endpoint, starts the adapter
    /// when requested, and returns a process-style exit code. Display output is
    /// sent to `stdout`; validation and launch errors are sent to `stderr`.
    /// Hosts that want swift-log output should configure logging before calling
    /// this method.
    ///
    /// - Parameters:
    ///   - arguments: Command-line arguments, including the executable name.
    ///   - environment: Environment variables used for endpoint resolution.
    ///   - stdout: Callback for standard output lines.
    ///   - stderr: Callback for standard error lines.
    /// - Returns: `0` for success, or a nonzero exit code for launch or
    ///   validation failures.
    public static func run(
        arguments: [String],
        environment: [String: String],
        stdout: @escaping @Sendable (String) -> Void,
        stderr: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        return await Launcher().run(
            arguments: arguments,
            environment: environment,
            stdout: stdout,
            stderr: stderr
        )
    }
}

extension XcodeMCPProxyInstaller {
    /// Runs the `xcode-mcp-proxy-install` command-line facade.
    ///
    /// This helper parses the same arguments and environment accepted by the
    /// executable, executes the normalized install plan, and returns a
    /// process-style exit code. Output that belongs on standard output or
    /// standard error is delivered through the supplied callbacks.
    ///
    /// - Parameters:
    ///   - arguments: Command-line arguments, including the executable name.
    ///   - environment: Environment variables used for install resolution.
    ///   - stdout: Callback for standard output lines.
    ///   - stderr: Callback for standard error lines.
    /// - Returns: `0` for success, or a nonzero exit code for launch or
    ///   validation failures.
    public static func run(
        arguments: [String],
        environment: [String: String],
        stdout: @escaping @Sendable (String) -> Void,
        stderr: @escaping @Sendable (String) -> Void
    ) -> Int32 {
        Launcher().run(
            arguments: arguments,
            environment: environment,
            stdout: stdout,
            stderr: stderr
        )
    }
}

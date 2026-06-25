extension XcodeMCPProxyServerCommand {
    package struct Runtime {
        private let dependencies: XcodeMCPProxyServerCommand.Dependencies

        package init(dependencies: XcodeMCPProxyServerCommand.Dependencies) {
            self.dependencies = dependencies
        }

        package func execute(args: [String], environment: [String: String]) async -> Int32 {
            await dependencies.launch(args, environment, dependencies.stdout, dependencies.stderr)
        }
    }
}

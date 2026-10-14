// Xcode stores MainActor closures without Swift 6's inferred Sendable flag.
// The same toolchain's Swift 5 mode preserves that native metadata identity.
package typealias WorkspaceCallback = @MainActor () -> Void

@MainActor
package func optionalWorkspaceCallback(_ callback: @escaping WorkspaceCallback) -> WorkspaceCallback? { callback }

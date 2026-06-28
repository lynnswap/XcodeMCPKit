// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .strictMemorySafety(),
]

let package = Package(
    name: "XcodeMCPKit",
    platforms: [
        .macOS("15.4")
    ],
    products: [
        .library(
            name: "XcodeMCPKit",
            targets: ["XcodeMCPKit"]
        ),
        .library(
            name: "XcodeMCPKitTesting",
            targets: ["XcodeMCPKitTesting"]
        ),
        .library(
            name: "XcodeMCPProxyKit",
            targets: ["XcodeMCPProxyKit"]
        ),
        .executable(
            name: "xcode-mcp-proxy",
            targets: ["XcodeMCPProxyCLI"]
        ),
        .executable(
            name: "xcode-mcp-proxy-server",
            targets: ["XcodeMCPProxyServer"]
        ),
        .executable(
            name: "xcode-mcp-proxy-install",
            targets: ["XcodeMCPProxyInstall"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder.git", from: "0.4.3"),
    ],
    targets: [
        .target(
            name: "XcodeMCPCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            path: "Sources/XcodeMCPCore",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPProcessRuntime",
            dependencies: [
                "XcodeMCPCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            path: "Sources/XcodeMCPProcessRuntime",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPClientRuntime",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
            ],
            path: "Sources/XcodeMCPClientRuntime",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPProxyRuntime",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            path: "Sources/XcodeMCPProxyRuntime",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPKit",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPClientRuntime",
            ],
            path: "Sources/XcodeMCPKit",
            exclude: ["README.md"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPKitTesting",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPClientRuntime",
                "XcodeMCPKit",
            ],
            path: "Sources/XcodeMCPKitTesting",
            exclude: ["README.md"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPProxyKit",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                "XcodeMCPProxyRuntime",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            exclude: ["README.md"],
            swiftSettings: strictSwiftSettings,
            plugins: [
                .plugin(name: "ProxyBuildInfoPlugin"),
            ]
        ),
        .target(
            name: "XcodeMCPProxyTestSupport",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                "XcodeMCPProxyKit",
                "XcodeMCPProxyRuntime",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            path: "Tests/XcodeMCPProxyTestSupport",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPRuntimeTestSupport",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            path: "Tests/XcodeMCPRuntimeTestSupport",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPProxyRuntimeTestSupport",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                "XcodeMCPProxyKit",
                "XcodeMCPProxyRuntime",
                "XcodeMCPProxyTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            path: "Tests/XcodeMCPProxyRuntimeTestSupport",
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPProxyCLI",
            dependencies: [
                "XcodeMCPProxyKit"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPProxyServer",
            dependencies: ["XcodeMCPProxyKit"],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPProxyInstall",
            dependencies: ["XcodeMCPProxyKit"],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "ProxyBuildInfoTool",
            swiftSettings: strictSwiftSettings
        ),
        .plugin(
            name: "ProxyBuildInfoPlugin",
            capability: .buildTool(),
            dependencies: ["ProxyBuildInfoTool"]
        ),
        .testTarget(
            name: "XcodeMCPKitTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPClientRuntime",
                "XcodeMCPKit",
            ],
            path: "Tests/XcodeMCPKitTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "XcodeMCPKitTestingTests",
            dependencies: [
                "XcodeMCPKit",
                "XcodeMCPKitTesting",
            ],
            path: "Tests/XcodeMCPKitTestingTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "XcodeMCPRuntimeTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                "XcodeMCPProxyRuntime",
                "XcodeMCPRuntimeTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            path: "Tests/XcodeMCPRuntimeTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "PublicProductContractTests",
            dependencies: [],
            path: "Tests/PublicProductContractTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyRuntimeCoordinatorTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                "XcodeMCPProxyKit",
                "XcodeMCPProxyTestSupport",
                "XcodeMCPProxyRuntime",
                "XcodeMCPProxyRuntimeTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyRuntimeCoordinatorTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyDocumentationProviderTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                "XcodeMCPProxyKit",
                "XcodeMCPProxyRuntime",
                "XcodeMCPProxyTestSupport",
                "XcodeMCPProxyRuntimeTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            path: "Tests/ProxyDocumentationProviderTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyToolSurfaceTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                "XcodeMCPProxyKit",
                "XcodeMCPProxyRuntime",
                "XcodeMCPProxyTestSupport",
                .product(name: "NIO", package: "swift-nio"),
            ],
            path: "Tests/ProxyToolSurfaceTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyStartupLoggingTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                "XcodeMCPProxyKit",
                "XcodeMCPProxyRuntime",
            ],
            path: "Tests/ProxyStartupLoggingTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "XcodeMCPRuntimeProcessTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                "XcodeMCPProxyRuntime",
                "XcodeMCPRuntimeTestSupport",
            ],
            path: "Tests/XcodeMCPRuntimeProcessTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyStdioAdapterTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                "XcodeMCPProxyKit",
                "XcodeMCPProxyTestSupport",
                "XcodeMCPProxyRuntime",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyStdioAdapterTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyStressTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                "XcodeMCPProxyKit",
                "XcodeMCPProxyTestSupport",
                "XcodeMCPProxyRuntime",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyStressTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyHTTPGatewayTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                "XcodeMCPProxyKit",
                "XcodeMCPProxyTestSupport",
                "XcodeMCPProxyRuntime",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyHTTPGatewayTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyCLITests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                "XcodeMCPProxyKit",
                "XcodeMCPProxyTestSupport",
                "XcodeMCPProxyRuntime",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyCLITests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyIntegrationTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                "XcodeMCPProxyKit",
                "XcodeMCPProxyTestSupport",
                "XcodeMCPProxyRuntime",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyIntegrationTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyLiveMCPBridgeTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPProcessRuntime",
                "XcodeMCPProxyKit",
                .product(name: "NIO", package: "swift-nio"),
            ],
            path: "Tests/ProxyLiveMCPBridgeTests",
            swiftSettings: strictSwiftSettings
        ),
    ]
)

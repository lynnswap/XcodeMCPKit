// swift-tools-version: 6.2
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
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "XcodeMCPKit",
            targets: ["XcodeMCPKit"]
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
            name: "ProxyBuildInfoSupport",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPKit",
            dependencies: [
                "XcodeMCPProxy"
            ],
            path: "Sources/XcodeMCPKit",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyCore",
            dependencies: [
                "ProxyMCP",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            path: "Sources/ProxyCore",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyMCP",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
            ],
            path: "Sources/ProxyMCP",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxySession",
            dependencies: [
                "ProxyCore",
                "ProxyMCP",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ],
            path: "Sources/ProxySession",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyXcodeSupport",
            dependencies: [
                "ProxyCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
            ],
            path: "Sources/ProxyXcodeSupport",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyXcodeFeatures",
            dependencies: [
                "ProxyCore",
                "ProxyMCP",
                "ProxyXcodeSupport",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
            ],
            path: "Sources/ProxyXcodeFeatures",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyHTTPGateway",
            dependencies: [
                "ProxyCore",
                "ProxyMCP",
                "ProxySession",
                "ProxyXcodeSupport",
                "ProxyXcodeFeatures",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            path: "Sources/ProxyHTTPGateway",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyStdioTransport",
            dependencies: [
                "ProxyCore",
                "ProxyMCP",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ProxyStdioTransport",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPProxy",
            dependencies: [
                "ProxyCore",
                "ProxyMCP",
                "ProxySession",
                "ProxyXcodeSupport",
                "ProxyXcodeFeatures",
                "ProxyHTTPGateway",
                "ProxyStdioTransport",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: strictSwiftSettings,
            plugins: [
                .plugin(name: "ProxyBuildInfoPlugin"),
            ]
        ),
        .target(
            name: "ProxyCLI",
            dependencies: [
                "XcodeMCPProxy",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ProxyCLI",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPTestSupport",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPProxyCLI",
            dependencies: [
                "ProxyCLI"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPProxyServer",
            dependencies: ["ProxyCLI"],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPProxyInstall",
            dependencies: ["ProxyCLI"],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "ProxyBuildInfoTool",
            dependencies: ["ProxyBuildInfoSupport"],
            swiftSettings: strictSwiftSettings
        ),
        .plugin(
            name: "ProxyBuildInfoPlugin",
            capability: .buildTool(),
            dependencies: ["ProxyBuildInfoTool"]
        ),
        .testTarget(
            name: "ProxyContractTests",
            dependencies: [
                "XcodeMCPProxy",
                "ProxyCore",
                "ProxyMCP",
                "ProxySession",
                "ProxyXcodeSupport",
                "ProxyXcodeFeatures",
                "ProxyHTTPGateway",
                "ProxyStdioTransport",
                "ProxyCLI",
                "XcodeMCPTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyContractTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyRuntimeTests",
            dependencies: [
                "XcodeMCPProxy",
                "ProxyCore",
                "ProxyMCP",
                "ProxySession",
                "ProxyXcodeSupport",
                "ProxyXcodeFeatures",
                "ProxyHTTPGateway",
                "ProxyStdioTransport",
                "ProxyCLI",
                "XcodeMCPTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyRuntimeTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyHTTPTransportTests",
            dependencies: [
                "XcodeMCPProxy",
                "ProxyCore",
                "ProxyMCP",
                "ProxySession",
                "ProxyXcodeSupport",
                "ProxyXcodeFeatures",
                "ProxyHTTPGateway",
                "ProxyStdioTransport",
                "ProxyCLI",
                "XcodeMCPTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyHTTPTransportTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyCLITests",
            dependencies: [
                "XcodeMCPProxy",
                "ProxyCore",
                "ProxyMCP",
                "ProxySession",
                "ProxyXcodeSupport",
                "ProxyXcodeFeatures",
                "ProxyHTTPGateway",
                "ProxyStdioTransport",
                "ProxyCLI",
                "XcodeMCPTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyCLITests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyBuildInfoSupportTests",
            dependencies: [
                "ProxyBuildInfoSupport",
            ],
            path: "Tests/ProxyBuildInfoSupportTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyIntegrationTests",
            dependencies: [
                "XcodeMCPProxy",
                "ProxyCore",
                "ProxyMCP",
                "ProxySession",
                "ProxyXcodeSupport",
                "ProxyXcodeFeatures",
                "ProxyHTTPGateway",
                "ProxyStdioTransport",
                "ProxyCLI",
                "XcodeMCPTestSupport",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyIntegrationTests",
            swiftSettings: strictSwiftSettings
        ),
    ]
)

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
            name: "ProxyBuildInfoSupport",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyBuildInfo",
            dependencies: [],
            path: "Sources/ProxyBuildInfo",
            swiftSettings: strictSwiftSettings,
            plugins: [
                .plugin(name: "ProxyBuildInfoPlugin"),
            ]
        ),
        .target(
            name: "ProxyMCPContract",
            dependencies: [],
            path: "Sources/ProxyMCPContract",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyCore",
            dependencies: [
                "ProxyMCPContract",
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
                "ProxyCore",
                .product(name: "NIO", package: "swift-nio"),
            ],
            path: "Sources/ProxyMCP",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxySessionUpstream",
            dependencies: [
                "ProxyCore",
                "ProxyMCP",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIO", package: "swift-nio"),
            ],
            path: "Sources/ProxySessionUpstream",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPKit",
            dependencies: [
                "ProxyCore",
                "ProxySessionUpstream",
            ],
            path: "Sources/XcodeMCPKit",
            exclude: ["README.md"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxySessionControlPlane",
            dependencies: [
                "ProxyCore",
                "ProxyMCP",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIO", package: "swift-nio"),
            ],
            path: "Sources/ProxySessionControlPlane",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxySession",
            dependencies: [
                "ProxyCore",
                "ProxyMCP",
                "ProxySessionControlPlane",
                "ProxySessionUpstream",
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
                "ProxySessionControlPlane",
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
            name: "XcodeMCPProxyKit",
            dependencies: [
                "ProxyBuildInfo",
                "ProxyCore",
                "ProxyMCP",
                "ProxySession",
                "ProxySessionControlPlane",
                "ProxyXcodeSupport",
                "ProxyXcodeFeatures",
                "ProxyHTTPGateway",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            exclude: ["README.md"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyCLICommon",
            dependencies: [
                "ProxyCore",
            ],
            path: "Sources/ProxyCLI/Common",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyAdapterCLI",
            dependencies: [
                "ProxyBuildInfo",
                "ProxyCLICommon",
                "ProxyCore",
                "ProxyStdioTransport",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ProxyCLI/Adapter",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyServerCLI",
            dependencies: [
                "ProxyBuildInfo",
                "ProxyCLICommon",
                "ProxyCore",
                "XcodeMCPProxyKit",
            ],
            path: "Sources/ProxyCLI/Server",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "ProxyInstallCLI",
            dependencies: [
                "ProxyBuildInfo",
                "ProxyCLICommon",
                "ProxyCore",
            ],
            path: "Sources/ProxyCLI/Install",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPTestSupport",
            dependencies: [
                "ProxySession",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            path: "Tests/XcodeMCPTestSupport",
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPProxyCLI",
            dependencies: [
                "ProxyAdapterCLI"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPProxyServer",
            dependencies: ["ProxyServerCLI"],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPProxyInstall",
            dependencies: ["ProxyInstallCLI"],
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
            name: "XcodeMCPKitTests",
            dependencies: [
                "XcodeMCPKit",
            ],
            path: "Tests/XcodeMCPKitTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "PublicProductContractTests",
            dependencies: [],
            path: "Tests/PublicProductContractTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyContractTests",
            dependencies: [
                "XcodeMCPProxyKit",
                "ProxyCore",
                "ProxyMCP",
                "ProxySession",
                "ProxySessionControlPlane",
                "ProxySessionUpstream",
                "ProxyXcodeSupport",
                "ProxyXcodeFeatures",
                "ProxyHTTPGateway",
                "ProxyStdioTransport",
                "ProxyAdapterCLI",
                "ProxyServerCLI",
                "XcodeMCPTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyContractTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxySessionTests",
            dependencies: [
                "XcodeMCPProxyKit",
                "ProxyCore",
                "ProxyMCP",
                "ProxySession",
                "ProxySessionControlPlane",
                "ProxySessionUpstream",
                "ProxyXcodeSupport",
                "ProxyXcodeFeatures",
                "ProxyHTTPGateway",
                "ProxyStdioTransport",
                "XcodeMCPTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxySessionTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyProcessTests",
            dependencies: [
                "XcodeMCPProxyKit",
                "ProxySession",
                "ProxySessionUpstream",
                "XcodeMCPTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyProcessTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyStressTests",
            dependencies: [
                "XcodeMCPProxyKit",
                "ProxyCore",
                "ProxySession",
                "ProxySessionUpstream",
                "ProxyHTTPGateway",
                "XcodeMCPTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ProxyStressTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ProxyHTTPGatewayTests",
            dependencies: [
                "XcodeMCPProxyKit",
                "ProxyCore",
                "ProxyMCP",
                "ProxySession",
                "ProxySessionControlPlane",
                "ProxySessionUpstream",
                "ProxyXcodeSupport",
                "ProxyXcodeFeatures",
                "ProxyHTTPGateway",
                "ProxyStdioTransport",
                "XcodeMCPTestSupport",
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
                "XcodeMCPProxyKit",
                "ProxyCore",
                "ProxyMCP",
                "ProxySession",
                "ProxySessionControlPlane",
                "ProxySessionUpstream",
                "ProxyXcodeSupport",
                "ProxyXcodeFeatures",
                "ProxyHTTPGateway",
                "ProxyStdioTransport",
                "ProxyBuildInfo",
                "ProxyAdapterCLI",
                "ProxyCLICommon",
                "ProxyInstallCLI",
                "ProxyServerCLI",
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
                "XcodeMCPProxyKit",
                "ProxyBuildInfo",
                "ProxyCore",
                "ProxyMCP",
                "ProxySession",
                "ProxySessionControlPlane",
                "ProxySessionUpstream",
                "ProxyXcodeSupport",
                "ProxyXcodeFeatures",
                "ProxyHTTPGateway",
                "ProxyStdioTransport",
                "XcodeMCPTestSupport",
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
                "XcodeMCPProxyKit",
                "ProxyCore",
                "ProxySessionUpstream",
                "ProxyXcodeSupport",
                .product(name: "NIO", package: "swift-nio"),
            ],
            path: "Tests/ProxyLiveMCPBridgeTests",
            swiftSettings: strictSwiftSettings
        ),
    ]
)

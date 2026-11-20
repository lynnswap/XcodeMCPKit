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
        .macOS("15.4"), .iOS("18.4"), .tvOS("18.4"), .watchOS("11.4"), .visionOS("2.4")
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
            name: "XcodeMCPServerKit",
            targets: ["XcodeMCPServerKit"]
        ),
        .executable(
            name: "xcode-mcp-server",
            targets: ["XcodeMCPServerCLI"]
        ),
        .executable(
            name: "xcode-mcp-install",
            targets: ["XcodeMCPInstallCLI"]
        ),
        .executable(
            name: "xcode-mcp-tool-verifier",
            targets: ["XcodeMCPToolVerifierCLI"]
        ),
        .executable(
            name: "xcode-mcp-native-host",
            targets: ["XcodeMCPNativeHost"]
        ),
        .library(name: "XcodeMCPPreviewRenderer", type: .static, targets: ["XcodeMCPPreviewRenderer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/lynnswap/ABIBridge.git", exact: "0.17.0"),
        .package(url: "https://github.com/p-x9/MachOKit.git", exact: "0.55.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "XcodeMCPWire", swiftSettings: strictSwiftSettings),
        .target(name: "XcodeMCPInstallation", swiftSettings: strictSwiftSettings),
        .testTarget(
            name: "XcodeMCPInstallationTests",
            dependencies: ["XcodeMCPInstallation"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPNativeSwiftABI",
            swiftSettings: [.swiftLanguageMode(.v5), .defaultIsolation(nil), .strictMemorySafety()]
        ),
        .target(
            name: "XcodeMCPNativeRuntime",
            dependencies: ["XcodeMCPInstallation", "XcodeMCPWire", "XcodeMCPNativeSwiftABI", .product(name: "ABIBridge", package: "ABIBridge"),
                           .product(name: "MachOKit", package: "MachOKit")],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPNativeHost",
            dependencies: ["XcodeMCPInstallation", "XcodeMCPNativeRuntime", "XcodeMCPWire"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPPreviewRenderer",
            dependencies: [
                "XcodeMCPWire",
                .product(name: "ABIBridge", package: "ABIBridge"),
                .product(name: "ABIBridgeSwiftUI", package: "ABIBridge"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "XcodeMCPNativeRuntimeTests",
            dependencies: ["XcodeMCPNativeRuntime", "XcodeMCPWire", .product(name: "ABIBridge", package: "ABIBridge")],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPCore",
            dependencies: ["XcodeMCPWire"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPKit",
            dependencies: ["XcodeMCPCore", "XcodeMCPWire"],
            path: "Sources/XcodeMCPKit",
            exclude: ["README.md"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPKitTesting",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPKit",
            ],
            path: "Sources/XcodeMCPKitTesting",
            exclude: ["README.md"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPServerRuntimeContract",
            dependencies: ["XcodeMCPCore"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPServerRuntime",
            dependencies: [
                "XcodeMCPInstallation",
                "XcodeMCPServerRuntimeContract",
                "XcodeMCPCore",
                "XcodeMCPWire",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPServerHTTP",
            dependencies: [
                "XcodeMCPServerRuntimeContract",
                "XcodeMCPCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPPermissionAutomation",
            dependencies: [.product(name: "Logging", package: "swift-log")],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "XcodeMCPPermissionAutomationTests",
            dependencies: [
                "XcodeMCPPermissionAutomation",
                "XcodeMCPCoreTestSupport",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPServerKit",
            dependencies: [
                "XcodeMCPServerRuntimeContract",
                "XcodeMCPCore",
                "XcodeMCPServerRuntime",
                "XcodeMCPServerHTTP",
                "XcodeMCPPermissionAutomation",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            exclude: ["README.md"],
            swiftSettings: strictSwiftSettings,
            plugins: [
                .plugin(name: "ServerBuildInfoPlugin"),
            ]
        ),
        .target(
            name: "XcodeMCPServerTestSupport",
            dependencies: [
                "XcodeMCPCoreTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            path: "Tests/XcodeMCPServerTestSupport",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPCoreTestSupport",
            dependencies: [
                "XcodeMCPCore",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            path: "Tests/XcodeMCPCoreTestSupport",
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPServerCLI",
            dependencies: ["XcodeMCPServerKit"],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPInstallCLI",
            dependencies: ["XcodeMCPServerKit"],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "XcodeMCPToolVerifierCLI",
            dependencies: ["XcodeMCPToolVerifier"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPToolVerifier",
            dependencies: ["XcodeMCPKit"],
            exclude: ["README.md"],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "ServerBuildInfoTool",
            swiftSettings: strictSwiftSettings
        ),
        .plugin(
            name: "ServerBuildInfoPlugin",
            capability: .buildTool(),
            dependencies: ["ServerBuildInfoTool"]
        ),
        .testTarget(
            name: "XcodeMCPKitTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPCoreTestSupport",
                "XcodeMCPKit",
            ],
            path: "Tests/XcodeMCPKitTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "XcodeMCPKitTestingTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPCoreTestSupport",
                "XcodeMCPKit",
                "XcodeMCPKitTesting",
            ],
            path: "Tests/XcodeMCPKitTestingTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "XcodeMCPCoreTests",
            dependencies: [
                "XcodeMCPCoreTestSupport",
                "XcodeMCPCore",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            path: "Tests/XcodeMCPCoreTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "PublicProductContractTests",
            dependencies: [
                "XcodeMCPCoreTestSupport",
            ],
            path: "Tests/PublicProductContractTests",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "XcodeMCPServerRuntimeTestSupport",
            dependencies: [
                "XcodeMCPCore", "XcodeMCPServerRuntime", "XcodeMCPServerTestSupport",
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            path: "Tests/XcodeMCPServerRuntimeTestSupport",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "XcodeMCPServerRuntimeTests",
            dependencies: [
                "XcodeMCPServerRuntimeTestSupport",
                "XcodeMCPServerRuntimeContract",
                "XcodeMCPCore",
                "XcodeMCPServerRuntime",
                "XcodeMCPServerTestSupport",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            path: "Tests/XcodeMCPServerRuntimeTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "XcodeMCPProcessRuntimeTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPCoreTestSupport",
            ],
            path: "Tests/XcodeMCPProcessRuntimeTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ServerStressTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPKit",
                "XcodeMCPServerRuntime",
                "XcodeMCPServerHTTP",
                "XcodeMCPServerTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ServerStressTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "XcodeMCPServerHTTPTests",
            dependencies: [
                "XcodeMCPServerRuntimeContract",
                "XcodeMCPServerHTTP",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/XcodeMCPServerHTTPTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ToolVerifierTests",
            dependencies: ["XcodeMCPToolVerifier", "XcodeMCPKitTesting"],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ServerCLITests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPKit",
                "XcodeMCPServerKit",
                "XcodeMCPServerRuntime",
                "XcodeMCPServerTestSupport",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ServerCLITests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ServerIntegrationTests",
            dependencies: [
                "XcodeMCPCoreTestSupport",
                "XcodeMCPServerRuntimeTestSupport",
                "XcodeMCPServerRuntimeContract",
                "XcodeMCPCore",
                "XcodeMCPKit",
                "XcodeMCPServerKit",
                "XcodeMCPServerRuntime",
                "XcodeMCPServerHTTP",
                "XcodeMCPServerTestSupport",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/ServerIntegrationTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "LiveMCPBridgeTests",
            dependencies: [
                "XcodeMCPCore",
                "XcodeMCPKit",
                "XcodeMCPServerKit",
                "XcodeMCPServerRuntime",
                .product(name: "NIO", package: "swift-nio"),
            ],
            path: "Tests/LiveMCPBridgeTests",
            swiftSettings: strictSwiftSettings
        ),
    ]
)

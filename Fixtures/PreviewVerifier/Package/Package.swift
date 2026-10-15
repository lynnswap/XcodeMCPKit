// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "HostlessPreviewPackage",
    platforms: [.macOS("15.4")],
    products: [
        .library(name: "HostlessPreviewPackage", targets: ["HostlessPreviewPackage"]),
    ],
    targets: [
        .target(name: "HostlessPreviewPackage"),
    ]
)

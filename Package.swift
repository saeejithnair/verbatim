// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Verbatim",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Verbatim", path: "Sources/Verbatim")
    ]
)

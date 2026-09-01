// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Verbatim",
    platforms: [.macOS(.v14)],
    targets: [
        // AVFoundation reports audio-route problems as NSExceptions, which
        // Swift cannot catch; this tiny ObjC shim converts them to values.
        .target(name: "ObjCTry", path: "Sources/ObjCTry"),
        .executableTarget(
            name: "Verbatim",
            dependencies: ["ObjCTry"],
            path: "Sources/Verbatim"
        ),
    ]
)

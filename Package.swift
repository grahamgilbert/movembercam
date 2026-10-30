// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MovemberCam",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MovemberCore", path: "Shared"),
        .testTarget(name: "MovemberCoreTests", dependencies: ["MovemberCore"], path: "Tests/Unit")
    ]
)

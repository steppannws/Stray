// swift-tools-version:5.10
import PackageDescription

// The scanning, sizing, and reclaim logic lives here rather than in the app
// target so it can be built and tested without an app host - `swift test`
// in this directory runs the whole suite headlessly, including in CI, on
// code whose job is to irreversibly delete files.
let package = Package(
    name: "StrayCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StrayCore", targets: ["StrayCore"]),
    ],
    targets: [
        .target(name: "StrayCore"),
        .testTarget(name: "StrayCoreTests", dependencies: ["StrayCore"]),
    ]
)

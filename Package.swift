// swift-tools-version:5.9
// Test harness only — the app itself is built by build.sh. `swift test` builds
// the pure logic in MeowBar/Sources/Core as MeowBarCore and runs the tests.
import PackageDescription

let package = Package(
    name: "MeowBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MeowBarCore", path: "MeowBar/Sources/Core"),
        .testTarget(name: "MeowBarCoreTests", dependencies: ["MeowBarCore"],
                    path: "Tests/MeowBarCoreTests"),
    ]
)

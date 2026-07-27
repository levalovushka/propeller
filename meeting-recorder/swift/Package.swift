// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS(.v14)],
    products: [
        // Exposed as a product so Xcode generates a standalone scheme —
        // that's what makes SwiftUI previews build against the library.
        .library(name: "PropellerUI", targets: ["PropellerUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "SpeakerMatchingCore",
            path: "SpeakerMatchingCore"
        ),
        /// Pure helpers extracted for XCTest (plan-optimization S2).
        .target(
            name: "PropellerPure",
            path: "PropellerPure"
        ),
        /// OSSignposter intervals for pipeline / sidecar (plan-testing-metrics F1).
        .target(
            name: "PropellerMetrics",
            path: "PropellerMetrics"
        ),
        // Pure-SwiftUI UI kit (tokens + reusable views). Its own library target
        // so SwiftUI previews work — executable targets can't preview without
        // ENABLE_DEBUG_DYLIB, which SPM manifests can't set.
        .target(
            name: "PropellerUI",
            path: "PropellerUI"
        ),
        .executableTarget(
            name: "MeetingRecorder",
            dependencies: [
                "SpeakerMatchingCore",
                "PropellerPure",
                "PropellerMetrics",
                "PropellerUI",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
            ],
            path: "Sources"
        ),
        .executableTarget(
            name: "Experiments",
            dependencies: [
                "SpeakerMatchingCore",
                "PropellerMetrics",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Experiments"
        ),
        /// Batch pipeline harness — emits benchmarks/latest.json (plan-testing-metrics M2).
        .executableTarget(
            name: "Bench",
            dependencies: [
                "SpeakerMatchingCore",
                "PropellerMetrics",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Bench"
        ),
        .executableTarget(
            name: "SpeakerMatchingCoreChecks",
            dependencies: ["SpeakerMatchingCore"],
            path: "Checks/SpeakerMatchingCoreChecks"
        ),
        .testTarget(
            name: "MeetingRecorderTests",
            dependencies: [
                "PropellerPure",
                "PropellerUI",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/MeetingRecorderTests",
            exclude: ["README.md"]
        ),
    ]
)

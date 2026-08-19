// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    // 14.4, а не 14.0: захват держится на `AudioHardwareCreateProcessTap`,
    // которого раньше нет. Запасного пути на ScreenCaptureKit больше не
    // существует — он был удалён вместе с этим подъёмом, сознательно
    // (см. archive/PLAN-CAPTURE-AND-LIVE.md).
    platforms: [.macOS("14.4")],
    products: [
        // Exposed as a product so Xcode generates a standalone scheme —
        // that's what makes SwiftUI previews build against the library.
        .library(name: "PropellerUI", targets: ["PropellerUI"]),
    ],
    dependencies: [
        // Не ниже 0.15.5: до неё `OfflineDiarizerModels.load` **игнорировал**
        // переданный `MLModelConfiguration` (внутри было жёсткое `.all`), то
        // есть наш запасной заход `.cpuAndNeuralEngine` после падения на
        // macOS 14 не делал ничего. Сверено по исходникам обеих версий.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
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
            // The sidebar draws `SidebarRowState`; the rule that produces one
            // lives in PropellerPure so a test can reach it.
            dependencies: ["PropellerPure"],
            path: "PropellerUI",
            // SwiftPM does not compile Metal: it reports `.metal` as an
            // unhandled file and walks past it. `build.sh` builds the library
            // and puts it in the app's resources — see `SummaryShader`.
            exclude: ["TextShimmer.metal", "Disintegrate.metal"]
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
        /// Read-only MCP server for Claude Desktop — a separate binary inside
        /// the bundle, because Claude owns the process: it is launched at
        /// Claude's start, has to work with Propeller closed, and must never be
        /// a second writer of the archive index.
        .executableTarget(
            name: "PropellerMCP",
            dependencies: ["PropellerPure"],
            path: "MCPServer"
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
        /// `--live` measures the live layer instead; it reuses the product's own
        /// transcript assembly and stem-dominance rule from PropellerPure, so the
        /// measured text is the shipped text.
        .executableTarget(
            name: "Bench",
            dependencies: [
                "SpeakerMatchingCore",
                "PropellerMetrics",
                "PropellerPure",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Bench"
        ),
        .executableTarget(
            name: "SpeakerMatchingCoreChecks",
            dependencies: ["SpeakerMatchingCore"],
            path: "Checks/SpeakerMatchingCoreChecks"
        ),
        /// Lab runner: an axprobe JSONL trace in, the CallWindowJournal spans
        /// out, in the format `tools/diarize-lab/saer-journal.py` scores. Lives
        /// here and not in the lab so the measured decision is the shipped
        /// decision — the same reason Bench reuses PropellerPure.
        .executableTarget(
            name: "CallWindowJournalLab",
            dependencies: ["PropellerPure"],
            path: "Checks/CallWindowJournalLab"
        ),
        .testTarget(
            name: "MeetingRecorderTests",
            dependencies: [
                "PropellerPure",
                "PropellerUI",
                // Speaker attribution decides which stem a voice came from, and
                // that arithmetic is as testable as the rest of the core.
                "SpeakerMatchingCore",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/MeetingRecorderTests",
            exclude: ["README.md"]
        ),
    ]
)

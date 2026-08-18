// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "probe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "probe",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "axprobe",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "axprobe", path: "Sources/axprobe")]
)

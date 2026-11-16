// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "webshot",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "webshot", path: "Sources/webshot")
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MarkTextKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "MarkTextKit", targets: ["MarkTextKit"])],
    dependencies: [
        // cmark-gfm C AST: the renderer walks it directly and emits HTML bytes.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.9.0"),
    ],
    targets: [
        .target(
            name: "MarkTextKit",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            resources: [.copy("Resources/web")]
        ),
        .testTarget(
            name: "MarkTextKitTests",
            dependencies: ["MarkTextKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

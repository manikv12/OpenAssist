// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenAssist",
    platforms: [
        .macOS("13.3")
    ],
    products: [
        .executable(name: "OpenAssist", targets: ["OpenAssist"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1")
    ],
    targets: [
        .executableTarget(
            name: "OpenAssist",
            dependencies: [
                "whisper",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/OpenAssist",
            resources: [.process("../../Resources")]
        ),
        .binaryTarget(
            name: "whisper",
            path: "Vendor/Whisper/whisper.xcframework"
        ),
        .testTarget(
            name: "OpenAssistTests",
            dependencies: ["OpenAssist"],
            path: "Tests/OpenAssistTests"
        )
    ]
)

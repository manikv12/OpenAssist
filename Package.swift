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
        .package(url: "https://github.com/HumeAI/hume-swift-sdk.git", exact: "0.0.1-beta9")
    ],
    targets: [
        .target(
            name: "OpenAssistObjCInterop",
            path: "Sources/OpenAssistObjCInterop",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "OpenAssist",
            dependencies: [
                "whisper",
                "OpenAssistObjCInterop",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Hume", package: "hume-swift-sdk")
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
            dependencies: [
                "OpenAssist",
                "OpenAssistObjCInterop"
            ],
            path: "Tests/OpenAssistTests"
        )
    ]
)

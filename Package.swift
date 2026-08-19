// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacVibe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacVibe", targets: ["MacVibe"])
    ],
    dependencies: [
        // Auto-update. Vended as a binary xcframework; build.sh copies the
        // resulting Sparkle.framework into Contents/Frameworks.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "MacVibe",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/MacVibe",
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        )
    ]
)

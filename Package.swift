// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacVibe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacVibe", targets: ["MacVibe"])
    ],
    targets: [
        .executableTarget(
            name: "MacVibe",
            path: "Sources/MacVibe",
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        )
    ]
)

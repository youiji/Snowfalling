// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sugrob",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Sugrob",
            path: "Sources/Sugrob",
            // The per-frame loops reach class properties millions of times a second; Swift's runtime exclusivity
            // checks around each access cost as much as the physics itself.
            swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release))]
        ),
    ]
)

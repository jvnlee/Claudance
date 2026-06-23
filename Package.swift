// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Claudance",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Claudance",
            path: "Sources/Claudance"
        )
    ]
)

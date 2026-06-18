// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeMeter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeMeter",
            path: "Sources/ClaudeMeter"
        )
    ]
)

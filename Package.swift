// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BuzzDock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BuzzDock",
            path: "Sources/BuzzDock"
        ),
        // Coquille des apps web (copiée dans chaque app web générée)
        .executableTarget(
            name: "BuzzWebApp",
            path: "Sources/BuzzWebApp"
        )
    ]
)

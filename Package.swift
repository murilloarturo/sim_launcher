// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SimLauncher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SimLauncher", targets: ["SimLauncher"])
    ],
    targets: [
        .executableTarget(
            name: "SimLauncher"
        ),
        .testTarget(
            name: "SimLauncherTests",
            dependencies: ["SimLauncher"]
        )
    ],
    swiftLanguageModes: [.v6]
)

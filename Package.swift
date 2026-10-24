// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gh-switch",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "GHSwitch", targets: ["GHSwitch"]),
        .executable(name: "gh-switch", targets: ["gh-switch"]),
    ],
    targets: [
        .target(name: "GHSwitchCore"),
        .executableTarget(name: "gh-switch", dependencies: ["GHSwitchCore"]),
        .executableTarget(name: "GHSwitch", dependencies: ["GHSwitchCore"]),
        .testTarget(name: "GHSwitchCoreTests", dependencies: ["GHSwitchCore"]),
    ],
    swiftLanguageModes: [.v5]
)

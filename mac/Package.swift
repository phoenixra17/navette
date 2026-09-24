// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Navette",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NavetteCore", path: "Sources/NavetteCore"),
        .executableTarget(name: "Navette", dependencies: ["NavetteCore"], path: "Sources/Navette"),
        .testTarget(name: "NavetteTests", dependencies: ["NavetteCore"], path: "Tests/NavetteTests"),
    ]
)

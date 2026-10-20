// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tailport",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tailport", targets: ["Tailport"]),
        .executable(name: "TailportTunnel", targets: ["TailportTunnel"])
    ],
    targets: [
        .executableTarget(name: "Tailport"),
        .executableTarget(name: "TailportTunnel"),
        .testTarget(name: "TailportTests", dependencies: ["Tailport"])
    ],
    swiftLanguageModes: [.v5]
)

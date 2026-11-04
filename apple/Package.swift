// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NomadCore",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [.library(name: "NomadCore", targets: ["NomadCore"])],
    targets: [
        .target(name: "NomadCore"),
        .testTarget(name: "NomadCoreTests", dependencies: ["NomadCore"])
    ],
    swiftLanguageModes: [.v5]
)

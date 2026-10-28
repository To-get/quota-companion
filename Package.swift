// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaCompanion",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QuotaCompanion", targets: ["QuotaCompanion"])],
    targets: [
        .target(name: "QuotaCore"),
        .executableTarget(name: "QuotaCompanion", dependencies: ["QuotaCore"]),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"])
    ],
    swiftLanguageModes: [.v5]
)

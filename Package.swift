// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vapor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VaporKit", targets: ["VaporKit"]),
        .executable(name: "vapor", targets: ["vapor"]),
        .executable(name: "VaporApp", targets: ["VaporApp"]),
    ],
    targets: [
        .target(name: "VaporKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "vapor", dependencies: ["VaporKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "VaporApp", dependencies: ["VaporKit"],
                          resources: [.process("Resources")],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "VaporKitTests", dependencies: ["VaporKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

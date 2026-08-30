// swift-tools-version: 6.0
import PackageDescription

// vovo-mel-viz builds on vovo-core (the public inference half of Vovo: Metal engine, mel/audio, model, Vocos).
let package = Package(
    name: "vovo-mel-viz",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "vovo-mel", targets: ["vovo-mel"])],
    dependencies: [.package(url: "https://github.com/franckverrot/vovo-core.git", branch: "main")],
    targets: [
        .executableTarget(
            name: "vovo-mel",
            dependencies: [
                .product(name: "VovoMetal", package: "vovo-core"), .product(name: "VovoData", package: "vovo-core"),
                .product(name: "VovoModel", package: "vovo-core"), .product(name: "VovoText", package: "vovo-core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

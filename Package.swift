// swift-tools-version: 6.0
import PackageDescription

// vovo-mel-viz builds on the Vovo libraries (mel extraction, the acoustic model, the Vocos vocoder).
// Inside a `git clone --recurse-submodules` of Vovo this package sits in `Vovo/vovo-mel-viz` and finds them at `..`.
let package = Package(
    name: "vovo-mel-viz",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "vovo-mel", targets: ["vovo-mel"])],
    dependencies: [.package(name: "Vovo", path: "..")],
    targets: [
        .executableTarget(
            name: "vovo-mel",
            dependencies: [
                .product(name: "VovoMetal", package: "Vovo"), .product(name: "VovoData", package: "Vovo"),
                .product(name: "VovoModel", package: "Vovo"), .product(name: "VovoText", package: "Vovo"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

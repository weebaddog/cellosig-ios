// swift-tools-version:5.9
// CellosigCore: the cellosig protocol (X3DH, Double Ratchet, sealed sender,
// safety numbers, attachment encryption, wire formats). No UI, no storage, so
// it can be tested on its own against the Node/Android implementation.
import PackageDescription

let package = Package(
    name: "CellosigCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "CellosigCore", targets: ["CellosigCore"]),
    ],
    targets: [
        .target(name: "CellosigCore", path: "Sources/CellosigCore"),
        .testTarget(
            name: "CellosigCoreTests",
            dependencies: ["CellosigCore"],
            path: "Tests/CellosigCoreTests"
        ),
    ]
)

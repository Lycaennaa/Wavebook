// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wavebook",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WavebookCore", targets: ["WavebookCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        .target(
            name: "WavebookCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/WavebookCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "WavebookCoreTests",
            dependencies: ["WavebookCore"],
            path: "Tests/WavebookCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
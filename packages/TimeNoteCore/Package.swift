// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TimeNoteCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TimeNoteDomain", targets: ["TimeNoteDomain"]),
        .library(name: "TimeNoteApplication", targets: ["TimeNoteApplication"])
    ],
    targets: [
        .target(name: "TimeNoteDomain"),
        .target(name: "TimeNoteApplication", dependencies: ["TimeNoteDomain"]),
        .testTarget(
            name: "TimeNoteCoreTests",
            dependencies: ["TimeNoteDomain", "TimeNoteApplication"]
        )
    ]
)

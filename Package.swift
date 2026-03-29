// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Orbit",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Orbit", targets: ["Orbit"]),
    ],
    targets: [
        .executableTarget(
            name: "Orbit",
            path: "Sources",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "OrbitTests",
            dependencies: ["Orbit"]
        ),
    ]
)

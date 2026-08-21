// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "AgentTransmission",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentTransmissionCore", targets: ["AgentTransmissionCore"]),
        .executable(name: "CodexTransmission", targets: ["CodexTransmission"]),
    ],
    targets: [
        .target(name: "AgentTransmissionCore"),
        .executableTarget(
            name: "CodexTransmission",
            dependencies: ["AgentTransmissionCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "AgentTransmissionTests",
            dependencies: ["AgentTransmissionCore", "CodexTransmission"]
        ),
    ]
)

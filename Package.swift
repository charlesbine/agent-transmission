// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "AgentTransmission",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentTransmissionCore", targets: ["AgentTransmissionCore"]),
        .executable(name: "AgentTransmission", targets: ["AgentTransmission"]),
    ],
    targets: [
        .target(name: "AgentTransmissionCore"),
        .executableTarget(
            name: "AgentTransmission",
            dependencies: ["AgentTransmissionCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "AgentTransmissionTests",
            dependencies: ["AgentTransmissionCore", "AgentTransmission"]
        ),
    ]
)

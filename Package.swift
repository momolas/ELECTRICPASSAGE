// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VehicleKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .visionOS(.v2),
        .watchOS(.v11)
    ],
    products: [
        .library(
            name: "VehicleKit",
            targets: ["VehicleKit"]
        ),
        .library(
            name: "SwiftVehicleProtocols",
            targets: ["SwiftVehicleProtocols"]
        ),
        .library(name: "VehicleCore", targets: ["VehicleCore"]),
        .library(name: "VehicleISOTP", targets: ["VehicleISOTP"]),
        .library(name: "VehicleDiagnostic", targets: ["VehicleDiagnostic"]),
        .library(name: "VehicleTransport", targets: ["VehicleTransport"]),
        .library(name: "VehicleTransportPanda", targets: ["VehicleTransportPanda"]),
        .library(name: "VehicleAnalytics", targets: ["VehicleAnalytics"]),
        .library(name: "VehicleML", targets: ["VehicleML"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "VehicleCore",
            dependencies: [],
            path: "Sources/VehicleCore"
        ),
        .target(
            name: "VehicleISOTP",
            dependencies: ["VehicleCore"],
            path: "Sources/VehicleISOTP"
        ),
        .target(
            name: "VehicleDiagnostic",
            dependencies: ["VehicleCore", "VehicleISOTP", "VehicleTransport"],
            path: "Sources/VehicleDiagnostic"
        ),
        .target(
            name: "VehicleTransport",
            dependencies: ["VehicleCore"],
            path: "Sources/VehicleTransport"
        ),
        .target(
            name: "VehicleTransportPanda",
            dependencies: ["VehicleTransport", "VehicleCore"],
            path: "Sources/VehicleTransportPanda"
        ),
        .target(
            name: "VehicleAnalytics",
            dependencies: ["VehicleCore", "VehicleTransport"],
            path: "Sources/VehicleAnalytics"
        ),
        .target(
            name: "VehicleML",
            dependencies: ["VehicleCore", "VehicleAnalytics"],
            path: "Sources/VehicleML"
        ),
        .target(
            name: "VehicleKit",
            dependencies: [
                "VehicleCore",
                "VehicleISOTP",
                "VehicleDiagnostic",
                "VehicleTransport",
                "VehicleTransportPanda",
                "VehicleAnalytics",
                "VehicleML"
            ],
            path: "Sources/VehicleKit"
        ),
        .target(
            name: "SwiftVehicleProtocols",
            dependencies: ["VehicleKit"],
            path: "Sources/SwiftVehicleProtocols"
        ),
        .testTarget(
            name: "VehicleKitTests",
            dependencies: ["VehicleKit"],
            path: "Tests/VehicleKitTests"
        )
    ]
)

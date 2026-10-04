// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MenuBox",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MenuBox", targets: ["MenuBox"])
    ],
    dependencies: [
        .package(name: "MacAppEssentials", path: "../tools/library"),
        .package(path: "../tools/library/Integrations/MacAppUpdatesSparkle"),
        .package(path: "../tools/library/Integrations/MacAppDiagnosticsSentry")
    ],
    targets: [
        .executableTarget(
            name: "MenuBox",
            dependencies: [
                .product(name: "MacAppCore", package: "MacAppEssentials"),
                .product(name: "MacAppSettings", package: "MacAppEssentials"),
                .product(name: "MacAppLifecycle", package: "MacAppEssentials"),
                .product(name: "MacAppMainMenu", package: "MacAppEssentials"),
                .product(name: "MacAppUpdatesSparkle", package: "MacAppUpdatesSparkle"),
                .product(name: "MacAppDiagnosticsSentry", package: "MacAppDiagnosticsSentry")
            ],
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "MenuBoxTests",
            dependencies: ["MenuBox"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

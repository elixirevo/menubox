// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MenuBox",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MenuBox", targets: ["MenuBox"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "MenuBox",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
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

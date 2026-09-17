// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "victual-kit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .macCatalyst(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        // Generated request/response types and the low-level client.
        .library(name: "VictualAPI", targets: ["VictualAPI"]),
        // Connection configuration, authentication, and error handling.
        .library(name: "VictualCore", targets: ["VictualCore"]),
        // SwiftUI session plumbing shared by every Apple-platform front end.
        .library(name: "VictualUI", targets: ["VictualUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.12.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "VictualAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        .target(
            name: "VictualCore",
            dependencies: [
                "VictualAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ]
        ),
        .target(
            name: "VictualUI",
            dependencies: ["VictualCore"]
        ),
        // Shared fakes for the test targets. Not a product: nothing outside this
        // package can import it.
        .target(
            name: "VictualTestSupport",
            dependencies: [
                "VictualCore",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            path: "Tests/VictualTestSupport"
        ),
        .testTarget(
            name: "VictualAPITests",
            dependencies: ["VictualAPI"]
        ),
        .testTarget(
            name: "VictualCoreTests",
            dependencies: ["VictualCore", "VictualTestSupport"]
        ),
        .testTarget(
            name: "VictualUITests",
            dependencies: ["VictualUI", "VictualTestSupport"]
        ),
    ]
)

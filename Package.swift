// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Choreganize",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "Choreganize", targets: ["Choreganize"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "Choreganize",
            path: "Choreganize",
            resources: [
                // Including assets allows the package to compile if resources are needed.
                .process("Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "ChoreganizeTests",
            dependencies: [
                "Choreganize",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "ChoreganizeTests"
        ),
        .testTarget(
            name: "ChoreganizeUITests",
            dependencies: [
                "Choreganize",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "ChoreganizeUITests"
        )
    ]
)

// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LibraryCore",
    platforms: [.macOS(.v14), .iOS(.v17)], // Matches your project targets
    products: [
        .library(name: "LibraryCore", targets: ["LibraryCore"]),
    ],
    dependencies: [
        // Add the GRDB dependency here too
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.2"),
    ],
    targets: [
            .target(
                name: "LibraryCore",
                dependencies: [
                    .product(name: "GRDB", package: "GRDB.swift"),
                ]
            )
        ]
)

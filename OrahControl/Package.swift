// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OrahControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OrahKit", targets: ["OrahKit"]),
        .executable(name: "OrahControl", targets: ["OrahControl"]),
        .executable(name: "orahctl", targets: ["orahctl"]),
    ],
    targets: [
        .target(name: "OrahKit"),
        .executableTarget(name: "OrahControl", dependencies: ["OrahKit"]),
        .executableTarget(name: "orahctl", dependencies: ["OrahKit"]),
    ]
)

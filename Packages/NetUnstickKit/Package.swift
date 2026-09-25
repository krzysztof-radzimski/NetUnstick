// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NetUnstickKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NetUnstickCore", targets: ["NetUnstickCore"]),
        .library(name: "NetUnstickNetwork", targets: ["NetUnstickNetwork"]),
        .library(name: "NetUnstickRepair", targets: ["NetUnstickRepair"]),
    ],
    targets: [
        .target(name: "NetUnstickCore"),
        .target(name: "NetUnstickNetwork", dependencies: ["NetUnstickCore"]),
        .target(name: "NetUnstickRepair", dependencies: ["NetUnstickCore", "NetUnstickNetwork"]),
        .testTarget(name: "NetUnstickCoreTests", dependencies: ["NetUnstickCore"]),
        .testTarget(name: "NetUnstickNetworkTests", dependencies: ["NetUnstickNetwork"]),
        .testTarget(name: "NetUnstickRepairTests", dependencies: ["NetUnstickRepair"]),
    ]
)

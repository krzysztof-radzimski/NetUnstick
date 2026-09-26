// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NetUnstickKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NetUnstickCore", type: .static, targets: ["NetUnstickCore"]),
        .library(name: "NetUnstickNetwork", type: .static, targets: ["NetUnstickNetwork"]),
        .library(name: "NetUnstickRepair", type: .static, targets: ["NetUnstickRepair"]),
    ],
    targets: [
        .target(name: "NetUnstickCore"),
        .target(name: "NetUnstickNetwork", dependencies: ["NetUnstickCore"]),
        .target(name: "NetUnstickRepair", dependencies: ["NetUnstickCore", "NetUnstickNetwork"]),
        .testTarget(name: "NetUnstickCoreTests", dependencies: ["NetUnstickCore"]),
        .testTarget(name: "NetUnstickNetworkTests", dependencies: ["NetUnstickNetwork"], resources: [
            .copy("Fixtures/netstat-ipv4.txt"),
            .copy("Fixtures/netstat-ipv6.txt"),
            .copy("Fixtures/scutil-dns.txt"),
        ]),
        .testTarget(name: "NetUnstickRepairTests", dependencies: ["NetUnstickRepair"]),
    ]
)

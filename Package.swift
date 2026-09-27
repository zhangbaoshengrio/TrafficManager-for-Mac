// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrafficMonitor",
    // 本地化资源用 .copy 而非 .process 声明：.process 会把 zh-Hans.lproj
    // 小写成 zh-hans.lproj，之后运行时再也匹配不上该语言（实测）。
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "TrafficMonitor", targets: ["TrafficMonitor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .executableTarget(
            name: "TrafficMonitor",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                .copy("Resources/en.lproj"),
                .copy("Resources/zh-Hans.lproj"),
            ]
        ),
        .testTarget(
            name: "TrafficMonitorTests",
            dependencies: ["TrafficMonitor"]
        ),
    ]
)

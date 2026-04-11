// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WeChatHUD",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WeChatHUD",
            path: "Sources/WeChatHUD",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "WeChatHUDTests",
            dependencies: ["WeChatHUD"],
            path: "Tests/WeChatHUDTests"
        )
    ]
)

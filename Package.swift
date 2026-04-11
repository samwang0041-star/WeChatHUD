// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WeChatHUD",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"])
            ],
            linkerSettings: [
                .unsafeFlags(["/opt/homebrew/lib/libzstd.a"])
            ]
        ),
        .executableTarget(
            name: "WeChatHUD",
            dependencies: ["CZstd"],
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

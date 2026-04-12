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
                .unsafeFlags(["-L/opt/homebrew/lib"]),
                .unsafeFlags(["-Xlinker", "-w"]),
                .linkedLibrary("zstd")
            ]
        ),
        .executableTarget(
            name: "WeChatHUD",
            dependencies: ["CZstd"],
            path: "Sources/WeChatHUD",
            // Versioned prompts for the AI subsystem live alongside the
            // source so SPM bundles them as Bundle.module resources. The
            // root-level Resources/Info.plist is unrelated — it's pulled
            // in via the linker flag below, not the SPM resources system.
            resources: [
                .copy("Resources/prompts")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                // Embed Info.plist directly into the executable so the
                // bare `.build/debug/WeChatHUD` binary (no `.app` bundle)
                // is still recognised by macOS as having usage
                // descriptions. Without this, `NSAppleEventsUsageDescription`
                // is invisible to TCC and Automation prompts are silently
                // denied with `errAEEventNotPermitted (-1743)`.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "WeChatHUDTests",
            dependencies: ["WeChatHUD"],
            path: "Tests/WeChatHUDTests"
        )
    ]
)

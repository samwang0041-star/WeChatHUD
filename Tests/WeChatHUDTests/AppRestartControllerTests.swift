import XCTest
@testable import WeChatHUD

@MainActor
final class AppRestartControllerTests: XCTestCase {
    final class Flag: @unchecked Sendable {
        var value = false
    }

    func testRejectsMissingBundleBeforeCallingLauncher() async {
        let launchCalled = Flag()

        do {
            try await AppRestartController.restart(
                bundleURL: URL(fileURLWithPath: "/tmp/WeChatHUD-does-not-exist.app"),
                launch: { _, _, _ in launchCalled.value = true }
            )
            XCTFail("Expected missing bundle error")
        } catch let error as AppRestartController.RestartError {
            XCTAssertEqual(error, .bundleMissing(URL(fileURLWithPath: "/tmp/WeChatHUD-does-not-exist.app")))
            XCTAssertFalse(launchCalled.value)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectsNonAppBundleBeforeCallingLauncher() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("WeChatHUD-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            try await AppRestartController.restart(bundleURL: file, launch: { _, _, _ in
                XCTFail("Launcher must not be called")
            })
            XCTFail("Expected non-app bundle error")
        } catch let error as AppRestartController.RestartError {
            XCTAssertEqual(error, .notApplicationBundle(file))
        }
    }

    func testLaunchSuccessTerminatesOnlyAfterSuccessfulCallback() async throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("WeChatHUD-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: app) }
        let launched = Flag()
        let terminated = Flag()

        try await AppRestartController.restart(
            bundleURL: app,
            launch: { _, configuration, completion in
                XCTAssertTrue(configuration.createsNewApplicationInstance)
                XCTAssertEqual(configuration.arguments, ["--relaunch-parent", String(ProcessInfo.processInfo.processIdentifier)])
                launched.value = true
                completion(AppRestartController.LaunchReceipt(
                    processIdentifier: Int32(ProcessInfo.processInfo.processIdentifier + 1),
                    isTerminated: false,
                    bundleURL: app
                ), nil)
            },
            terminate: { terminated.value = true }
        )

        XCTAssertTrue(launched.value)
        XCTAssertTrue(terminated.value)
    }

    func testRelaunchParentParsesOnlyValidDifferentPositivePID() {
        XCTAssertEqual(relaunchParent(arguments: ["--relaunch-parent", "1234"], currentPID: 99), 1234)
        XCTAssertNil(relaunchParent(arguments: [], currentPID: 99))
        XCTAssertNil(relaunchParent(arguments: ["--relaunch-parent"], currentPID: 99))
        XCTAssertNil(relaunchParent(arguments: ["--relaunch-parent", "0"], currentPID: 99))
        XCTAssertNil(relaunchParent(arguments: ["--relaunch-parent", "-12"], currentPID: 99))
        XCTAssertNil(relaunchParent(arguments: ["--relaunch-parent", "12x"], currentPID: 99))
        XCTAssertNil(relaunchParent(arguments: ["--relaunch-parent", "99"], currentPID: 99))
    }

    func testLaunchFailureKeepsCurrentApplicationRunning() async throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("WeChatHUD-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: app) }
        let terminated = Flag()

        do {
            try await AppRestartController.restart(
                bundleURL: app,
                launch: { _, _, completion in
                    completion(nil, NSError(domain: "test", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: "测试启动失败"]))
                },
                terminate: { terminated.value = true }
            )
            XCTFail("Expected launch failure")
        } catch let error as AppRestartController.RestartError {
            XCTAssertEqual(error.userMessage, "新应用启动失败，当前应用仍在运行，请稍后重试")
            XCTAssertFalse(terminated.value)
        }
    }

    func testRejectsCurrentOrTerminatedOrWrongBundleReceipt() async throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("WeChatHUD-\(UUID().uuidString).app")
        let otherApp = FileManager.default.temporaryDirectory.appendingPathComponent("Other-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: otherApp, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: app)
            try? FileManager.default.removeItem(at: otherApp)
        }

        let cases: [AppRestartController.LaunchReceipt] = [
            .init(processIdentifier: Int32(ProcessInfo.processInfo.processIdentifier), isTerminated: false, bundleURL: app),
            .init(processIdentifier: Int32(ProcessInfo.processInfo.processIdentifier + 1), isTerminated: true, bundleURL: app),
            .init(processIdentifier: Int32(ProcessInfo.processInfo.processIdentifier + 1), isTerminated: false, bundleURL: otherApp)
        ]
        for receipt in cases {
            let terminated = Flag()
            do {
                try await AppRestartController.restart(
                    bundleURL: app,
                    launch: { _, _, completion in completion(receipt, nil) },
                    terminate: { terminated.value = true }
                )
                XCTFail("Expected receipt validation failure")
            } catch let error as AppRestartController.RestartError {
                XCTAssertEqual(error.userMessage, "新应用启动失败，当前应用仍在运行，请稍后重试")
                XCTAssertFalse(terminated.value)
            }
        }
    }
}

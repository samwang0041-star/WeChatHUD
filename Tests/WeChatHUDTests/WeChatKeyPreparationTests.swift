import CryptoKit
import XCTest
@testable import WeChatHUD

/// Full key-preparation flow without touching real WeChat, codesign, or the
/// default ~/.wechat-hud paths: every external command goes through the fake
/// runner and every path is a temp directory owned by the test.
@MainActor
final class WeChatKeyPreparationTests: XCTestCase {
    private final class FakeRunner: WeChatKeyPreparationService.ProcessRunner {
        struct Call {
            let executablePath: String
            let arguments: [String]
            let currentDirectoryPath: String?
        }

        private(set) var calls: [Call] = []
        private let handler: (Call) -> WeChatKeyPreparationService.RunOutcome

        init(handler: @escaping (Call) -> WeChatKeyPreparationService.RunOutcome) {
            self.handler = handler
        }

        func run(
            executablePath: String,
            arguments: [String],
            currentDirectoryPath: String?,
            timeout: TimeInterval
        ) async throws -> WeChatKeyPreparationService.RunOutcome {
            let call = Call(
                executablePath: executablePath,
                arguments: arguments,
                currentDirectoryPath: currentDirectoryPath)
            calls.append(call)
            return handler(call)
        }
    }

    private func entitlementsPlist(taskAllow: Bool) -> String {
        let entry = taskAllow
            ? "    <key>com.apple.security.get-task-allow</key>\n    <true/>"
            : "    <key>com.apple.security.app-sandbox</key>\n    <true/>"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(entry)
        </dict>
        </plist>
        """
    }

    private func makeTempDirectory(name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechathud-prep-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// Builds a database first page whose stored HMAC matches the given key,
    /// using the same primitives the service verifies with.
    private func makeEncryptedDBPage(key: Data, salt: Data) -> Data {
        let macSalt = Data(salt.map { $0 ^ 0x3A })
        let macKey = WeChatKeyPreparationService.deriveMacKey(key: key, macSalt: macSalt)!
        var payload = Data(count: 4032 - 16)
        payload.append(contentsOf: [1, 0, 0, 0])  // uint32 LE 1
        let digest = HMAC<SHA512>.authenticationCode(for: payload, using: SymmetricKey(data: macKey))

        var page = Data()
        page.append(salt)
        page.append(payload.dropLast(4))
        page.append(Data(digest))
        XCTAssertEqual(page.count, 4096)
        return page
    }

    private func makeExecutableFile(at path: String) throws {
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: path)
    }

    func testMissingTaskAllowEntitlementRequiresUserConsent() async {
        let fake = FakeRunner { call in
            XCTAssertEqual(call.executablePath, "/usr/bin/codesign")
            XCTAssertEqual(call.arguments, ["-d", "--entitlements", ":-", "/Applications/WeChat.app"])
            return .init(exitCode: 0, stdout: self.entitlementsPlist(taskAllow: false), stderr: "")
        }
        let service = WeChatKeyPreparationService(runner: fake)
        let entitled = await service.checkWeChatEntitlement(appPath: "/Applications/WeChat.app")
        XCTAssertFalse(entitled)
        await service.updateEntitlementPhase(appPath: "/Applications/WeChat.app")
        XCTAssertEqual(service.phase, .needsResignConsent)
    }

    func testPresentTaskAllowEntitlementKeepsFlowIdle() async {
        let fake = FakeRunner { _ in
            .init(exitCode: 0, stdout: self.entitlementsPlist(taskAllow: true), stderr: "")
        }
        let service = WeChatKeyPreparationService(runner: fake)
        let entitled = await service.checkWeChatEntitlement(appPath: "/Applications/WeChat.app")
        XCTAssertTrue(entitled)
        await service.updateEntitlementPhase(appPath: "/Applications/WeChat.app")
        XCTAssertEqual(service.phase, .idle)
    }

    func testTaskForPidFailureReportsNeedsResignAgain() async throws {
        let workDir = try makeTempDirectory(name: "taskforpid")
        let binaryPath = try makeTempDirectory(name: "bin") + "/find_all_keys_macos.arm64"
        try makeExecutableFile(at: binaryPath)

        let fake = FakeRunner { call in
            XCTAssertEqual(call.executablePath, binaryPath)
            XCTAssertEqual(call.currentDirectoryPath, workDir)
            return .init(exitCode: 5, stdout: "task_for_pid failed: 5\n", stderr: "")
        }
        let service = WeChatKeyPreparationService(runner: fake)
        let outcome = try await service.runExtraction(
            binaryURL: URL(fileURLWithPath: binaryPath), workDir: workDir)

        guard case .needsResignAgain(let reason) = outcome else {
            return XCTFail("expected needsResignAgain, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("task_for_pid"))
    }

    func testExtractionParsesScannerOutput() async throws {
        let workDir = try makeTempDirectory(name: "extract")
        let binaryPath = try makeTempDirectory(name: "bin") + "/find_all_keys_macos.arm64"
        try makeExecutableFile(at: binaryPath)

        let keyHex = String(repeating: "ab", count: 32)
        let saltHex = String(repeating: "cd", count: 16)
        let payload = """
        {
          "message_0.db": {"enc_key": "\(keyHex)", "salt": "\(saltHex)"}
        }
        """
        try payload.write(
            to: URL(fileURLWithPath: (workDir as NSString).appendingPathComponent("all_keys.json")),
            atomically: true, encoding: .utf8)

        let fake = FakeRunner { _ in .init(exitCode: 0, stdout: "Matched 1/1", stderr: "") }
        let service = WeChatKeyPreparationService(runner: fake)
        let outcome = try await service.runExtraction(
            binaryURL: URL(fileURLWithPath: binaryPath), workDir: workDir)

        guard case .extracted(let rawKeys) = outcome else {
            return XCTFail("expected extracted, got \(outcome)")
        }
        XCTAssertEqual(rawKeys["message_0.db"]?["enc_key"], keyHex)
    }

    func testVerifyAndStoreValidatesHMACAndWritesInjectableDirectory() async throws {
        let key = Data((0..<32).map { UInt8($0 * 7 + 3) })
        let salt = Data((0..<16).map { UInt8($0 * 11 + 1) })
        let page = makeEncryptedDBPage(key: key, salt: salt)

        let dbRoot = try makeTempDirectory(name: "dbroot")
        try page.write(
            to: URL(fileURLWithPath: (dbRoot as NSString).appendingPathComponent("message_0.db")),
            options: .atomic)

        let keysDirectory = try makeTempDirectory(name: "keys")
        let service = WeChatKeyPreparationService(runner: FakeRunner { _ in
            XCTFail("verify/store must not run external commands")
            return .init(exitCode: 0, stdout: "", stderr: "")
        })

        let storedPath = try service.verifyAndStore(
            rawKeys: ["message_0.db": [
                "enc_key": key.map { String(format: "%02x", $0) }.joined(),
                "salt": salt.map { String(format: "%02x", $0) }.joined()
            ]],
            dbRoot: dbRoot,
            keysDirectory: keysDirectory)

        XCTAssertEqual(
            storedPath, (keysDirectory as NSString).appendingPathComponent("all_keys.json"))
        XCTAssertTrue(WeChatReader.validateKeyFile(at: storedPath))
        let dirPerms = try FileManager.default.attributesOfItem(atPath: keysDirectory)[.posixPermissions] as? NSNumber
        XCTAssertEqual(dirPerms?.uint16Value, 0o700)
        let filePerms = try FileManager.default.attributesOfItem(atPath: storedPath)[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePerms?.uint16Value, 0o600)
    }

    func testVerifyAndStoreRejectsKeyThatFailsHMAC() async throws {
        let key = Data((0..<32).map { UInt8($0 + 1) })
        let salt = Data((0..<16).map { UInt8($0 * 3) })
        var page = makeEncryptedDBPage(key: key, salt: salt)
        // Corrupt the stored HMAC region.
        page.replaceSubrange(4032..<4096, with: Data(count: 64))

        let dbRoot = try makeTempDirectory(name: "dbroot-bad")
        try page.write(
            to: URL(fileURLWithPath: (dbRoot as NSString).appendingPathComponent("message_0.db")),
            options: .atomic)

        let keysDirectory = try makeTempDirectory(name: "keys-bad")
        let service = WeChatKeyPreparationService(runner: FakeRunner { _ in
            .init(exitCode: 0, stdout: "", stderr: "")
        })

        XCTAssertThrowsError(
            try service.verifyAndStore(
                rawKeys: ["message_0.db": [
                    "enc_key": key.map { String(format: "%02x", $0) }.joined(),
                    "salt": salt.map { String(format: "%02x", $0) }.joined()
                ]],
                dbRoot: dbRoot,
                keysDirectory: keysDirectory)
        ) { error in
            guard case WeChatKeyPreparationService.PreparationError.keyVerificationFailed = error else {
                return XCTFail("expected keyVerificationFailed, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (keysDirectory as NSString).appendingPathComponent("all_keys.json")))
    }
}

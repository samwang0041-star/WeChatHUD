import CommonCrypto
import CryptoKit
import Foundation

/// One-time preparation that turns a locked WeChat install into a readable
/// one: make WeChat debuggable (ad-hoc resign), wait for a fresh login, scan
/// WeChat process memory for database keys, then verify and store them.
///
/// Every external command goes through the injected runner so tests exercise
/// the whole flow without touching real WeChat, codesign, or key material.
/// The service never resigns or scans before the view explicitly asks it to,
/// and never quits WeChat itself.
@MainActor
final class WeChatKeyPreparationService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case needsResignConsent
        case waitingForWeChatRelogin
        case extracting
        case needsResignAgain(reason: String)
        case succeeded(keysPath: String)
        case failed(reason: String)
    }

    struct RunOutcome: Equatable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    protocol ProcessRunner {
        func run(
            executablePath: String,
            arguments: [String],
            currentDirectoryPath: String?,
            timeout: TimeInterval
        ) async throws -> RunOutcome
    }

    enum PreparationError: LocalizedError {
        case binaryMissing(String)
        case workDirMissing(String)
        case extractionFailed(String)
        case noKeysFound
        case keyVerificationFailed
        case resignFailed(String)
        case malformedEntitlements

        var errorDescription: String? {
            switch self {
            case .binaryMissing(let path): return "密钥提取工具不存在: \(path)"
            case .workDirMissing(let path): return "微信数据目录不存在: \(path)"
            case .extractionFailed(let detail): return "密钥提取失败: \(detail)"
            case .noKeysFound: return "提取输出中没有可用的数据库密钥"
            case .keyVerificationFailed: return "提取的密钥均未通过数据库页 HMAC 校验"
            case .resignFailed(let detail): return "微信重签失败: \(detail)"
            case .malformedEntitlements: return "微信签名权限解析失败"
            }
        }
    }

    /// Keys exactly as the C scanner writes them:
    /// { db-relative-path: { "enc_key": hex, "salt": hex } } — the same shape
    /// WeChatReader.loadKeys consumes. This is deliberately NOT
    /// { salt: key }; see the C source all_keys.json writer.
    typealias RawKeys = [String: [String: String]]

    static let taskAllowEntitlement = "com.apple.security.get-task-allow"
    static let defaultKeysDirectory = NSHomeDirectory() + "/.wechat-hud/keys"

    @Published private(set) var phase: Phase = .idle

    private let runner: ProcessRunner

    init(runner: ProcessRunner = SubprocessRunner()) {
        self.runner = runner
    }

    // MARK: - Step functions

    /// True only when WeChat's current signature already allows task_for_pid.
    @discardableResult
    func checkWeChatEntitlement(appPath: String) async -> Bool {
        guard let probe = try? await runCodesign(arguments: ["-d", "--entitlements", ":-", appPath], timeout: 15),
              probe.exitCode == 0,
              let entitlements = Self.parseEntitlementsPlist(probe.stdout),
              entitlements[Self.taskAllowEntitlement] as? Bool == true else { return false }
        return true
    }

    /// Preserve WeChat's existing entitlements and add get-task-allow, then
    /// ad-hoc re-sign. The merged entitlements file is temporary and removed
    /// right after signing.
    func resignWeChat(appPath: String) async throws {
        let probe = try await runCodesign(arguments: ["-d", "--entitlements", ":-", appPath], timeout: 15)
        var entitlements = probe.exitCode == 0
            ? (Self.parseEntitlementsPlist(probe.stdout) ?? [:])
            : [:]
        entitlements[Self.taskAllowEntitlement] = true

        let plistData: Data
        do {
            plistData = try PropertyListSerialization.data(
                fromPropertyList: entitlements, format: .xml, options: 0)
        } catch {
            throw PreparationError.malformedEntitlements
        }

        let tempPlist = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechathud-entitlements-\(UUID().uuidString).plist")
        try plistData.write(to: tempPlist)
        defer { try? FileManager.default.removeItem(at: tempPlist) }

        let result = try await runCodesign(
            arguments: ["--force", "--sign", "-", "--entitlements", tempPlist.path, appPath],
            timeout: 60)
        guard result.exitCode == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw PreparationError.resignFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    enum ExtractionOutcome: Equatable {
        case extracted(RawKeys)
        case needsResignAgain(reason: String)
    }

    /// Runs the bundled scanner binary with cwd = db_storage's parent, as the
    /// C binary requires. It writes all_keys.json into the working directory.
    func runExtraction(binaryURL: URL, workDir: String) async throws -> ExtractionOutcome {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: binaryURL.path) else {
            throw PreparationError.binaryMissing(binaryURL.path)
        }
        guard fm.fileExists(atPath: workDir) else {
            throw PreparationError.workDirMissing(workDir)
        }

        let outcome = try await runner.run(
            executablePath: binaryURL.path,
            arguments: [],
            currentDirectoryPath: workDir,
            timeout: 120)

        let combined = outcome.stdout + "\n" + outcome.stderr
        if combined.contains("task_for_pid") {
            return .needsResignAgain(reason: combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard outcome.exitCode == 0 else {
            let detail = outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr
            throw PreparationError.extractionFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let outputURL = URL(fileURLWithPath: (workDir as NSString).appendingPathComponent("all_keys.json"))
        guard let data = fm.contents(atPath: outputURL.path),
              let raw = try? JSONDecoder().decode(RawKeysPayload.self, from: data),
              !raw.keys.isEmpty else {
            throw PreparationError.noKeysFound
        }
        return .extracted(raw.keys)
    }

    /// Verify at least one extracted key against the first page of its
    /// database (HMAC-SHA512, same math as wechat_cli keys/common.py), then
    /// store the full raw payload under the keys directory with tight
    /// permissions. Returns the stored file path.
    @discardableResult
    func verifyAndStore(
        rawKeys: RawKeys,
        dbRoot: String,
        keysDirectory: String? = nil
    ) throws -> String {
        guard !rawKeys.isEmpty else { throw PreparationError.noKeysFound }

        var verified = false
        for (relPath, entry) in rawKeys {
            guard let hexKey = entry["enc_key"],
                  let key = Data(hexString: hexKey),
                  key.count == 32 else { continue }
            let dbPath = (dbRoot as NSString).appendingPathComponent(relPath)
            guard let pageData = try? Data(contentsOf: URL(fileURLWithPath: dbPath)),
                  pageData.count >= 4096 else { continue }
            if Self.verifyEncKey(key: key, page1: pageData.prefix(4096)) {
                verified = true
                break
            }
        }
        guard verified else { throw PreparationError.keyVerificationFailed }

        let directory = keysDirectory ?? Self.defaultKeysDirectory
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)

        let payload = try JSONEncoder().encode(RawKeysPayload(keys: rawKeys))
        let outputPath = (directory as NSString).appendingPathComponent("all_keys.json")
        guard fm.createFile(atPath: outputPath, contents: payload,
                            attributes: [.posixPermissions: 0o600]) else {
            throw PreparationError.extractionFailed("无法写入 \(outputPath)")
        }
        return outputPath
    }

    func setPhase(_ newPhase: Phase) {
        phase = newPhase
    }

    /// Reads WeChat's signature and maps it to the flow phase: unprepared
    /// installs move to needsResignConsent (user consent required before any
    /// resign or scan); already-debuggable installs stay idle and ready.
    func updateEntitlementPhase(appPath: String) async {
        let entitled = await checkWeChatEntitlement(appPath: appPath)
        guard !entitled, phase == .idle else { return }
        phase = .needsResignConsent
    }

    // MARK: - Crypto (keys/common.py verify_enc_key)

    /// salt = page1[0:16]; mac_salt = salt ^ 0x3A;
    /// mac_key = PBKDF2-HMAC-SHA512(key, mac_salt, 2, 32);
    /// HMAC-SHA512(mac_key, page1[16:4032] + uint32 LE 1) == page1[4032:4096].
    static func verifyEncKey(key: Data, page1: Data) -> Bool {
        guard page1.count >= 4096 else { return false }
        let page = Data(page1.prefix(4096))
        let salt = page.prefix(16)
        let macSalt = Data(salt.map { $0 ^ 0x3A })
        guard let macKey = deriveMacKey(key: key, macSalt: macSalt) else { return false }

        var hmacInput = page.subdata(in: 16..<4032)
        hmacInput.append(contentsOf: [1, 0, 0, 0])  // uint32 little-endian 1
        let stored = page.subdata(in: 4032..<4096)
        let digest = HMAC<SHA512>.authenticationCode(
            for: hmacInput, using: SymmetricKey(data: macKey))
        return Data(digest) == stored
    }

    static func deriveMacKey(key: Data, macSalt: Data) -> Data? {
        var derived = Data(repeating: 0, count: 32)
        let material = Data(key)
        let salt = Data(macSalt)
        let status = derived.withUnsafeMutableBytes { derivedPtr -> Int32 in
            material.withUnsafeBytes { keyPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        keyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), key.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), 2,
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    // MARK: - Plist helpers

    static func parseEntitlementsPlist(_ output: String) -> [String: Any]? {
        guard let data = output.data(using: .utf8),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }

    private func runCodesign(arguments: [String], timeout: TimeInterval) async throws -> RunOutcome {
        try await runner.run(
            executablePath: "/usr/bin/codesign",
            arguments: arguments,
            currentDirectoryPath: nil,
            timeout: timeout)
    }

    // MARK: - Payload decoding

    private struct RawKeysPayload: Codable {
        let keys: RawKeys

        init(keys: RawKeys) { self.keys = keys }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            keys = try container.decode(RawKeys.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(keys)
        }
    }
}

/// Real runner used in production; kills the child on timeout.
struct SubprocessRunner: WeChatKeyPreparationService.ProcessRunner {
    private final class DataBox: @unchecked Sendable {
        var value = Data()
    }

    func run(
        executablePath: String,
        arguments: [String],
        currentDirectoryPath: String?,
        timeout: TimeInterval
    ) async throws -> WeChatKeyPreparationService.RunOutcome {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let outcome = try Self.blockingRun(
                        executablePath: executablePath,
                        arguments: arguments,
                        currentDirectoryPath: currentDirectoryPath,
                        timeout: timeout)
                    continuation.resume(returning: outcome)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func blockingRun(
        executablePath: String,
        arguments: [String],
        currentDirectoryPath: String?,
        timeout: TimeInterval
    ) throws -> WeChatKeyPreparationService.RunOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let currentDirectoryPath {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath)
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let killer = DispatchWorkItem { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stdoutBox.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderrBox.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()
        killer.cancel()

        return WeChatKeyPreparationService.RunOutcome(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutBox.value, as: UTF8.self),
            stderr: String(decoding: stderrBox.value, as: UTF8.self))
    }
}

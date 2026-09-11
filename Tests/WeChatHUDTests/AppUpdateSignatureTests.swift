import XCTest
@testable import WeChatHUD

/// The self-updater used to install whatever the release contained.
///
/// Its only integrity check was an optional `.sha256` sidecar that ships in the
/// same release as the archive it validates, and the bundle identity/version it
/// compared came from the incoming bundle's own `Info.plist`. Neither says who
/// built the archive. These tests exercise the real Security-framework checks
/// (unsigned, ad-hoc signed, tampered) and the policy around them.
final class AppUpdateSignatureTests: XCTestCase {

    private func makeFakeApp(at url: URL, version: String = "1.3.0") throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>(AppUpdateService.productionIdentifier)</string>
            <key>CFBundleExecutable</key><string>WeChatHUD</string>
            <key>CFBundleShortVersionString</key><string>(version)</string>
            <key>CFBundleVersion</key><string>(version)</string>
        </dict></plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        // A real Mach-O, so codesign has an executable to seal.
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: macOS.appendingPathComponent("WeChatHUD")
        )
        return url
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-signature-(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func codesign(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func service(
        for app: URL,
        signatureTeamIdentifier: @escaping @Sendable (URL) throws -> String?,
        runningTeamIdentifier: @escaping @Sendable () -> String?
    ) -> AppUpdateService {
        AppUpdateService(
            currentVersion: AppVersion("1.2.0")!,
            currentBundleIdentifier: AppUpdateService.productionIdentifier,
            currentBundleURL: app,
            signatureTeamIdentifier: signatureTeamIdentifier,
            runningTeamIdentifier: runningTeamIdentifier
        )
    }

    // MARK: - Real Security-framework behaviour

    func testUnsignedArchiveFailsStaticValidation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFakeApp(at: root.appendingPathComponent("WeChatHUD.app"))

        XCTAssertThrowsError(try AppUpdateSignature.teamIdentifier(ofAppAt: app)) { error in
            XCTAssertEqual(error as? AppUpdateError, .unsignedArchive)
        }
    }

    func testAdHocSignedArchiveValidatesWithoutATeamIdentifier() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFakeApp(at: root.appendingPathComponent("WeChatHUD.app"))
        guard try codesign(["--force", "--sign", "-", app.path]) == 0 else {
            throw XCTSkip("codesign is unavailable in this environment")
        }

        XCTAssertNil(
            try AppUpdateSignature.teamIdentifier(ofAppAt: app),
            "an ad-hoc signature is valid but carries no Team ID, so it can never be pinned"
        )
    }

    func testTamperingAfterSigningIsDetected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFakeApp(at: root.appendingPathComponent("WeChatHUD.app"))
        guard try codesign(["--force", "--sign", "-", app.path]) == 0 else {
            throw XCTSkip("codesign is unavailable in this environment")
        }

        try Data("tampered".utf8).write(to: app.appendingPathComponent("Contents/MacOS/WeChatHUD"))

        XCTAssertThrowsError(
            try AppUpdateSignature.teamIdentifier(ofAppAt: app),
            "a modified sealed resource must fail validation"
        )
    }

    // MARK: - Policy

    func testVerifyIncomingSignatureRejectsAnUnsignedArchive() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFakeApp(at: root.appendingPathComponent("WeChatHUD.app"))
        let subject = service(
            for: app,
            signatureTeamIdentifier: { try AppUpdateSignature.teamIdentifier(ofAppAt: $0) },
            runningTeamIdentifier: { "TEAM123" }
        )

        XCTAssertThrowsError(try subject.verifyIncomingSignature(of: app)) { error in
            XCTAssertEqual(error as? AppUpdateError, .unsignedArchive)
        }
    }

    func testVerifyIncomingSignatureRejectsADifferentTeam() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFakeApp(at: root.appendingPathComponent("WeChatHUD.app"))
        let subject = service(
            for: app,
            signatureTeamIdentifier: { _ in "OTHERTEAM" },
            runningTeamIdentifier: { "TEAM123" }
        )

        XCTAssertThrowsError(try subject.verifyIncomingSignature(of: app)) { error in
            XCTAssertEqual(error as? AppUpdateError, .signatureMismatch)
        }
    }

    func testVerifyIncomingSignatureRefusesWhenTheRunningBuildHasNoIdentity() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFakeApp(at: root.appendingPathComponent("WeChatHUD.app"))
        let subject = service(
            for: app,
            signatureTeamIdentifier: { _ in "TEAM123" },
            runningTeamIdentifier: { nil }
        )

        XCTAssertThrowsError(try subject.verifyIncomingSignature(of: app)) { error in
            XCTAssertEqual(error as? AppUpdateError, .signingIdentityUnavailable)
        }
    }

    func testVerifyIncomingSignatureAcceptsAMatchingTeam() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFakeApp(at: root.appendingPathComponent("WeChatHUD.app"))
        let subject = service(
            for: app,
            signatureTeamIdentifier: { url in
                XCTAssertTrue(url.path.hasSuffix("WeChatHUD.app"))
                return "TEAM123"
            },
            runningTeamIdentifier: { "TEAM123" }
        )

        XCTAssertNoThrow(try subject.verifyIncomingSignature(of: app))
    }
}

import XCTest
@testable import WeChatHUD

final class ClassifierCLITests: XCTestCase {
    func testClassifyRealOutputRejectsFixturesPath() {
        XCTAssertTrue(ClassifierCLI.isUnsafeClassifyRealOutputPath(
            "Tests/Fixtures/labeled_messages_private.json",
            currentDirectory: "/tmp/WeChatHUD"
        ))
    }

    func testClassifyRealOutputRejectsPackagePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wchud-cli-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("// package marker\n".utf8).write(to: root.appendingPathComponent("Package.swift"))

        let out = root.appendingPathComponent("scratch/raw_messages.json").path

        XCTAssertTrue(ClassifierCLI.isUnsafeClassifyRealOutputPath(out, currentDirectory: "/tmp"))
    }

    func testClassifyRealOutputAllowsTmpPathOutsidePackage() {
        let out = "/tmp/wchud_classify_real_\(UUID().uuidString).json"

        XCTAssertFalse(ClassifierCLI.isUnsafeClassifyRealOutputPath(out, currentDirectory: "/tmp"))
    }
}

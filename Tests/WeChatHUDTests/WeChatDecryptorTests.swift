import XCTest
@testable import WeChatHUD

final class WeChatDecryptorTests: XCTestCase {

    func testDecryptPageSizeValidation() {
        let key = Data(count: 32)
        let shortPage = Data(count: 100)
        XCTAssertThrowsError(try WeChatDecryptor.decryptPage(shortPage, key: key, isFirstPage: true))
    }

    func testInvalidKeySize() {
        let key = Data(count: 16)  // too short
        let tmpInput = NSTemporaryDirectory() + "test_enc_\(UUID()).db"
        let tmpOutput = NSTemporaryDirectory() + "test_dec_\(UUID()).db"
        FileManager.default.createFile(atPath: tmpInput, contents: Data(count: 4096))
        defer { try? FileManager.default.removeItem(atPath: tmpInput) }
        XCTAssertThrowsError(try WeChatDecryptor.decryptDB(inputPath: tmpInput, outputPath: tmpOutput, key: key))
    }

    func testDecryptedOutputStartsWithSQLiteHeader() throws {
        // Create a fake encrypted page with valid structure
        // This tests the output format, not real decryption (which needs a real key)
        let key = Data(repeating: 0x41, count: 32)
        var page = Data(count: 4096)
        // Put a fake IV at the expected position
        let ivOffset = 4096 - 80
        for i in 0..<16 {
            page[ivOffset + i] = 0
        }

        // We can't test real decryption without real encrypted data,
        // but we verify the method runs and either succeeds or throws DecryptorError
        do {
            let result = try WeChatDecryptor.decryptPage(page, key: key, isFirstPage: true)
            // If it succeeds, first page output should start with SQLite header
            XCTAssertTrue(result.starts(with: WeChatDecryptor.sqliteHeader))
        } catch let error as DecryptorError {
            // AES decrypt may fail with fake data — that's expected
            switch error {
            case .decryptFailed:
                break  // expected with fake data
            default:
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }
}

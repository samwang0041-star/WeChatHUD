import XCTest
import CommonCrypto
@testable import WeChatHUD

final class WeChatDecryptorTests: XCTestCase {

    // MARK: - Page-level tests

    func testDecryptPageSizeValidation() {
        let key = Data(count: 32)
        let shortPage = Data(count: 100)
        XCTAssertThrowsError(try WeChatDecryptor.decryptPage(shortPage, key: key, isFirstPage: true))
    }

    func testDecryptPageWithValidEncryptedData() throws {
        // Build a synthetic encrypted page that WeChatDecryptor can decrypt.
        // Layout (first page): [salt(16)] [ciphertext(4000)] [IV(16)] [HMAC(64)]
        let key = Data(repeating: 0xAA, count: 32)
        let iv = Data(repeating: 0xBB, count: 16)

        // Plaintext body for first page: pageSize - saltSize(16) - reserveSize(80) = 4000 bytes
        let plaintext = Data(repeating: 0x42, count: 4000)

        // Encrypt with AES-256-CBC, no padding (plaintext is exact multiple of block size)
        var ciphertext = Data(count: plaintext.count + kCCBlockSizeAES128)
        var ciphertextLen = 0
        let status = ciphertext.withUnsafeMutableBytes { cBuf in
            plaintext.withUnsafeBytes { pBuf in
                iv.withUnsafeBytes { ivBuf in
                    key.withUnsafeBytes { keyBuf -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),  // no padding
                            keyBuf.baseAddress, 32,
                            ivBuf.baseAddress,
                            pBuf.baseAddress, plaintext.count,
                            cBuf.baseAddress, cBuf.count,
                            &ciphertextLen
                        )
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        ciphertext.count = ciphertextLen
        XCTAssertEqual(ciphertext.count, 4000)

        // Assemble the page: salt(16) + ciphertext(4000) + IV(16) + HMAC_placeholder(64)
        var page = Data(count: 16)  // salt
        page.append(ciphertext)
        page.append(iv)
        page.append(Data(count: 64))  // HMAC placeholder
        XCTAssertEqual(page.count, 4096)

        let result = try WeChatDecryptor.decryptPage(page, key: key, isFirstPage: true)
        XCTAssertEqual(result.count, 4096)
        // First page output starts with SQLite header
        XCTAssertTrue(result.starts(with: WeChatDecryptor.sqliteHeader))
        // The decrypted body after the header should match our plaintext
        let bodyStart = WeChatDecryptor.sqliteHeader.count
        let bodyEnd = 4096 - 80  // reserveSize
        let decryptedBody = result.subdata(in: bodyStart..<bodyEnd)
        XCTAssertEqual(decryptedBody, plaintext)
    }

    func testDecryptPageNonFirstPage() throws {
        // Non-first page: [ciphertext(4016)] [IV(16)] [HMAC(64)]
        let key = Data(repeating: 0xCC, count: 32)
        let iv = Data(repeating: 0xDD, count: 16)
        let plaintext = Data(repeating: 0x55, count: 4016)  // no salt subtracted

        var ciphertext = Data(count: plaintext.count + kCCBlockSizeAES128)
        var ciphertextLen = 0
        let status = ciphertext.withUnsafeMutableBytes { cBuf in
            plaintext.withUnsafeBytes { pBuf in
                iv.withUnsafeBytes { ivBuf in
                    key.withUnsafeBytes { keyBuf -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBuf.baseAddress, 32,
                            ivBuf.baseAddress,
                            pBuf.baseAddress, plaintext.count,
                            cBuf.baseAddress, cBuf.count,
                            &ciphertextLen
                        )
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        ciphertext.count = ciphertextLen

        var page = ciphertext
        page.append(iv)
        page.append(Data(count: 64))
        XCTAssertEqual(page.count, 4096)

        let result = try WeChatDecryptor.decryptPage(page, key: key, isFirstPage: false)
        XCTAssertEqual(result.count, 4096)
        // Non-first page should NOT start with SQLite header
        XCTAssertFalse(result.starts(with: WeChatDecryptor.sqliteHeader))
        // Body should match plaintext
        let decryptedBody = result.subdata(in: 0..<4016)
        XCTAssertEqual(decryptedBody, plaintext)
    }

    // MARK: - Full DB decryption (end-to-end)

    func testInvalidKeySize() {
        let key = Data(count: 16)  // too short
        let tmpInput = NSTemporaryDirectory() + "test_enc_\(UUID()).db"
        let tmpOutput = NSTemporaryDirectory() + "test_dec_\(UUID()).db"
        FileManager.default.createFile(atPath: tmpInput, contents: Data(count: 4096))
        defer { try? FileManager.default.removeItem(atPath: tmpInput) }
        XCTAssertThrowsError(try WeChatDecryptor.decryptDB(inputPath: tmpInput, outputPath: tmpOutput, key: key))
    }

    func testDecryptDBFileTooSmall() {
        let key = Data(count: 32)
        let tmpInput = NSTemporaryDirectory() + "test_small_\(UUID()).db"
        let tmpOutput = NSTemporaryDirectory() + "test_dec_\(UUID()).db"
        FileManager.default.createFile(atPath: tmpInput, contents: Data(count: 100))
        defer { try? FileManager.default.removeItem(atPath: tmpInput) }
        XCTAssertThrowsError(try WeChatDecryptor.decryptDB(inputPath: tmpInput, outputPath: tmpOutput, key: key)) { error in
            guard case DecryptorError.readFailed = error else {
                XCTFail("Expected readFailed, got \(error)")
                return
            }
        }
    }

    func testDecryptDBMissingFile() {
        let key = Data(count: 32)
        XCTAssertThrowsError(try WeChatDecryptor.decryptDB(
            inputPath: "/nonexistent/path.db",
            outputPath: "/tmp/out.db",
            key: key
        )) { error in
            guard case DecryptorError.readFailed = error else {
                XCTFail("Expected readFailed, got \(error)")
                return
            }
        }
    }

    func testDecryptDBEndToEnd() throws {
        // Create a 2-page encrypted DB with known content
        let key = Data(repeating: 0xAA, count: 32)
        let iv1 = Data(repeating: 0x11, count: 16)
        let iv2 = Data(repeating: 0x22, count: 16)

        // Page 1: salt(16) + ciphertext(4000) + IV(16) + HMAC(64)
        let plain1 = Data(repeating: 0x41, count: 4000)
        let cipher1 = try aesEncrypt(plaintext: plain1, key: key, iv: iv1)

        var page1 = Data(count: 16)  // salt
        page1.append(cipher1)
        page1.append(iv1)
        page1.append(Data(count: 64))

        // Page 2: ciphertext(4016) + IV(16) + HMAC(64)
        let plain2 = Data(repeating: 0x42, count: 4016)
        let cipher2 = try aesEncrypt(plaintext: plain2, key: key, iv: iv2)

        var page2 = cipher2
        page2.append(iv2)
        page2.append(Data(count: 64))

        var encDB = page1
        encDB.append(page2)

        let tmpInput = NSTemporaryDirectory() + "test_e2e_enc_\(UUID()).db"
        let tmpOutput = NSTemporaryDirectory() + "test_e2e_dec_\(UUID()).db"
        defer {
            try? FileManager.default.removeItem(atPath: tmpInput)
            try? FileManager.default.removeItem(atPath: tmpOutput)
        }

        FileManager.default.createFile(atPath: tmpInput, contents: encDB)
        try WeChatDecryptor.decryptDB(inputPath: tmpInput, outputPath: tmpOutput, key: key)

        let output = try Data(contentsOf: URL(fileURLWithPath: tmpOutput))
        XCTAssertEqual(output.count, 8192)  // 2 pages

        // Page 1 should start with SQLite header
        XCTAssertTrue(output.starts(with: WeChatDecryptor.sqliteHeader))

        // Verify decrypted body of page 1
        let body1Start = WeChatDecryptor.sqliteHeader.count
        let body1End = 4096 - 80
        XCTAssertEqual(output.subdata(in: body1Start..<body1End), plain1)

        // Verify decrypted body of page 2
        let body2Start = 4096
        let body2End = 4096 + 4016
        XCTAssertEqual(output.subdata(in: body2Start..<body2End), plain2)
    }

    // MARK: - WAL tests

    func testApplyWALSkipsMissingFile() throws {
        let key = Data(count: 32)
        // Should not throw when WAL file doesn't exist
        try WeChatDecryptor.applyWAL(
            dbPath: "/tmp/nonexistent.db",
            walPath: "/tmp/nonexistent.wal",
            key: key
        )
    }

    func testApplyWALRejectsIncompleteHeader() throws {
        let key = Data(count: 32)
        let walPath = NSTemporaryDirectory() + "test_wal_small_\(UUID()).wal"
        // Incomplete headers must fail so callers retry instead of marking a sync successful.
        FileManager.default.createFile(atPath: walPath, contents: Data(count: 10))
        defer { try? FileManager.default.removeItem(atPath: walPath) }

        XCTAssertThrowsError(try WeChatDecryptor.applyWAL(
            dbPath: "/tmp/nonexistent.db",
            walPath: walPath,
            key: key
        ))
    }

    // MARK: - Helpers

    private func aesEncrypt(plaintext: Data, key: Data, iv: Data) throws -> Data {
        var ciphertext = Data(count: plaintext.count + kCCBlockSizeAES128)
        var ciphertextLen = 0
        let status = ciphertext.withUnsafeMutableBytes { cBuf in
            plaintext.withUnsafeBytes { pBuf in
                iv.withUnsafeBytes { ivBuf in
                    key.withUnsafeBytes { keyBuf -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBuf.baseAddress, 32,
                            ivBuf.baseAddress,
                            pBuf.baseAddress, plaintext.count,
                            cBuf.baseAddress, cBuf.count,
                            &ciphertextLen
                        )
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else {
            throw DecryptorError.decryptFailed("Test encrypt failed: \(status)")
        }
        ciphertext.count = ciphertextLen
        return ciphertext
    }
}

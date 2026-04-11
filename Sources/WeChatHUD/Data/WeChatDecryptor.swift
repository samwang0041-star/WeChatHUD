import Foundation
import CommonCrypto

enum DecryptorError: Error {
    case invalidKey(String)
    case readFailed(String)
    case decryptFailed(String)
    case writeFailed(String)
}

struct WeChatDecryptor {
    static let pageSize = 4096
    static let keySize = 32
    static let saltSize = 16
    static let reserveSize = 80  // IV(16) + HMAC-SHA512(64)
    static let ivSize = 16
    static let sqliteHeader = "SQLite format 3\0".data(using: .ascii)!

    /// Decrypt a single page of an encrypted WeChat SQLite database.
    /// Page 1 has salt in first 16 bytes; pages 2+ are fully encrypted.
    static func decryptPage(_ pageData: Data, key: Data, isFirstPage: Bool) throws -> Data {
        guard pageData.count == pageSize else {
            throw DecryptorError.decryptFailed("Page size mismatch: \(pageData.count)")
        }

        // Work with a zero-based copy so all index math is straightforward.
        let page = Data(pageData)
        let ivOffset = pageSize - reserveSize
        let iv = page.subdata(in: ivOffset..<(ivOffset + ivSize))

        let encStart = isFirstPage ? saltSize : 0
        let encData = page.subdata(in: encStart..<ivOffset)

        var decrypted = Data(count: encData.count + kCCBlockSizeAES128)
        var decryptedLen = 0

        let status = decrypted.withUnsafeMutableBytes { decBuf in
            encData.withUnsafeBytes { encBuf in
                iv.withUnsafeBytes { ivBuf in
                    key.withUnsafeBytes { keyBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, keySize,
                            ivBuf.baseAddress,
                            encBuf.baseAddress, encData.count,
                            decBuf.baseAddress, decBuf.count,
                            &decryptedLen
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw DecryptorError.decryptFailed("CCCrypt failed: \(status)")
        }

        decrypted.count = decryptedLen
        let padding = Data(count: reserveSize)

        if isFirstPage {
            return sqliteHeader + decrypted + padding
        } else {
            return decrypted + padding
        }
    }

    /// Decrypt an entire WeChat SQLite database file.
    static func decryptDB(inputPath: String, outputPath: String, key: Data) throws {
        guard key.count == keySize else {
            throw DecryptorError.invalidKey("Key must be \(keySize) bytes, got \(key.count)")
        }

        guard let inputData = FileManager.default.contents(atPath: inputPath) else {
            throw DecryptorError.readFailed("Cannot read \(inputPath)")
        }

        guard inputData.count >= pageSize else {
            throw DecryptorError.readFailed("File too small: \(inputData.count) bytes")
        }

        let pageCount = inputData.count / pageSize
        var output = Data(capacity: pageCount * pageSize)

        for i in 0..<pageCount {
            let offset = i * pageSize
            let pageData = inputData.subdata(in: offset..<(offset + pageSize))
            let decrypted = try decryptPage(pageData, key: key, isFirstPage: i == 0)
            output.append(decrypted)
        }

        guard FileManager.default.createFile(atPath: outputPath, contents: output) else {
            throw DecryptorError.writeFailed("Cannot write to \(outputPath)")
        }
    }

    /// Apply WAL (Write-Ahead Log) patches to a decrypted database.
    /// WAL contains newer writes that haven't been checkpointed yet.
    static func applyWAL(dbPath: String, walPath: String, key: Data) throws {
        guard FileManager.default.fileExists(atPath: walPath) else { return }
        guard var dbData = FileManager.default.contents(atPath: dbPath) else {
            throw DecryptorError.readFailed("Cannot read \(dbPath)")
        }
        guard let walData = FileManager.default.contents(atPath: walPath) else { return }

        let walHeaderSize = 32
        let frameHeaderSize = 24

        guard walData.count > walHeaderSize else { return }

        // WAL header salt (bytes 16-24)
        let walSalt1 = walData.subdata(in: 16..<20)
        let walSalt2 = walData.subdata(in: 20..<24)

        var offset = walHeaderSize
        while offset + frameHeaderSize + pageSize <= walData.count {
            // Frame header: page number (bytes 0-4, big-endian)
            let pgnoBytes = walData.subdata(in: offset..<(offset + 4))
            let pgno = pgnoBytes.withUnsafeBytes { buf -> UInt32 in
                UInt32(bigEndian: buf.loadUnaligned(as: UInt32.self))
            }

            // Verify frame salt matches WAL header salt
            let frameSalt1 = walData.subdata(in: (offset + 8)..<(offset + 12))
            let frameSalt2 = walData.subdata(in: (offset + 12)..<(offset + 16))
            guard frameSalt1 == walSalt1 && frameSalt2 == walSalt2 else {
                offset += frameHeaderSize + pageSize
                continue
            }

            // Decrypt frame page data
            let frameStart = offset + frameHeaderSize
            let frameData = walData.subdata(in: frameStart..<(frameStart + pageSize))
            let decrypted = try decryptPage(frameData, key: key, isFirstPage: pgno == 1)

            // Patch into DB at correct page position
            let dbOffset = Int(pgno - 1) * pageSize
            if dbOffset + pageSize <= dbData.count {
                dbData.replaceSubrange(dbOffset..<(dbOffset + pageSize), with: decrypted)
            }

            offset += frameHeaderSize + pageSize
        }

        guard FileManager.default.createFile(atPath: dbPath, contents: dbData) else {
            throw DecryptorError.writeFailed("Cannot write patched DB to \(dbPath)")
        }
    }
}

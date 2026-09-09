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

        guard key.count == keySize else {
            throw DecryptorError.invalidKey("Key must be \(keySize) bytes")
        }
        // Work with a zero-based copy so all index math is straightforward.
        let page = Data(pageData)
        let ivOffset = pageSize - reserveSize
        let iv = page.subdata(in: ivOffset..<(ivOffset + ivSize))

        let encStart = isFirstPage ? saltSize : 0
        let encData = page.subdata(in: encStart..<ivOffset)

        // SQLCipher does NOT apply PKCS7 padding — the ciphertext region is
        // an exact multiple of AES block size and decrypts to the same length.
        // Passing kCCOptionPKCS7Padding makes CCCrypt strip bogus trailing
        // bytes and produces a corrupt page.
        var decrypted = Data(count: encData.count)
        var decryptedLen = 0

        let status = decrypted.withUnsafeMutableBytes { decBuf in
            encData.withUnsafeBytes { encBuf in
                iv.withUnsafeBytes { ivBuf in
                    key.withUnsafeBytes { keyBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),  // no padding
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
    ///
    /// Multi-threaded, zero-Swift-allocation hot path: pre-allocate one raw
    /// output buffer, let `DispatchQueue.concurrentPerform` spread pages
    /// across all cores, and decrypt each page directly into its slot. No
    /// per-page `Data.subdata` / `Data.append` — everything stays in raw
    /// pointer space until the final wrap.
    static func decryptDB(inputPath: String, outputPath: String, key: Data) throws {
        guard key.count == keySize else {
            throw DecryptorError.invalidKey("Key must be \(keySize) bytes, got \(key.count)")
        }
        guard let inputData = FileManager.default.contents(atPath: inputPath) else {
            throw DecryptorError.readFailed("Cannot read \(inputPath)")
        }
        guard inputData.count >= pageSize, inputData.count % pageSize == 0 else {
            throw DecryptorError.readFailed("File too small: \(inputData.count) bytes")
        }

        let pageCount = inputData.count / pageSize
        let totalSize = pageCount * pageSize

        guard let outputPtr = malloc(totalSize) else {
            throw DecryptorError.decryptFailed("malloc(\(totalSize)) failed")
        }
        var ownsOutput = true
        defer { if ownsOutput { free(outputPtr) } }

        // Collect the first error; workers bail out early if one is set.
        let errorLock = NSLock()
        var firstError: DecryptorError?

        try inputData.withUnsafeBytes { (inputBuf: UnsafeRawBufferPointer) in
            let inputBase = inputBuf.baseAddress!

            DispatchQueue.concurrentPerform(iterations: pageCount) { i in
                // Early bail-out if another worker already failed.
                errorLock.lock()
                let hasError = firstError != nil
                errorLock.unlock()
                if hasError { return }

                let offset = i * pageSize
                let pageIn = UnsafeRawBufferPointer(
                    start: inputBase.advanced(by: offset),
                    count: pageSize
                )
                let pageOut = outputPtr.advanced(by: offset)

                do {
                    try decryptPageInPlace(
                        pageIn: pageIn,
                        pageOut: pageOut,
                        key: key,
                        isFirstPage: i == 0
                    )
                } catch {
                    errorLock.lock()
                    if firstError == nil {
                        firstError = (error as? DecryptorError)
                            ?? .decryptFailed("page \(i): \(error)")
                    }
                    errorLock.unlock()
                }
            }

            if let err = firstError { throw err }
        }

        // Hand the raw buffer to Data; it will call free() on destruction.
        let outputData = Data(bytesNoCopy: outputPtr, count: totalSize, deallocator: .free)
        ownsOutput = false

        guard FileManager.default.createFile(atPath: outputPath, contents: outputData, attributes: [.posixPermissions: 0o600]) else {
            throw DecryptorError.writeFailed("Cannot write to \(outputPath)")
        }
    }

    /// Decrypt a single page directly into a caller-provided output slot.
    /// Used by the parallel `decryptDB` path to avoid per-page Swift
    /// allocations. Layout of `pageOut` after this call:
    ///
    /// - first page: `[SQLite header (16 bytes) | decrypted body (4000) | zero reserve (80)]`
    /// - other pages: `[decrypted body (4016) | zero reserve (80)]`
    private static func decryptPageInPlace(
        pageIn: UnsafeRawBufferPointer,
        pageOut: UnsafeMutableRawPointer,
        key: Data,
        isFirstPage: Bool
    ) throws {
        let ivOffset = pageSize - reserveSize
        let encStart = isFirstPage ? saltSize : 0
        let encLen = ivOffset - encStart

        let ivPtr = pageIn.baseAddress!.advanced(by: ivOffset)
        let encPtr = pageIn.baseAddress!.advanced(by: encStart)
        let decDst = pageOut.advanced(by: encStart)

        var decryptedLen = 0
        let status = key.withUnsafeBytes { keyBuf -> Int32 in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(0),  // no padding — SQLCipher pages are exact multiples
                keyBuf.baseAddress, keySize,
                ivPtr,
                encPtr, encLen,
                decDst, encLen,
                &decryptedLen
            )
        }
        guard status == kCCSuccess else {
            throw DecryptorError.decryptFailed("CCCrypt failed: \(status)")
        }

        // Zero the 80-byte reserve region at the end of the page.
        memset(pageOut.advanced(by: ivOffset), 0, reserveSize)

        // Page 1: overwrite the first 16 bytes with the plaintext SQLite header.
        if isFirstPage {
            sqliteHeader.withUnsafeBytes { hdrBuf in
                pageOut.copyMemory(from: hdrBuf.baseAddress!, byteCount: saltSize)
            }
        }
    }

    /// Replay only committed, checksum-valid WAL frames into an atomically
    /// published cache copy. Never patch WeChat's source database.
    static func applyWAL(dbPath: String, walPath: String, key: Data) throws {
        guard FileManager.default.fileExists(atPath: walPath) else { return }
        guard let walData = FileManager.default.contents(atPath: walPath) else {
            throw DecryptorError.readFailed("Cannot read WAL snapshot")
        }
        let plan = try WALReplay.plan(walData, expectedPageSize: pageSize)
        guard let pageCount = plan.databasePageCount else { return }
        let fm = FileManager.default
        let staging = dbPath + ".wal-" + UUID().uuidString
        try fm.copyItem(atPath: dbPath, toPath: staging)
        defer { try? fm.removeItem(atPath: staging) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging)
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: staging))
        do {
            for frame in plan.frames where frame.pageNumber <= pageCount {
                let decrypted = try decryptPage(frame.data, key: key, isFirstPage: frame.pageNumber == 1)
                try handle.seek(toOffset: UInt64(frame.pageNumber - 1) * UInt64(pageSize))
                try handle.write(contentsOf: decrypted)
            }
            // Committed database size may grow or shrink; both are valid WAL transactions.
            try handle.truncate(atOffset: UInt64(pageCount) * UInt64(pageSize))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        // POSIX rename atomically replaces the destination; existing readers retain
        // their previous inode and new readers see only the finished snapshot.
        guard rename(staging, dbPath) == 0 else {
            throw DecryptorError.writeFailed("Cannot publish WAL snapshot")
        }
    }
}

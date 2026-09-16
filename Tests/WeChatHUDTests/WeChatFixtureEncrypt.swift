import CryptoKit
import Foundation
@testable import WeChatHUD

/// Shared helpers for building SQLCipher-format encrypted fixtures. Since
/// `WeChatDecryptor.decryptDB` now verifies the page-1 HMAC (a zeroed or
/// garbage MAC slot means a wrong key, not a fixture), every encrypted test
/// database must carry a *real* page MAC.
enum WeChatFixtureEncrypt {
    /// The 64-byte page MAC SQLCipher stores in the page reserve:
    /// mac_key = PBKDF2-HMAC-SHA512(key, salt ^ 0x3A, 2), input =
    /// encrypted body + IV + uint32LE(pageNumber).
    ///
    /// - `dbSalt`: the database salt — page 1's leading 16 bytes. All pages
    ///   derive their MAC key from it, even though only page 1 stores it.
    /// - `bodyWithIV`: bytes 16..<4032 for page 1, bytes 0..<4032 otherwise.
    static func pageMAC(key: Data, dbSalt: Data, bodyWithIV: Data, pageNumber: UInt32) -> Data {
        let macSalt = Data(dbSalt.map { $0 ^ 0x3A })
        guard let macKey = WeChatDecryptor.deriveMacKey(key: key, macSalt: macSalt) else {
            preconditionFailure("PBKDF2 failed for fixture key")
        }
        var input = bodyWithIV
        var le = pageNumber.littleEndian
        withUnsafeBytes(of: &le) { input.append(contentsOf: $0) }
        return Data(HMAC<SHA512>.authenticationCode(for: input, using: SymmetricKey(data: macKey)))
    }

    /// Assemble one encrypted page: [salt?|cipher|iv|mac].
    /// `salt` is included only for page 1.
    static func page(key: Data, dbSalt: Data, cipher: Data, iv: Data, pageNumber: UInt32) -> Data {
        var bodyWithIV = cipher
        bodyWithIV.append(iv)
        let mac = pageMAC(key: key, dbSalt: dbSalt, bodyWithIV: bodyWithIV, pageNumber: pageNumber)
        var page = pageNumber == 1 ? dbSalt : Data()
        page.append(cipher)
        page.append(iv)
        page.append(mac)
        return page
    }
}

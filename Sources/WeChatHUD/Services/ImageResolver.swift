import CryptoKit
import Foundation

/// Attempts to locate WeChat image files for AI analysis.
/// This is a best-effort resolver — image files may not be accessible
/// due to macOS sandbox restrictions or WeChat storage changes.
enum ImageResolver {

    /// Attempt to find an image file for a given message in a chat.
    /// Returns the file path if found, nil otherwise.
    /// Prefers thumbnails (smaller, faster to analyze).
    ///
    /// - Parameters:
    ///   - chatUsername: The chat's WeChat username (used to narrow down directory search).
    ///   - messageId: The composite message UID from MessageInfo.id ("relPath/table/localId").
    ///   - dbDir: The WeChatReader.dbDir path (e.g. ".../Msg/").
    static func resolve(chatUsername: String, messageId: String, dbDir: String) -> String? {
        resolve(chatUsername: chatUsername, messageId: messageId, messageTime: 0, dbDir: dbDir)
    }

    /// Attempt to find a readable image file for a WeChat image message.
    /// Supports both older MessageTemp layouts and the newer xwechat_files
    /// `msg/attach/<chat-md5>/<yyyy-MM>/Img` layout.
    static func resolve(chatUsername: String, messageId: String, messageTime: Int, dbDir: String) -> String? {
        guard !dbDir.isEmpty else { return nil }

        // Extract the numeric localId from the composite id string "relPath/tableName/localId"
        let localId = messageId.split(separator: "/").last.map(String.init) ?? messageId

        if let path = resolveFromAttach(chatUsername: chatUsername, localId: localId, messageTime: messageTime, dbDir: dbDir) {
            return path
        }

        return resolveFromMessageTemp(localId: localId, dbDir: dbDir)
    }

    private static func resolveFromAttach(chatUsername: String, localId: String, messageTime: Int, dbDir: String) -> String? {
        let accountRoot = accountRoot(from: dbDir)
        let attachRoots = [
            "\(accountRoot)/msg/attach",
            "\(dbDir)/message/attach"
        ]

        for attachRoot in attachRoots where FileManager.default.fileExists(atPath: attachRoot) {
            let chatHash = md5Hex(chatUsername)
            let datePrefix = monthPrefix(unixTime: messageTime)
            let primaryDir = datePrefix.map { "\(attachRoot)/\(chatHash)/\($0)/Img" }

            if let primaryDir, let path = resolveFromImageDir(primaryDir, localId: localId, messageTime: messageTime) {
                return path
            }

            guard let chatDirs = try? FileManager.default.contentsOfDirectory(atPath: attachRoot) else { continue }
            let orderedDirs = ([chatHash] + chatDirs).uniqued()
            for chatDir in orderedDirs {
                let chatRoot = "\(attachRoot)/\(chatDir)"
                guard FileManager.default.fileExists(atPath: chatRoot) else { continue }

                let monthDirs: [String]
                if let datePrefix {
                    monthDirs = [datePrefix]
                } else {
                    monthDirs = (try? FileManager.default.contentsOfDirectory(atPath: chatRoot)) ?? []
                }

                for month in monthDirs {
                    let imageDir = "\(chatRoot)/\(month)/Img"
                    if let path = resolveFromImageDir(imageDir, localId: localId, messageTime: messageTime) {
                        return path
                    }
                }
            }
        }

        return nil
    }

    private static func resolveFromMessageTemp(localId: String, dbDir: String) -> String? {
        // WeChat stores images in MessageTemp directories one level above the Msg/ dbDir
        let basePath = (dbDir as NSString).deletingLastPathComponent
        let messageTemp = "\(basePath)/Message/MessageTemp"

        // Try to find the chat's temp directory
        // Chat directories are often hashed versions of the username
        guard let chatDirs = try? FileManager.default.contentsOfDirectory(atPath: messageTemp) else {
            return nil
        }

        for chatDir in chatDirs {
            // First: try thumb directory (smaller images, preferred for AI)
            let thumbPath = "\(messageTemp)/\(chatDir)/Thumb"
            if FileManager.default.fileExists(atPath: thumbPath),
               let thumbFiles = try? FileManager.default.contentsOfDirectory(atPath: thumbPath),
               let match = thumbFiles.first(where: { $0.contains(localId) }) {
                let fullPath = "\(thumbPath)/\(match)"
                if let path = imagePathForAnalysis(fullPath) {
                    return path
                }
            }

            // Second: try full Image directory
            let imagePath = "\(messageTemp)/\(chatDir)/Image"
            guard FileManager.default.fileExists(atPath: imagePath) else { continue }

            guard let files = try? FileManager.default.contentsOfDirectory(atPath: imagePath) else { continue }

            // WeChat image files often contain the localId in their name
            if let match = files.first(where: { $0.contains(localId) }) {
                let fullPath = "\(imagePath)/\(match)"
                if let path = imagePathForAnalysis(fullPath) {
                    return path
                }
            }
        }

        return nil
    }

    private static func resolveFromImageDir(_ imageDir: String, localId: String, messageTime: Int) -> String? {
        guard FileManager.default.fileExists(atPath: imageDir),
              let files = try? FileManager.default.contentsOfDirectory(atPath: imageDir) else {
            return nil
        }

        let exactMatches = files
            .filter { $0.contains(localId) }
            .sorted(by: imagePriority)
        for file in exactMatches {
            let path = "\(imageDir)/\(file)"
            if let analysisPath = imagePathForAnalysis(path) { return analysisPath }
        }

        guard messageTime > 0 else { return nil }
        let candidates = files
            .filter { !$0.hasSuffix("_h.dat") }
            .compactMap { file -> (path: String, delta: TimeInterval, priority: Int)? in
                let path = "\(imageDir)/\(file)"
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let modifiedAt = attrs[.modificationDate] as? Date else { return nil }
                let delta = abs(modifiedAt.timeIntervalSince1970 - Double(messageTime))
                guard delta <= 6 * 3600 else { return nil }
                return (path, delta, file.hasSuffix("_t.dat") ? 1 : 0)
            }
            .sorted {
                if $0.delta != $1.delta { return $0.delta < $1.delta }
                return $0.priority < $1.priority
            }

        for candidate in candidates.prefix(8) {
            if let analysisPath = imagePathForAnalysis(candidate.path) { return analysisPath }
        }

        return nil
    }

    /// Check if a file looks like an image based on extension and basic validation.
    private static func isImageFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        let imageExts = ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "tiff"]
        if imageExts.contains(ext) { return true }

        // WeChat sometimes stores images without extension — check file header
        guard let data = FileManager.default.contents(atPath: path),
              data.count >= 4 else { return false }

        let header = [UInt8](data.prefix(4))
        // JPEG: FF D8 FF
        if header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF { return true }
        // PNG: 89 50 4E 47
        if header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4E && header[3] == 0x47 { return true }
        // GIF: 47 49 46
        if header[0] == 0x47 && header[1] == 0x49 && header[2] == 0x46 { return true }

        return false
    }

    private static func readableImagePath(_ path: String) -> String? {
        if isImageFile(path) { return path }
        guard (path as NSString).pathExtension.lowercased() == "dat" else { return nil }
        return decodeXORImageIfPossible(path)
    }

    private static func imagePathForAnalysis(_ path: String) -> String? {
        if let readable = readableImagePath(path) { return readable }
        return (path as NSString).pathExtension.lowercased() == "dat" ? path : nil
    }

    private static func decodeXORImageIfPossible(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), data.count >= 16 else { return nil }
        guard let decoded = xorDecodedImage(data) else { return nil }

        let cacheDir = "\(NSHomeDirectory())/.wechat-hud/media-cache"
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        let key = md5Hex(path + ":\(data.count)")
        let output = "\(cacheDir)/\(key).\(decoded.ext)"
        if !FileManager.default.fileExists(atPath: output) {
            try? decoded.data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        return isImageFile(output) ? output : nil
    }

    private static func xorDecodedImage(_ data: Data) -> (data: Data, ext: String)? {
        let signatures: [(bytes: [UInt8], ext: String)] = [
            ([0xFF, 0xD8, 0xFF], "jpg"),
            ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "png"),
            ([0x47, 0x49, 0x46, 0x38, 0x37, 0x61], "gif"),
            ([0x47, 0x49, 0x46, 0x38, 0x39, 0x61], "gif"),
            ([0x52, 0x49, 0x46, 0x46], "webp")
        ]

        let bytes = [UInt8](data.prefix(16))
        for signature in signatures {
            let key = bytes[0] ^ signature.bytes[0]
            guard signature.bytes.indices.allSatisfy({ (bytes[$0] ^ key) == signature.bytes[$0] }) else {
                continue
            }
            if signature.ext == "webp" {
                let webp = [UInt8]("WEBP".utf8)
                guard webp.indices.allSatisfy({ (bytes[$0 + 8] ^ key) == webp[$0] }) else { continue }
            }
            let decoded = Data(data.map { $0 ^ key })
            return (decoded, signature.ext)
        }
        return nil
    }

    private static func accountRoot(from dbDir: String) -> String {
        let url = URL(fileURLWithPath: dbDir)
        if url.lastPathComponent == "db_storage" {
            return url.deletingLastPathComponent().path
        }
        return dbDir
    }

    private static func monthPrefix(unixTime: Int) -> String? {
        guard unixTime > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(unixTime))
        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        guard let year = comps.year, let month = comps.month else { return nil }
        return String(format: "%04d-%02d", year, month)
    }

    private static func md5Hex(_ value: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func imagePriority(_ lhs: String, _ rhs: String) -> Bool {
        imagePriority(lhs) < imagePriority(rhs)
    }

    private static func imagePriority(_ name: String) -> Int {
        if name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") || name.hasSuffix(".png") { return 0 }
        if name.hasSuffix(".dat") && !name.hasSuffix("_t.dat") && !name.hasSuffix("_h.dat") { return 1 }
        if name.hasSuffix("_t.dat") { return 2 }
        return 3
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

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
        guard !dbDir.isEmpty else { return nil }

        // Extract the numeric localId from the composite id string "relPath/tableName/localId"
        let localId = messageId.split(separator: "/").last.map(String.init) ?? messageId

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
                if isImageFile(fullPath) {
                    return fullPath
                }
            }

            // Second: try full Image directory
            let imagePath = "\(messageTemp)/\(chatDir)/Image"
            guard FileManager.default.fileExists(atPath: imagePath) else { continue }

            guard let files = try? FileManager.default.contentsOfDirectory(atPath: imagePath) else { continue }

            // WeChat image files often contain the localId in their name
            if let match = files.first(where: { $0.contains(localId) }) {
                let fullPath = "\(imagePath)/\(match)"
                if isImageFile(fullPath) {
                    return fullPath
                }
            }
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
}

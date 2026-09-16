import Foundation

/// Single place that creates HUD on-disk artifacts with owner-only permissions.
/// Directories are `0700`, files are `0600`. Existing trees are tightened on
/// open rather than left at whatever umask created them.
enum SecureFileManager {
    static let directoryPermissions: Int16 = 0o700
    static let filePermissions: Int16 = 0o600

    @discardableResult
    static func ensureDirectory(at path: String) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue { return false }
            // Tighten-and-verify: if the chmod fails (e.g. an attacker-owned
            // directory squatting a predictable name), fail closed rather than
            // trusting a path we cannot secure.
            do {
                try fm.setAttributes([.posixPermissions: NSNumber(value: directoryPermissions)], ofItemAtPath: path)
            } catch {
                return false
            }
            return posixMode(at: path) == directoryPermissions
        }
        do {
            try fm.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: directoryPermissions)]
            )
            try? fm.setAttributes([.posixPermissions: NSNumber(value: directoryPermissions)], ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func ensureFilePermissions(at path: String) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        do {
            try fm.setAttributes([.posixPermissions: NSNumber(value: filePermissions)], ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }

    /// Owner-only walk of `root`: every directory `0700`, every regular file `0600`.
    /// Symlinks are left untouched so we never chmod a target we do not own.
    @discardableResult
    static func hardenTree(at root: String) -> Int {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDirectory) else { return 0 }
        var changed = 0
        if isDirectory.boolValue {
            if ensureDirectory(at: root) { changed += 1 }
        } else {
            if ensureFilePermissions(at: root) { changed += 1 }
            return changed
        }
        guard let enumerator = fm.enumerator(atPath: root) else { return changed }
        while let relative = enumerator.nextObject() as? String {
            let path = (root as NSString).appendingPathComponent(relative)
            if isSymlink(path) { continue }
            var childIsDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &childIsDir) else { continue }
            if childIsDir.boolValue {
                if ensureDirectory(at: path) { changed += 1 }
            } else if ensureFilePermissions(at: path) {
                changed += 1
            }
        }
        return changed
    }

    static func posixMode(at path: String) -> Int16? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let number = attrs?[.posixPermissions] as? NSNumber else { return nil }
        return number.int16Value
    }

    static func isSymlink(_ path: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let type = attrs?[.type] as? FileAttributeType else { return false }
        return type == .typeSymbolicLink
    }
}

import AppKit

/// Reveal a file in Finder and report whether the viewer actually opened.
enum CompanionFinder {
    static func reveal(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            && NSWorkspace.shared.selectFile(
                url.path,
                inFileViewerRootedAtPath: url.deletingLastPathComponent().path
            )
    }

    static func openDesktop() -> Bool {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            return false
        }
        return NSWorkspace.shared.open(desktop)
    }
}

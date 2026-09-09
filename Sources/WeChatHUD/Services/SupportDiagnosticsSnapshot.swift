@preconcurrency import AppKit
import Foundation

/// A redacted snapshot of the current WeChatHUD process for explicit support
/// export. It intentionally describes this process only; it does not inspect
/// another app's accessibility tree or request a permission.
struct SupportDiagnosticsSnapshot: Equatable {
    enum BundleLocation: String, Equatable {
        case installed
        case preview
        case other
    }

    let osVersion: String
    let appVersion: String
    let bundleIdentifier: String
    let bundleLocation: BundleLocation
    let processIdentifier: Int32
    let accessibilityTrusted: Bool
    let previewMode: Bool

    static func current(
        bundle: Bundle = .main,
        bundleURL: URL? = nil,
        processIdentifier: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        accessibilityTrusted: Bool = AXIsProcessTrusted(),
        previewMode: Bool = PreviewRuntime.isEnabled,
        operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        applicationsRoots: [URL]? = nil
    ) -> Self {
        let identifier = bundle.bundleIdentifier ?? "unknown"
        let isPreview = previewMode || identifier == "com.wechathud.product-preview"
        return Self(
            osVersion: operatingSystemVersion,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            bundleIdentifier: identifier,
            bundleLocation: classifyBundleLocation(
                url: bundleURL ?? bundle.bundleURL,
                preview: isPreview,
                applicationsRoots: applicationsRoots
            ),
            processIdentifier: processIdentifier,
            accessibilityTrusted: accessibilityTrusted,
            previewMode: isPreview
        )
    }

    /// Only stable categories are exported; the bundle path itself is never
    /// included because it can contain the user's account name.
    static func classifyBundleLocation(
        url: URL,
        preview: Bool,
        applicationsRoots: [URL]? = nil
    ) -> BundleLocation {
        if preview { return .preview }
        guard url.pathExtension.lowercased() == "app" else { return .other }
        let appPath = url.standardizedFileURL.path
        let roots = applicationsRoots ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        if roots.contains(where: { root in
            let rootPath = root.standardizedFileURL.path
            return appPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }) {
            return .installed
        }
        return .other
    }

    var exportLines: [String] {
        [
            "操作系统：\(osVersion)",
            "应用版本：\(appVersion)",
            "Bundle ID：\(bundleIdentifier)",
            "应用位置类别：\(bundleLocation.rawValue)",
            "进程 PID：\(processIdentifier)",
            "当前进程 AXIsProcessTrusted：\(accessibilityTrusted ? "true" : "false")",
            "预览模式：\(previewMode ? "true" : "false")"
        ]
    }
}

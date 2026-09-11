@preconcurrency import AppKit
import Foundation

/// Extracts the parent process identifier passed to a relaunching instance.
/// Only positive decimal integers are accepted, and an instance may not name
/// itself as its own parent.
func relaunchParent(arguments: [String], currentPID: Int32) -> Int32? {
    guard let marker = arguments.firstIndex(of: "--relaunch-parent"),
          arguments.index(after: marker) < arguments.endIndex else {
        return nil
    }
    let value = arguments[arguments.index(after: marker)]
    guard !value.isEmpty,
          value.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
          let pid = Int32(value),
          pid > 0,
          pid != currentPID else {
        return nil
    }
    return pid
}

/// Relaunches the current application after connection settings have been
/// applied. The new process is started first; the current process is only
/// asked to terminate after Launch Services reports a successful launch.
@MainActor
enum AppRestartController {
    struct LaunchReceipt: Equatable, Sendable {
        let processIdentifier: Int32
        let isTerminated: Bool
        let bundleURL: URL
    }

    typealias Launcher = @Sendable (
        URL,
        NSWorkspace.OpenConfiguration,
        @escaping @Sendable (LaunchReceipt?, Error?) -> Void
    ) -> Void

    enum RestartError: Error, Equatable, LocalizedError {
        case previewMode
        case restartInProgress
        case bundleMissing(URL)
        case notApplicationBundle(URL)
        case launchFailed(String)

        var errorDescription: String? { userMessage }

        var userMessage: String {
            switch self {
            case .previewMode:
                return "演示模式不能重启应用"
            case .restartInProgress:
                return "应用正在重启，请稍候"
            case .bundleMissing:
                return "请从应用程序打开完整的 WeChatHUD 后再试"
            case .notApplicationBundle:
                return "请从应用程序打开完整的 WeChatHUD 后再试"
            case .launchFailed:
                return "新应用启动失败，当前应用仍在运行，请稍后重试"
            }
        }
    }

    private static var isRestarting = false

    /// Starts a fresh instance of this `.app`, then exits the old instance.
    ///
    /// `createsNewApplicationInstance` is deliberate: a normal Launch
    /// Services open may merely activate the already-running process.
    static func restart() async throws {
        try await restart(bundleURL: Bundle.main.bundleURL)
    }

    /// Internal seam for deterministic validation tests. Production callers
    /// should use `restart()` so the current bundle and NSWorkspace are used.
    static func restart(bundleURL: URL?,
                        launch: Launcher? = nil,
                        terminate: (() -> Void)? = nil) async throws {
        guard !PreviewRuntime.isEnabled else { throw RestartError.previewMode }
        guard !isRestarting else { throw RestartError.restartInProgress }
        isRestarting = true
        defer { isRestarting = false }

        guard let bundleURL else {
            throw RestartError.bundleMissing(URL(fileURLWithPath: ""))
        }
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw RestartError.bundleMissing(bundleURL)
        }
        guard bundleURL.pathExtension.lowercased() == "app",
              (try? bundleURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw RestartError.notApplicationBundle(bundleURL)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        let currentPID = Int32(ProcessInfo.processInfo.processIdentifier)
        configuration.arguments = ["--relaunch-parent", String(currentPID)]

        let open: Launcher = launch ?? { url, config, completion in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { application, error in
                guard let application else {
                    completion(nil, error)
                    return
                }
                guard let launchedBundleURL = application.bundleURL else {
                    completion(nil, nil)
                    return
                }
                completion(LaunchReceipt(
                    processIdentifier: application.processIdentifier,
                    isTerminated: application.isTerminated,
                    bundleURL: launchedBundleURL
                ), nil)
            }
        }
        let receipt: LaunchReceipt = try await withCheckedThrowingContinuation { continuation in
            open(bundleURL, configuration) { receipt, error in
                if let error {
                    _ = error
                    continuation.resume(throwing: RestartError.launchFailed("launch failed"))
                } else if let receipt {
                    continuation.resume(returning: receipt)
                } else {
                    continuation.resume(throwing: RestartError.launchFailed("系统未返回新实例"))
                }
            }
        }

        let expectedBundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let launchedBundle = receipt.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard receipt.processIdentifier != currentPID,
              !receipt.isTerminated,
              launchedBundle == expectedBundle else {
            throw RestartError.launchFailed("实例校验失败")
        }
        (terminate ?? { NSApp?.terminate(nil) })()
    }
}

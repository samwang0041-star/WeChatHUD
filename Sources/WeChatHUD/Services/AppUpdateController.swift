import Foundation
import Combine

/// Shared update state for settings, the menu bar, and the launch check.
@MainActor
final class AppUpdateController: ObservableObject {
    static let shared = AppUpdateController()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case installing
        case failed(String)
        case previewDisabled
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var offer: AppUpdateOffer?
    @Published private(set) var unpublishedVersion: AppVersion?
    @Published var config = AppUpdateConfig()

    private weak var store: HUDStore?
    private var launchTask: Task<Void, Never>?
    private var operation: Operation = .idle
    var serviceOverride: AppUpdateService?
    var restart: () async throws -> Void = { try await AppRestartController.restart() }

    private enum Operation {
        case idle
        case checking
        case installing
    }

    func bind(store: HUDStore) {
        self.store = store
        config = store.getSettingJSON(AppUpdateConfig.settingKey, as: AppUpdateConfig.self) ?? AppUpdateConfig()
        // Legacy builds persisted a `githubToken` inside this setting. The key
        // is no longer part of `AppUpdateConfig`, so decoding drops it on read —
        // but the raw JSON blob keeps it on disk. Re-save the decoded value once
        // so the token is not left sitting in the settings table.
        if let raw = store.getSetting(AppUpdateConfig.settingKey), raw.contains("githubToken") {
            saveConfig()
        }
        if PreviewRuntime.isEnabled {
            phase = .previewDisabled
            return
        }
        if let pending = config.pendingOffer {
            offer = pending
            phase = .available
        }
    }

    func saveConfig() {
        try? store?.setSettingJSON(AppUpdateConfig.settingKey, value: config)
    }

    func scheduleLaunchCheck(delay: TimeInterval = 12) {
        guard !PreviewRuntime.isEnabled else {
            phase = .previewDisabled
            return
        }
        guard config.autoCheckEnabled else { return }
        launchTask?.cancel()
        launchTask = Task { [weak self] in
            let nanoseconds = UInt64(max(delay, 0) * 1_000_000_000)
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self?.check(force: false, installIfEnabled: true)
        }
    }

    func check(force: Bool, installIfEnabled: Bool) async {
        if PreviewRuntime.isEnabled {
            phase = .previewDisabled
            return
        }
        guard operation == .idle else { return }
        if !force, !AppUpdatePolicy.shouldCheck(
            lastCheck: config.lastCheckDate,
            now: Date(),
            hasPendingOffer: config.pendingOffer != nil || offer != nil
        ) {
            return
        }
        operation = .checking
        phase = .checking
        defer {
            if operation == .checking { operation = .idle }
        }
        do {
            let result = try await makeService().check(repository: config.repository)
            unpublishedVersion = result.unpublishedInstaller
            if let next = result.offer {
                offer = next
                config.pendingOffer = next
                config.markChecked()
                saveConfig()
                phase = .available
                if installIfEnabled, config.autoInstallEnabled {
                    await installAvailable(reentrant: true)
                }
            } else if let missing = result.unpublishedInstaller {
                offer = nil
                config.pendingOffer = nil
                config.markChecked()
                saveConfig()
                phase = .failed(AppUpdateError.noInstallableAsset(missing.description).userMessage)
            } else {
                offer = nil
                config.pendingOffer = nil
                config.markChecked()
                saveConfig()
                phase = .upToDate
            }
        } catch let error as AppUpdateError {
            offer = config.pendingOffer
            phase = .failed(error.userMessage)
        } catch {
            offer = config.pendingOffer
            phase = .failed(AppUpdateError.httpStatus(0).userMessage)
        }
    }

    func installAvailable() async {
        await installAvailable(reentrant: false)
    }

    private func installAvailable(reentrant: Bool) async {
        guard let offer else { return }
        if PreviewRuntime.isEnabled {
            phase = .previewDisabled
            return
        }
        if !reentrant {
            guard operation == .idle else { return }
        }
        operation = .installing
        phase = .downloading
        defer { operation = .idle }
        do {
            let service = try makeService()
            phase = .installing
            _ = try await service.install(offer)
            config.pendingOffer = nil
            saveConfig()
            do {
                try await restart()
            } catch let error as AppRestartController.RestartError {
                phase = .failed(AppUpdateError.restartFailed(error.userMessage).userMessage)
            } catch {
                phase = .failed(AppUpdateError.restartFailed("").userMessage)
            }
        } catch let error as AppUpdateError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed(AppUpdateError.replaceFailed.userMessage)
        }
    }

    var statusText: String {
        switch phase {
        case .idle:
            return lastCheckSummary
        case .checking:
            return "正在检查 GitHub 上的新版本…"
        case .upToDate:
            return "已是最新版本"
        case .available:
            if let offer {
                return "有新版本 \(offer.version)"
            }
            return "有新版本"
        case .downloading:
            return "正在下载新版本…"
        case .installing:
            return "正在安装并准备重新打开…"
        case .failed(let message):
            return message
        case .previewDisabled:
            return "演示模式不检查或安装更新"
        }
    }

    var lastCheckSummary: String {
        guard let date = config.lastCheckDate else { return "尚未检查更新" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return "上次检查：\(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    var currentVersionText: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? serviceOverride?.currentVersion.description
            ?? "开发版"
    }

    private func makeService() throws -> AppUpdateService {
        if let serviceOverride { return serviceOverride }
        guard let version = AppUpdateService.runningVersion() else {
            throw AppUpdateError.currentVersionUnknown
        }
        return AppUpdateService(
            currentVersion: version
        )
    }
}

import Foundation

/// A user-facing action that can finish one of the remaining onboarding
/// dependencies. The action is intentionally separate from the underlying
/// evidence flags so the view cannot accidentally present raw implementation
/// checks as completed work.
enum OnboardingReadinessAction: String, CaseIterable, Identifiable {
    case wechatConnection
    case configureAI
    case testAI
    case chooseContacts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wechatConnection: return "完成微信连接"
        case .configureAI: return "设置 AI 服务"
        case .testAI: return "测试 AI 连接"
        case .chooseContacts: return "选择关注的对话"
        }
    }

    var systemImage: String {
        switch self {
        case .wechatConnection: return "link"
        case .configureAI, .testAI: return "sparkles"
        case .chooseContacts: return "person.2"
        }
    }
}

/// Setup evidence stays separate from completing the introduction. A readable
/// key file or populated AI configuration never certifies successful requests.
struct OnboardingReadiness {
    var directoryReady: Bool
    var keyFileReadable: Bool
    var hasSuccessfulSync: Bool
    var aiConfigurationValid: Bool
    var aiConnectionTested: Bool = false
    var trackedConversationCount: Int

    /// Actions are grouped by the user-visible dependency they resolve. In
    /// particular, the three pieces of sync evidence form one connection task.
    var remainingActions: [OnboardingReadinessAction] {
        var actions: [OnboardingReadinessAction] = []
        if !directoryReady || !keyFileReadable || !hasSuccessfulSync {
            actions.append(.wechatConnection)
        }
        if !aiConfigurationValid {
            actions.append(.configureAI)
        } else if !aiConnectionTested {
            actions.append(.testAI)
        }
        if trackedConversationCount == 0 {
            actions.append(.chooseContacts)
        }
        return actions
    }

    /// Kept for callers that render a compact textual summary.
    var remainingSteps: [String] {
        remainingActions.map(\.title)
    }

    /// Assembles readiness from live app state in ONE place.
    ///
    /// The onboarding wizard, the persistent setup card and the today
    /// empty-state each used to re-derive their own "is WeChat connected /
    /// is AI configured / is AI tested" booleans, so the three surfaces could
    /// drift (the card already disagreed with the wizard about what counts as
    /// connected). Every post-launch surface now reads this instead.
    ///
    /// `candidates` is passed in rather than scanned here: the directory scan
    /// touches the filesystem, and callers cache it in `@State` and refresh on
    /// events — computing it per body evaluation would scan on every render.
    ///
    /// Deliberately NOT proof of working requests: a readable key file or a
    /// populated AI config never certifies a successful sync or AI call, which
    /// is why `hasSuccessfulSync` requires an actual `lastSyncAt` from the
    /// matching directory and `aiConnectionTested` requires stored evidence.
    @MainActor
    static func evaluate(
        monitor: ChatMonitor,
        store: HUDStore,
        candidates: [String]
    ) -> OnboardingReadiness {
        let configured = (store.getSettingJSON("sync", as: SyncConfig.self) ?? SyncConfig()).wechatDBPath
        let diagnosis = SyncConnectionDiagnosis.evaluate(
            configuredPath: configured,
            candidates: candidates,
            exists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            readable: { FileManager.default.isReadableFile(atPath: $0) },
            containsDatabase: { FileManager.default.fileExists(atPath: $0 + "/session/session.db") },
            keyMaterial: SyncConnectionDiagnosis.KeyMaterialFacts(reader: monitor.reader)
        )
        let sourceMatches: Bool
        if case .ready(let root) = diagnosis {
            sourceMatches = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
                == URL(fileURLWithPath: monitor.reader.dbDir).standardizedFileURL.resolvingSymlinksInPath()
        } else {
            sourceMatches = false
        }
        let configuration = store.loadAIConfig()
        return OnboardingReadiness(
            directoryReady: !diagnosis.needsAttention,
            // A loose-permission key file is readable; it only needs
            // tightening. Treating it as unreadable would block readiness on a
            // file that is right there.
            keyFileReadable: monitor.reader.accessMaterialState == .available
                || monitor.reader.accessMaterialState == .loosePermissions,
            hasSuccessfulSync: sourceMatches && monitor.stats.lastSyncAt != nil,
            aiConfigurationValid: AISettingsValidation.connectionError(configuration.provider, requireModel: true) == nil,
            aiConnectionTested: AIConnectionEvidenceStore.isSuccessful(configuration, store: store),
            trackedConversationCount: store.getWhitelist().count
        )
    }
}

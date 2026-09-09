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
}

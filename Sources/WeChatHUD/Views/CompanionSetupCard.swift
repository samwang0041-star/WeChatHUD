import SwiftUI

/// Persistent next steps: dismissing the introduction never hides missing setup.
struct CompanionSetupCard: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var store: HUDStore
    let navigate: (SettingsView.Tab) -> Void

    @State private var readinessLoaded = false
    @State private var aiConfigured = false
    @State private var aiConnectionTested = false
    @State private var hasScope = false

    private var connected: Bool {
        guard monitor.stats.lastSyncAt != nil else { return false }
        switch monitor.stats.syncStatus {
        case .ok, .idle, .syncing: return true
        default: return false
        }
    }

    var body: some View {
        Group {
        if readinessLoaded && !PreviewRuntime.isEnabled && (!connected || !aiConfigured || !aiConnectionTested || !hasScope) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Label(FirstLaunchGuide.setupCardTitle, systemImage: "sparkles").font(.headline)
                    Spacer()
                    Button("使用指南") { navigate(.guide) }.buttonStyle(.link)
                }
                Text(FirstLaunchGuide.setupCardSubtitle)
                    .font(.callout).foregroundStyle(.secondary)
                if !connected {
                    step(OnboardingReadinessAction.wechatConnection.title,
                         detail: FirstLaunchGuide.setupStepDetail(.wechatConnection),
                         icon: "bubble.left.and.bubble.right", tab: .system)
                }
                if !aiConfigured {
                    step(OnboardingReadinessAction.configureAI.title,
                         detail: FirstLaunchGuide.setupStepDetail(.configureAI),
                         icon: "sparkles", tab: .aiButler)
                } else if !aiConnectionTested {
                    step(OnboardingReadinessAction.testAI.title,
                         detail: FirstLaunchGuide.setupStepDetail(.testAI),
                         icon: "checkmark.shield", tab: .aiButler)
                }
                if !hasScope {
                    step(OnboardingReadinessAction.chooseContacts.title,
                         detail: FirstLaunchGuide.setupStepDetail(.chooseContacts),
                         icon: "person.2", tab: .contacts)
                }
            }
            .padding(18)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.18)))
        }
        }
        .onAppear { refreshReadiness() }
    }

    private func refreshReadiness() {
        let config = store.loadAIConfig()
        aiConfigured = AISettingsValidation.connectionError(config.provider, requireModel: true) == nil
        aiConnectionTested = AIConnectionEvidenceStore.isSuccessful(config, store: store)
        hasScope = store.hasWhitelistEntries()
        readinessLoaded = true
    }

    private func step(_ title: String, detail: String, icon: String, tab: SettingsView.Tab) -> some View {
        Button { navigate(tab) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("setup.\(tab.rawValue)")
    }
}

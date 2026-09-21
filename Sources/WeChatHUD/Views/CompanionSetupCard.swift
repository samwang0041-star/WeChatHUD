import AppKit
import SwiftUI

/// Persistent next steps: dismissing the introduction never hides missing setup.
///
/// Status comes from `OnboardingReadiness.evaluate` — the same single source of
/// truth the wizard reads — so the card and the wizard can no longer disagree
/// about what "connected" or "AI ready" means. The AI step expands inline into
/// `FirstLaunchAISetupView` (configure + test without leaving the page) and the
/// header carries a one-glance health strip over the three things a new user
/// must get right: a readable database, a live WeChat sync, a reachable AI.
struct CompanionSetupCard: View {
    @EnvironmentObject var monitor: ChatMonitor
    @EnvironmentObject var store: HUDStore
    let navigate: (SettingsView.Tab) -> Void

    @State private var candidates: [String] = []
    @State private var readiness: OnboardingReadiness?
    @State private var aiSetupExpanded = false
    @State private var isRechecking = false

    var body: some View {
        // Readiness is assembled once per relevant event (rescan/recompute) and
        // cached in @State — the same pattern AssistantTodayView uses — so the
        // body reads flags off the cache instead of re-running evaluate (several
        // SQLite reads + file stats) on every property access. `readiness != nil`
        // is the "has computed at least once" gate that refreshID used to be.
        let connected = readiness?.hasSuccessfulSync ?? false
        let databaseReadable = readiness.map { $0.directoryReady && $0.keyFileReadable } ?? false
        let aiConfigured = readiness?.aiConfigurationValid ?? false
        let aiConnectionTested = readiness?.aiConnectionTested ?? false
        let followListUnreadable = readiness?.followListUnreadable ?? false
        let hasScope = (readiness?.trackedConversationCount ?? 0) > 0
        let allReady = connected && aiConfigured && aiConnectionTested && hasScope && !followListUnreadable
        return Group {
        if readiness != nil && !PreviewRuntime.isEnabled && !allReady {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Label(FirstLaunchGuide.setupCardTitle, systemImage: "sparkles").font(.headline)
                    Spacer()
                    Button("使用指南") { navigate(.guide) }.buttonStyle(CompanionPressStyle())
                }
                healthStrip(databaseReadable: databaseReadable, connected: connected, aiConnectionTested: aiConnectionTested)
                Text(FirstLaunchGuide.setupCardSubtitle)
                    .font(.callout).foregroundStyle(.secondary)
                if !connected {
                    step(OnboardingReadinessAction.wechatConnection.title,
                         detail: FirstLaunchGuide.setupStepDetail(.wechatConnection),
                         icon: "bubble.left.and.bubble.right", tab: .system)
                }
                if !aiConfigured {
                    aiStep(.configureAI)
                } else if !aiConnectionTested {
                    aiStep(.testAI)
                }
                if followListUnreadable {
                    step(OnboardingReadinessAction.chooseContacts.title,
                         detail: CompanionInteractionCopy.followListUnreadableEdit,
                         icon: "person.2", tab: .contacts)
                } else if !hasScope {
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
        .onAppear { rescan() }
        // Config / evidence changes don't move directories, so re-evaluating
        // against the cached candidates is enough; becoming active may mean
        // WeChat was just logged in, so that one re-scans the directories.
        .onReceive(NotificationCenter.default.publisher(for: .hudAIConfigDidChange)) { _ in recomputeReadiness() }
        .onReceive(NotificationCenter.default.publisher(for: .hudAIConnectionEvidenceDidChange).receive(on: RunLoop.main)) { _ in recomputeReadiness() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in rescan() }
    }

    /// One-glance consolidation of the three setup dependencies, so the user
    /// can see at a glance which leg is still missing instead of reading the
    /// step list and inferring it.
    private func healthStrip(databaseReadable: Bool, connected: Bool, aiConnectionTested: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("一键体检", systemImage: "stethoscope")
                    .font(.callout.weight(.medium))
                Spacer()
                Button {
                    guard !isRechecking else { return }
                    isRechecking = true
                    Task { @MainActor in
                        rescan()
                        isRechecking = false
                    }
                } label: {
                    Text(isRechecking ? "正在检测…" : "重新检测")
                }
                    .buttonStyle(CompanionPressStyle())
                    .disabled(isRechecking)
                    .help(isRechecking ? "正在重新检测连接" : "")
                    .accessibilityHint(isRechecking ? "正在重新检测连接" : "")
                    .accessibilityIdentifier("setup.recheck")
            }
            HStack(spacing: 16) {
                healthLight(ok: databaseReadable, label: "聊天可读")
                healthLight(ok: connected, label: "微信已连接")
                healthLight(ok: aiConnectionTested, label: "AI 能用")
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.health")
    }

    private func healthLight(ok: Bool, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("\(label)：\(ok ? "正常" : "待完成")")
    }

    /// The AI leg expands in place rather than navigating away: configuring a
    /// provider and running the connection test are two short actions, and
    /// leaving the page made it easy to configure but forget to test (the card
    /// would then keep showing "测试 AI 连接" with no obvious way back).
    private func aiStep(_ action: OnboardingReadinessAction) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withMotion(CompanionMotion.ease()) { aiSetupExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: action.systemImage).foregroundStyle(Color.accentColor).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(action.title).font(.callout.weight(.medium)).foregroundStyle(.primary)
                        Text(FirstLaunchGuide.setupStepDetail(action)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: aiSetupExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(CompanionPressStyle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("setup.aiButler")
            if aiSetupExpanded {
                VStack(alignment: .trailing, spacing: 10) {
                    FirstLaunchAISetupView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("更多 AI 设置") { navigate(.aiButler) }
                        .buttonStyle(CompanionPressStyle())
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("setup.ai.inline")
                .transition(.companionStatusReveal)
            }
        }
        .companionAnimation(CompanionMotion.ease(), value: aiSetupExpanded)
    }

    private func rescan() {
        let scanned = PreviewRuntime.isEnabled ? [] : WeChatReader.databaseCandidates()
        candidates = scanned
        readiness = OnboardingReadiness.evaluate(monitor: monitor, store: store, candidates: scanned)
    }

    private func recomputeReadiness() {
        readiness = OnboardingReadiness.evaluate(monitor: monitor, store: store, candidates: candidates)
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
        .buttonStyle(CompanionRowPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("setup.\(tab.rawValue)")
    }
}

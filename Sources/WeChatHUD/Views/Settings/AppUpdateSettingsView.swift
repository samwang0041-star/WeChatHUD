import SwiftUI
import AppKit

struct AppUpdateSettingsView: View {
    @EnvironmentObject private var store: HUDStore
    @ObservedObject private var updates = AppUpdateController.shared
    @State private var showInstallConfirm = false
    @State private var didLoad = false

    var body: some View {
        SettingsSection("版本与更新") {
            SettingsRow("当前版本", subtitle: updates.statusText, icon: "arrow.triangle.2.circlepath", iconColor: CompanionPalette.jade) {
                Text(updates.currentVersionText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            SettingsRowDivider()
            SettingsRow("检查更新", subtitle: "从 GitHub Releases 读取最新安装包。", icon: "magnifyingglass", iconColor: .blue) {
                Button(checkButtonTitle) {
                    Task { await updates.check(force: true, installIfEnabled: false) }
                }
                .disabled(isBusy || PreviewRuntime.isEnabled)
                .controlSize(.small)
            }
            if updates.phase == .available, updates.offer != nil {
                SettingsRowDivider()
                SettingsRow("安装新版本", subtitle: installSubtitle, icon: "square.and.arrow.down", iconColor: .orange) {
                    Button("下载并安装") { showInstallConfirm = true }
                        .buttonStyle(.borderedProminent)
                        .tint(CompanionPalette.jade)
                        .controlSize(.small)
                        .disabled(isBusy || PreviewRuntime.isEnabled)
                }
            }
            SettingsRowDivider()
            SettingsRow("启动时自动检查", subtitle: "打开后每天最多向 GitHub 查询一次。", icon: "clock.arrow.circlepath", iconColor: .blue) {
                Toggle("启动时自动检查", isOn: autoCheckBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(PreviewRuntime.isEnabled)
            }
            SettingsRowDivider()
            SettingsRow("发现后自动安装", subtitle: "下载 zip、替换当前应用并重新打开。默认关闭。", icon: "arrow.down.app", iconColor: .purple) {
                Toggle("发现后自动安装", isOn: autoInstallBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(PreviewRuntime.isEnabled)
            }
            SettingsRowDivider()
            HStack {
                Spacer(minLength: 56)
                if let url = updates.offer?.htmlURL {
                    Button("在浏览器中查看") { NSWorkspace.shared.open(url) }
                        .controlSize(.small)
                } else if let fallback = URL(string: "https://github.com/\(updates.config.repository)/releases") {
                    Button("打开发布页") { NSWorkspace.shared.open(fallback) }
                        .controlSize(.small)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            if PreviewRuntime.isEnabled {
                Text("演示模式不检查或安装更新。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            updates.bind(store: store)
        }
        .alert("安装新版本？", isPresented: $showInstallConfirm) {
            Button("下载并安装") {
                Task { await updates.installAvailable() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(installConfirmMessage)
        }
    }

    private var isBusy: Bool {
        switch updates.phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private var checkButtonTitle: String {
        switch updates.phase {
        case .checking: return "检查中…"
        case .downloading, .installing: return "安装中…"
        default: return "检查更新"
        }
    }

    private var installSubtitle: String {
        guard let offer = updates.offer else { return "下载安装包并替换当前应用。" }
        if offer.notes.isEmpty {
            return "将安装 \(offer.version)，完成后重新打开助手。"
        }
        let firstLine = offer.notes.split(whereSeparator: \.isNewline).first.map(String.init) ?? offer.notes
        return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
    }

    private var installConfirmMessage: String {
        let version = updates.offer?.version.description ?? "新版本"
        return "将下载 \(version) 并替换当前应用，完成后重新打开。聊天资料仍留在本机。"
    }

    private var autoCheckBinding: Binding<Bool> {
        Binding(
            get: { updates.config.autoCheckEnabled },
            set: { value in
                updates.config.autoCheckEnabled = value
                updates.saveConfig()
            }
        )
    }

    private var autoInstallBinding: Binding<Bool> {
        Binding(
            get: { updates.config.autoInstallEnabled },
            set: { value in
                updates.config.autoInstallEnabled = value
                updates.saveConfig()
            }
        )
    }
}

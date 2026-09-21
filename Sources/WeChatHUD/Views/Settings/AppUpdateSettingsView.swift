import SwiftUI
import AppKit

enum AppUpdateInstallCopy {
    static func confirmMessage(version: String) -> String {
        "将下载 \(version) 并替换当前应用，完成后重新打开。聊天资料仍留在本机。"
    }

    static func actionTitle(phase: AppUpdateController.Phase) -> String {
        switch phase {
        case .downloading: return "正在下载新版本…"
        case .installing: return "正在安装…"
        default: return "下载并安装"
        }
    }
}

struct AppUpdateSettingsView: View {
    @EnvironmentObject private var store: HUDStore
    @ObservedObject private var updates = AppUpdateController.shared
   @Binding var showInstallConfirm: Bool
   @State private var didLoad = false
    @State private var browserOpenError: String?

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
                .help(updateHoldReason ?? "")
                .accessibilityHint(updateHoldReason ?? "")
                .controlSize(.small)
                .buttonStyle(CompanionPressStyle())
            }
            if updates.phase == .available, updates.offer != nil {
                SettingsRowDivider()
                SettingsRow("安装新版本", subtitle: installSubtitle, icon: "square.and.arrow.down", iconColor: .orange) {
                    Button("下载并安装") { showInstallConfirm = true }
                        .tint(CompanionPalette.jade)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isBusy || PreviewRuntime.isEnabled)
                        .help(updateHoldReason ?? "")
                        .accessibilityHint(updateHoldReason ?? "")
                }
            }
            SettingsRowDivider()
            SettingsRow("启动时自动检查", subtitle: "打开后每天最多向 GitHub 查询一次。", icon: "clock.arrow.circlepath", iconColor: .blue) {
                Toggle("启动时自动检查", isOn: autoCheckBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(PreviewRuntime.isEnabled)
                    .help(PreviewRuntime.isEnabled ? "演示界面不会检查或安装更新" : "")
                    .accessibilityHint(PreviewRuntime.isEnabled ? "演示界面不会检查或安装更新" : "")
            }
            SettingsRowDivider()
            SettingsRow("发现后自动安装", subtitle: "下载 zip、替换当前应用并重新打开。只在启动时的自动检查里生效（需同时打开上一项）；手动检查仍会先问你。默认关闭。", icon: "arrow.down.app", iconColor: .purple) {
                Toggle("发现后自动安装", isOn: autoInstallBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(PreviewRuntime.isEnabled)
                    .help(PreviewRuntime.isEnabled ? "演示界面不会检查或安装更新" : "")
                    .accessibilityHint(PreviewRuntime.isEnabled ? "演示界面不会检查或安装更新" : "")
            }
            SettingsRowDivider()
            HStack {
                Spacer(minLength: 56)
               if let url = updates.offer?.htmlURL {
                    Button("在浏览器中查看") { openReleasePage(url) }
                       .controlSize(.small)
                       .buttonStyle(CompanionPressStyle())
               } else if let fallback = URL(string: "https://github.com/\(updates.config.repository)/releases") {
                    Button("打开发布页") { openReleasePage(fallback) }
                       .controlSize(.small)
                       .buttonStyle(CompanionPressStyle())
               }
                Spacer()
            }
           .padding(.horizontal, 16)
           .padding(.bottom, 12)
            if let browserOpenError {
                Text(browserOpenError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.companionStatusReveal)
            }
           if PreviewRuntime.isEnabled {
                Text("演示模式不检查或安装更新。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
       }
        .companionAnimation(CompanionMotion.ease(), value: browserOpenError)
       .onAppear {
           guard !didLoad else { return }
           didLoad = true
           updates.bind(store: store)
       }
   }

    private var isBusy: Bool {
        switch updates.phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private var updateHoldReason: String? {
        if PreviewRuntime.isEnabled { return "演示界面不会检查或安装更新" }
        if isBusy { return "正在检查或安装" }
        return nil
    }

   private var checkButtonTitle: String {
       switch updates.phase {
        case .checking: return "正在检查…"
        case .downloading, .installing: return "正在安装…"
      default: return "检查更新"
      }
  }

    private func openReleasePage(_ url: URL) {
        guard NSWorkspace.shared.open(url) else {
            browserOpenError = "没能打开发布页，请在浏览器打开 GitHub Releases。"
            return
        }
        browserOpenError = nil
    }

   private var installSubtitle: String {
        guard let offer = updates.offer else { return "下载安装包并替换当前应用。" }
        if offer.notes.isEmpty {
            return "将安装 \(offer.version)，完成后重新打开助手。"
        }
        let firstLine = offer.notes.split(whereSeparator: \.isNewline).first.map(String.init) ?? offer.notes
        return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
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

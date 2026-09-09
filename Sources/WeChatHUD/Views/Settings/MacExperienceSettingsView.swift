import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

/// System-owned settings are read from macOS rather than mirrored as a local
/// preference that could claim a permission or login registration succeeded.
struct MacExperienceSettingsView: View {
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var changingLogin = false
    @State private var requestingNotifications = false
    @State private var errorMessage: String?
    @State private var permissionCheckMessage: String?

    var body: some View {
        SettingsSection("macOS 体验与权限") {
            SettingsRow("登录时启动", subtitle: loginExplanation, icon: "power", iconColor: .blue) {
                Toggle("登录时启动", isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: updateLogin))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(changingLogin || PreviewRuntime.isEnabled)
            }
            if loginStatus == .requiresApproval {
                Button("在系统设置中确认登录项") { SMAppService.openSystemSettingsLoginItems() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 56).padding(.vertical, 10)
            }
            SettingsRowDivider()
            SettingsRow("微信操作权限", subtitle: "用于跳转到微信和发送回复；不影响读取聊天。",
                        icon: "hand.point.up.left", iconColor: .purple) {
                HStack(spacing: 8) {
                    Label(accessibilityGranted ? "已允许" : "待授权",
                          systemImage: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accessibilityGranted ? CompanionPalette.jade : .orange)
                    Button(accessibilityGranted ? "管理权限" : "打开辅助功能设置") {
                        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    }.disabled(PreviewRuntime.isEnabled)
                }
            }
            if !accessibilityGranted {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "exclamationmark.bubble")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .frame(width: 28)
                    Text("已经打开开关？请先重新检查。若仍未生效，退出并重新打开聊天伴侣后再试。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("重新检查权限") {
                        refresh()
                        permissionCheckMessage = accessibilityGranted
                            ? "权限已生效，可以返回聊天继续回复。"
                            : "当前应用仍未获得授权。请重新打开聊天伴侣后再试；回复内容不会自动发送。"
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(PreviewRuntime.isEnabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            if let permissionCheckMessage {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    Text(permissionCheckMessage)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
            SettingsRowDivider()
            SettingsRow("系统通知", subtitle: "接收待办提醒与重要更新。", icon: "bell.badge", iconColor: .orange) {
                HStack(spacing: 8) {
                    if notificationStatus == .authorized {
                        Label("已允许", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(CompanionPalette.jade)
                    }
                    if notificationStatus == .notDetermined {
                        Button("允许系统通知", action: requestNotifications)
                            .disabled(requestingNotifications || PreviewRuntime.isEnabled)
                    } else {
                        Button("管理通知") { openSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
                            .disabled(PreviewRuntime.isEnabled)
                    }
                }
            }
            SettingsRowDivider()
            Text("关闭这个窗口后，助手仍留在顶部和菜单栏。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
            SettingsRowDivider()
            SettingsRow("动画与透明度", subtitle: "减少动态效果时立刻切换状态；减少透明度时用实底，不靠桌面衬出字。", icon: "circle.dotted", iconColor: CompanionPalette.jade) {
                Text(accessibilityStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(CompanionPalette.jade)
                Text("更改已保存").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            if PreviewRuntime.isEnabled {
                Text("演示模式不修改登录项或申请系统权限。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            if let errorMessage {
                Text(errorMessage).font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var accessibilityStatus: String {
        let motion = CompanionMotion.reduceMotion ? "减少动态效果已开启" : "使用完整动效"
        let material = CompanionMotion.reduceTransparency ? "减少透明度已开启" : "使用默认材质"
        return "\(motion)\n\(material)"
    }

    private var loginExplanation: String {
        switch loginStatus {
        case .enabled: return "登录这台 Mac 后自动启动聊天伴侣。"
        case .requiresApproval: return "已申请登录启动，仍需在系统设置中允许。"
        case .notRegistered: return "需要时手动启动；开启后会向 macOS 注册登录项。"
        case .notFound:
            return runningFromApplicationsFolder
                ? "当前应用已从“应用程序”运行，但 macOS 尚未找到登录项。请重新打开应用后再试，或在系统设置的登录项中检查。"
                : "macOS 尚未找到当前应用的登录项。请将完整应用移入“应用程序”文件夹后重新打开，再开启此选项。"
        @unknown default: return "请在系统设置中检查登录项。"
        }
    }

    private var runningFromApplicationsFolder: Bool {
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let applicationFolders = [
            "/Applications",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications")
                .standardizedFileURL.path
        ]
        return applicationFolders.contains { folder in
            bundlePath == folder || bundlePath.hasPrefix(folder + "/")
        }
    }

    private var notificationExplanation: String {
        switch notificationStatus {
        case .authorized: return "已允许，承诺到期等提醒可进入通知中心。"
        case .provisional, .ephemeral: return "通知受系统限制，请在系统设置中检查提醒方式。"
        case .denied: return "通知未获允许，顶部浮窗和聊天伴侣窗口仍可使用。"
        case .notDetermined: return "用于承诺到期和重要消息提醒，由你决定是否允许。"
        @unknown default: return "请在系统设置中检查通知权限。"
        }
    }

    private func refresh() {
        permissionCheckMessage = nil
        loginStatus = SMAppService.mainApp.status
        accessibilityGranted = AXIsProcessTrusted()
        guard !PreviewRuntime.isEnabled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in notificationStatus = settings.authorizationStatus }
        }
    }

    private func updateLogin(_ enabled: Bool) {
        guard !PreviewRuntime.isEnabled, !changingLogin else { return }
        changingLogin = true
        Task { @MainActor in
            defer { changingLogin = false; refresh() }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                errorMessage = nil
            } catch {
                errorMessage = runningFromApplicationsFolder
                    ? "登录项未能更改。请重新打开应用后再试，并在系统设置的登录项中检查。"
                    : "登录项未能更改。请将完整应用移入“应用程序”文件夹后重新打开，再试一次。"
            }
        }
    }

    private func requestNotifications() {
        guard !PreviewRuntime.isEnabled, !requestingNotifications else { return }
        requestingNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            Task { @MainActor in
                requestingNotifications = false
                errorMessage = error == nil ? nil : "通知权限请求未完成，请在系统设置中检查。"
                refresh()
            }
        }
    }

    private func openSettings(_ address: String) {
        guard let url = URL(string: address), NSWorkspace.shared.open(url) else {
            errorMessage = "系统设置未能打开，请从苹果菜单中打开系统设置。"
            return
        }
        errorMessage = nil
    }
}

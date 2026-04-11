import SwiftUI

struct SettingsView: View {
    @Binding var showSettings: Bool
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("设置")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { showSettings = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().background(Color.white.opacity(0.1))

            // Tab bar
            HStack(spacing: 16) {
                settingsTab("AI 配置", icon: "cpu", index: 0)
                settingsTab("数据同步", icon: "arrow.triangle.2.circlepath", index: 1)
                settingsTab("通知", icon: "bell", index: 2)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider().background(Color.white.opacity(0.1))

            // Content
            ScrollView {
                switch selectedTab {
                case 0: AISettingsView()
                case 1: SyncSettingsView()
                case 2: notificationSettings
                default: EmptyView()
                }
            }
            .padding(16)
        }
    }

    private func settingsTab(_ label: String, icon: String, index: Int) -> some View {
        Button(action: { selectedTab = index }) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12))
            }
            .foregroundColor(selectedTab == index ? .white : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selectedTab == index ? Color.white.opacity(0.15) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private var notificationSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("通知设置")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)

            Toggle("@提到我时弹出通知", isOn: .constant(true))
                .font(.system(size: 12))
            Toggle("重要消息弹出通知", isOn: .constant(true))
                .font(.system(size: 12))
            Toggle("所有白名单消息弹出", isOn: .constant(false))
                .font(.system(size: 12))
        }
        .foregroundColor(.white)
    }
}

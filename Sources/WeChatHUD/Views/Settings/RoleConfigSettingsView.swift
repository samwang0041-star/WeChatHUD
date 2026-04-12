import SwiftUI

/// Per-role configuration editor. Each of the 11 roles is an expandable card
/// where users can tune reply window, notify level, classifier strictness,
/// reply tone, and VIP tracking dimensions.
struct RoleConfigSettingsView: View {
    @EnvironmentObject private var store: HUDStore

    @State private var configs: [String: RoleConfig] = [:]
    @State private var expandedRole: String?
    @State private var didLoad = false
    @State private var showSaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("每种身份角色的 AI 行为参数。修改后自动保存。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if showSaved {
                    Text("已保存")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.green)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 4)

            ForEach(orderedRoles, id: \.key) { key, role in
                roleCard(key: key, role: role)
            }
        }
        .onAppear {
            if !didLoad {
                configs = store.getSettingJSON("role_configs", as: [String: RoleConfig].self) ?? [:]
                didLoad = true
            }
        }
    }

    private var orderedRoles: [(key: String, role: ContactRole)] {
        let order: [(String, ContactRole)] = [
            ("boss", .boss), ("key_client", .keyClient), ("family", .family), ("partner", .partner),
            ("colleague", .colleague), ("client", .client), ("friend", .friend), ("supplier", .supplier),
            ("acquaintance", .acquaintance), ("group_only", .groupOnly), ("service", .service)
        ]
        return order.map { (key: $0.0, role: $0.1) }
    }

    private func roleCard(key: String, role: ContactRole) -> some View {
        let isExpanded = expandedRole == key
        let config = configs[key] ?? RoleConfig(
            replyWindow: role.defaultReplyWindowMinutes,
            notifyLevel: role.defaultNotifyLevel.rawValue,
            classifierStrictness: "normal",
            replyTone: role.defaultReplyTone.rawValue,
            vipTrackDimensions: role.vipTrackDimensions
        )

        return SettingsCard {
            VStack(alignment: .leading, spacing: isExpanded ? 12 : 0) {
                // Header (always visible)
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expandedRole = isExpanded ? nil : key } }) {
                    HStack(spacing: 8) {
                        Text(role.icon)
                            .font(.system(size: 16))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(role.label)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.primary)
                            Text(role.roleDescription)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()

                        // Summary pills
                        HStack(spacing: 4) {
                            miniPill("\(config.replyWindow)m", color: .blue)
                            miniPill(config.notifyLevel, color: config.notifyLevel == "strong" ? .red : .gray)
                        }

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Expanded editor
                if isExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        Divider()

                        // Reply window
                        configRow("回复窗口") {
                            HStack(spacing: 6) {
                                TextField("", value: binding(key, \.replyWindow, config), format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                                    .frame(width: 60)
                                Text("分钟（0 = 不追踪）")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }

                        // Notify level
                        configRow("通知级别") {
                            Picker("", selection: bindingString(key, \.notifyLevel, config)) {
                                Text("强通知").tag("strong")
                                Text("标准").tag("standard")
                                Text("轻提醒").tag("light")
                                Text("静默").tag("none")
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 280)
                        }

                        // Classifier strictness
                        configRow("分类严格度") {
                            Picker("", selection: bindingString(key, \.classifierStrictness, config)) {
                                Text("标准").tag("normal")
                                Text("严格（疑问句都算 ask）").tag("high")
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 280)
                        }

                        // Reply tone
                        configRow("回复语气") {
                            Picker("", selection: bindingString(key, \.replyTone, config)) {
                                Text("汇报式").tag("reporting")
                                Text("专业").tag("professional")
                                Text("协作").tag("collaborative")
                                Text("随意").tag("casual")
                                Text("礼貌").tag("polite")
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 360)
                        }

                        // VIP dimensions (only for VIP-eligible roles)
                        if !role.vipTrackDimensions.isEmpty {
                            configRow("VIP 追踪维度") {
                                Text(config.vipTrackDimensions.joined(separator: ", "))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func configRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            content()
        }
    }

    private func miniPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(3)
    }

    private func binding(_ key: String, _ keyPath: WritableKeyPath<RoleConfig, Int>, _ fallback: RoleConfig) -> Binding<Int> {
        Binding(
            get: { configs[key]?[keyPath: keyPath] ?? fallback[keyPath: keyPath] },
            set: { newValue in
                var cfg = configs[key] ?? fallback
                cfg[keyPath: keyPath] = newValue
                configs[key] = cfg
                save()
            }
        )
    }

    private func bindingString(_ key: String, _ keyPath: WritableKeyPath<RoleConfig, String>, _ fallback: RoleConfig) -> Binding<String> {
        Binding(
            get: { configs[key]?[keyPath: keyPath] ?? fallback[keyPath: keyPath] },
            set: { newValue in
                var cfg = configs[key] ?? fallback
                cfg[keyPath: keyPath] = newValue
                configs[key] = cfg
                save()
            }
        )
    }

    private func save() {
        try? store.setSettingJSON("role_configs", value: configs)
        showSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSaved = false }
    }
}
